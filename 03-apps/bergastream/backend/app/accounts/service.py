"""Regras das contas.

Com o Authentik ligado, ele é a fonte de usuário, nome, e-mail e senha: numa
conta já ligada (`oidc_subject`) esses campos são só leitura aqui e são
atualizados a cada login pelo Authentik (ver `app/auth/oidc.py`). A ligação é
pelo `sub`, então trocar usuário ou e-mail lá não desfaz nada.

O que pode quebrar a ligação é mexer **antes** do 1º login pelo Authentik: aí
o usuário e o e-mail daqui é que casam as contas. Por isso o app avisa antes
de salvar, e o e-mail é único (ligação sem ambiguidade).
"""
from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta, timezone

import asyncpg

from app.auth import repository as auth_repo
from app.auth.security import hash_password, hash_refresh_token
from app.config import settings

USERNAME = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

COLUMNS = ("id, username, name, email, is_admin, password_hash, oidc_subject, "
           "disabled_at, last_login_at, created_at")


class AccountError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def linked(row) -> bool:
    return row["oidc_subject"] is not None


def managed(row) -> bool:
    """Usuário, nome, e-mail e senha vêm do Authentik."""
    return settings.oidc_enabled and linked(row)


def admin_managed(row) -> bool:
    """O admin vem do grupo do Authentik (OIDC_ADMIN_GROUP)."""
    return managed(row) and bool(settings.oidc_admin_group)


def can_change_password(row) -> bool:
    return settings.password_login_enabled and not managed(row)


async def get(pool, user_id: str):
    try:
        return await pool.fetchrow(f"SELECT {COLUMNS} FROM users WHERE id = $1", user_id)
    except (asyncpg.DataError, ValueError):
        return None  # id que não é UUID


async def list_all(pool):
    return await pool.fetch(
        f"""SELECT {COLUMNS},
                   (SELECT count(DISTINCT family_id) FROM refresh_tokens r
                     WHERE r.user_id = users.id AND r.revoked_at IS NULL
                       AND r.expires_at > now()) AS sessions
            FROM users ORDER BY lower(name)""")


# ── Validação ─────────────────────────────────────────────────────

def clean_username(value: str) -> str:
    value = value.strip()
    if not USERNAME.match(value):
        raise AccountError(422, "Usuário: 3 a 32 letras, números, ponto, hífen ou _.")
    return value


def clean_name(value: str) -> str:
    value = " ".join(value.split())
    if not 1 <= len(value) <= 60:
        raise AccountError(422, "Nome: de 1 a 60 letras.")
    return value


def clean_email(value: str | None) -> str | None:
    value = (value or "").strip().lower()
    if not value:
        return None
    if len(value) > 254 or not EMAIL.match(value):
        raise AccountError(422, "E-mail inválido.")
    return value


def clean_password(value: str) -> str:
    if len(value) < 8:
        raise AccountError(422, "A senha precisa ter pelo menos 8 caracteres.")
    if len(value) > 256:
        raise AccountError(422, "Senha longa demais.")
    return value


async def _check_free(pool, user_id, username=None, name=None, email=None) -> None:
    if username and await pool.fetchval(
            "SELECT 1 FROM users WHERE lower(username) = lower($1) AND id IS DISTINCT FROM $2",
            username, user_id):
        raise AccountError(409, "Já existe uma conta com este usuário.")
    if name and await pool.fetchval(
            "SELECT 1 FROM users WHERE name = $1 AND id IS DISTINCT FROM $2", name, user_id):
        raise AccountError(409, "Já existe uma conta com este nome.")
    if email and await pool.fetchval(
            "SELECT 1 FROM users WHERE lower(email) = $1 AND id IS DISTINCT FROM $2",
            email, user_id):
        raise AccountError(409, "Já existe uma conta com este e-mail.")


# ── Alterações ───────────────────────────────────────────────────

async def create(pool, username: str, name: str | None, email: str | None, is_admin: bool):
    username = clean_username(username)
    name = clean_name(name or username)
    email = clean_email(email)
    await _check_free(pool, None, username, name, email)
    try:
        return await pool.fetchrow(
            f"""INSERT INTO users (username, name, email, is_admin) VALUES ($1, $2, $3, $4)
                RETURNING {COLUMNS}""", username, name, email, is_admin)
    except asyncpg.UniqueViolationError:
        raise AccountError(409, "Já existe uma conta com este usuário, nome ou e-mail.")


async def update_identity(pool, row, *, username: str | None = None, name: str | None = None,
                          email: str | None = None, clear_email: bool = False):
    """Troca usuário, nome e/ou e-mail. Devolve (linha nova, {campo: (antes, depois)})."""
    wanted = {}
    if username is not None:
        wanted["username"] = clean_username(username)
    if name is not None:
        wanted["name"] = clean_name(name)
    if email is not None or clear_email:
        wanted["email"] = clean_email(email)
    changes = {k: (row[k], v) for k, v in wanted.items() if (row[k] or None) != v}
    if not changes:
        return row, {}
    if managed(row):
        raise AccountError(409, "Usuário, nome e e-mail desta conta vêm do Authentik: altere "
                                "lá e eles mudam aqui no próximo login.")
    await _check_free(pool, row["id"], *(changes.get(k, (None, None))[1]
                                          for k in ("username", "name", "email")))
    sets = ", ".join(f"{k} = ${i}" for i, k in enumerate(changes, start=2))
    try:
        new = await pool.fetchrow(f"UPDATE users SET {sets} WHERE id = $1 RETURNING {COLUMNS}",
                                  row["id"], *(v for _, v in changes.values()))
    except asyncpg.UniqueViolationError:
        raise AccountError(409, "Já existe uma conta com este usuário, nome ou e-mail.")
    return new, changes


async def _active_admins(pool, besides) -> int:
    return await pool.fetchval(
        "SELECT count(*) FROM users WHERE is_admin AND disabled_at IS NULL AND id <> $1", besides)


async def set_admin(pool, actor_id: str, row, value: bool):
    if row["is_admin"] == value:
        return row
    if admin_managed(row):
        raise AccountError(409, "Quem é admin vem do grupo do Authentik (OIDC_ADMIN_GROUP).")
    if not value and str(row["id"]) == actor_id:
        raise AccountError(409, "Você não pode tirar o seu próprio admin.")
    if not value and await _active_admins(pool, row["id"]) == 0:
        raise AccountError(409, "Precisa ficar pelo menos um admin.")
    return await pool.fetchrow(f"UPDATE users SET is_admin = $2 WHERE id = $1 RETURNING {COLUMNS}",
                               row["id"], value)


async def set_disabled(pool, actor_id: str, row, value: bool):
    if (row["disabled_at"] is not None) == value:
        return row
    if value and str(row["id"]) == actor_id:
        raise AccountError(409, "Você não pode desativar a sua própria conta.")
    if value and row["is_admin"] and await _active_admins(pool, row["id"]) == 0:
        raise AccountError(409, "Precisa ficar pelo menos um admin ativo.")
    new = await pool.fetchrow(
        f"""UPDATE users SET disabled_at = CASE WHEN $2 THEN now() END WHERE id = $1
            RETURNING {COLUMNS}""", row["id"], value)
    if value:
        await auth_repo.revoke_all_for_user(pool, row["id"])
    return new


async def set_password(pool, row, password: str) -> None:
    """Senha nova; derruba todas as sessões."""
    await auth_repo.set_password(pool, row["id"], hash_password(clean_password(password)))
    await auth_repo.revoke_all_for_user(pool, row["id"])


def temporary_password() -> str:
    # Sem caracteres parecidos (l/1, O/0), para ditar ou digitar.
    alphabet = "abcdefghjkmnpqrstuvwxyzACDEFGHJKLMNPQRTUVWXY34679"
    return "".join(secrets.choice(alphabet) for _ in range(12))


async def unlink(pool, row) -> None:
    await pool.execute("UPDATE users SET oidc_subject = NULL WHERE id = $1", row["id"])
    await auth_repo.revoke_all_for_user(pool, row["id"])


# ── Links de "criar/redefinir senha" ─────────────────────────────

async def create_reset(pool, user_id, hours: int) -> str:
    token = secrets.token_urlsafe(32)
    # Um link valendo por vez: pedir de novo invalida o anterior.
    await pool.execute("DELETE FROM password_resets WHERE user_id = $1", user_id)
    await pool.execute(
        "INSERT INTO password_resets (token_hash, user_id, expires_at) VALUES ($1, $2, $3)",
        hash_refresh_token(token), user_id,
        datetime.now(timezone.utc) + timedelta(hours=hours))
    return token


def reset_url(token: str) -> str:
    return f"{settings.public_url}/api/auth/password/reset?token={token}"


async def peek_reset(pool, token: str):
    """Conta do link, se ainda vale (sem gastar)."""
    return await pool.fetchrow(
        f"""SELECT {", ".join("u." + c.strip() for c in COLUMNS.split(","))}
            FROM password_resets r JOIN users u ON u.id = r.user_id
            WHERE r.token_hash = $1 AND r.used_at IS NULL AND r.expires_at > now()
              AND u.disabled_at IS NULL""", hash_refresh_token(token))


async def use_reset(pool, token: str, password: str):
    """Troca a senha pelo link (uma vez só). Devolve a conta ou None."""
    password = clean_password(password)
    async with pool.acquire() as conn:
        async with conn.transaction():
            user_id = await conn.fetchval(
                """UPDATE password_resets SET used_at = now()
                   WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()
                   RETURNING user_id""", hash_refresh_token(token))
            if user_id is None:
                return None
            row = await conn.fetchrow(f"SELECT {COLUMNS} FROM users WHERE id = $1", user_id)
            if row is None or row["disabled_at"] is not None:
                return None
            await conn.execute("UPDATE users SET password_hash = $2 WHERE id = $1",
                               user_id, hash_password(password))
            await conn.execute("DELETE FROM password_resets WHERE user_id = $1", user_id)
    await auth_repo.revoke_all_for_user(pool, user_id)
    return row


async def find_for_reset(pool, login: str):
    """Conta pelo usuário ou e-mail (esqueci a senha)."""
    login = login.strip()
    return await pool.fetchrow(
        f"""SELECT {COLUMNS} FROM users
            WHERE (lower(username) = lower($1) OR lower(email) = lower($1))
              AND disabled_at IS NULL LIMIT 1""", login)
