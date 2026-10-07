"""Regras de login, renovação (com rotação) e logout."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

from app.auth import repository as repo
from app.auth.models import TokenPair, UserOut
from app.auth.security import (
    create_access_token,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)
from app.config import settings

if TYPE_CHECKING:
    import asyncpg


class InvalidCredentials(Exception):
    pass


class InvalidRefreshToken(Exception):
    pass


def _user_out(row) -> UserOut:
    return UserOut(
        id=row["id"], username=row["username"], name=row["name"], is_admin=row["is_admin"]
    )


async def _issue(
    pool: "asyncpg.Pool", row, family_id: uuid.UUID, user_agent: str | None
) -> TokenPair:
    refresh = new_refresh_token()
    await repo.insert_refresh_token(
        pool,
        row["id"],
        family_id,
        hash_refresh_token(refresh),
        datetime.now(timezone.utc) + timedelta(days=settings.refresh_token_days),
        user_agent,
    )
    return TokenPair(
        access_token=create_access_token(str(row["id"]), row["is_admin"]),
        refresh_token=refresh,
        expires_in=settings.access_token_minutes * 60,
        user=_user_out(row),
    )


async def login(
    pool: "asyncpg.Pool", username: str, password: str, user_agent: str | None
) -> TokenPair:
    row = await repo.get_user_by_username(pool, username.strip())
    # verify_password roda mesmo sem usuário (tempo constante).
    ok = verify_password(row["password_hash"] if row else None, password)
    if not row or not ok:
        raise InvalidCredentials()
    return await _issue(pool, row, uuid.uuid4(), user_agent)


async def refresh(pool: "asyncpg.Pool", token: str, user_agent: str | None) -> TokenPair:
    """Troca o refresh token por um par novo. Token já trocado reaparecendo
    revoga a família inteira."""
    token_hash = hash_refresh_token(token)
    # A decisão é tomada dentro da transação, mas a exceção só sai depois do
    # commit: lançar lá dentro desfaria a revogação da família.
    valid = False
    async with pool.acquire() as conn:
        async with conn.transaction():
            current = await repo.get_refresh_token(conn, token_hash, for_update=True)
            if current is None:
                pass
            elif current["revoked_at"] is not None:
                await repo.revoke_family(conn, current["family_id"])
            elif current["expires_at"] <= datetime.now(timezone.utc):
                pass
            else:
                await repo.revoke_refresh_token(conn, current["id"])
                valid = True
    if not valid:
        raise InvalidRefreshToken()

    row = await repo.get_user_by_id(pool, current["user_id"])
    if row is None:
        raise InvalidRefreshToken()
    return await _issue(pool, row, current["family_id"], user_agent)


async def logout(pool: "asyncpg.Pool", token: str) -> None:
    async with pool.acquire() as conn:
        current = await repo.get_refresh_token(conn, hash_refresh_token(token))
        if current is not None:
            await repo.revoke_family(conn, current["family_id"])
