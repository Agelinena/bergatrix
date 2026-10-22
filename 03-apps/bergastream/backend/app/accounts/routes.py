"""Rotas de contas.

- /api/admin/users/*       gestão das pessoas (só admin)
- /api/auth/account/*      "minha conta" (a própria pessoa)
- /api/auth/password/*     esqueci a senha e o link de redefinir (públicas)
- /api/admin/mail/*        situação e teste do envio de e-mail (só admin)

Regras em app/accounts/service.py; textos dos e-mails em notices.py.
"""
from __future__ import annotations

import html
import logging
from datetime import datetime
from typing import Literal

from fastapi import (APIRouter, BackgroundTasks, Depends, Form, HTTPException, Query, Request,
                     status)
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from app.accounts import notices, service
from app.accounts.service import AccountError
from app.auth import rate_limit
from app.auth import service as auth_service
from app.auth.dependencies import CurrentUser, admin_user, current_user
from app.auth.models import TokenPair
from app.config import settings
from app.core import mail
from app.core.db import get_pool
from app.core.pages import page

logger = logging.getLogger("bergastream.accounts")
admin_router = APIRouter(prefix="/api/admin", tags=["accounts"])
me_router = APIRouter(prefix="/api/auth", tags=["accounts"])


# ── Modelos ──────────────────────────────────────────────────────

class AccountOut(BaseModel):
    id: str
    username: str
    name: str
    email: str | None = None
    is_admin: bool
    disabled: bool = False
    # Já entrou pelo Authentik (ligada pelo sub).
    linked: bool = False
    # Usuário, nome, e-mail e senha vêm do Authentik (só leitura aqui).
    managed_by_authentik: bool = False
    admin_managed_by_authentik: bool = False
    has_password: bool = False
    last_login_at: datetime | None = None
    created_at: datetime | None = None
    sessions: int = 0

    @field_validator("id", mode="before")
    @classmethod
    def _id(cls, v):
        return str(v)


class MyAccount(AccountOut):
    can_change_password: bool = False
    # Página "Minha conta" do Authentik (trocar usuário, e-mail, senha).
    account_url: str | None = None
    mail_enabled: bool = False
    # Login pelo Authentik ligado no servidor (a conta ainda pode não estar
    # ligada: aí usuário e e-mail daqui é que vão casar as contas).
    oidc_enabled: bool = False


class UsersPage(BaseModel):
    users: list[AccountOut]
    mail_enabled: bool
    oidc_enabled: bool
    password_login_enabled: bool
    authentik_admin_url: str | None = None


class NewUser(BaseModel):
    username: str = Field(max_length=64)
    name: str | None = Field(None, max_length=120)
    email: str | None = Field(None, max_length=254)
    is_admin: bool = False
    # Manda o convite por e-mail (com o link de criar senha, se houver senha).
    invite: bool = True


class UserPatch(BaseModel):
    username: str | None = Field(None, max_length=64)
    name: str | None = Field(None, max_length=120)
    # "" apaga o e-mail.
    email: str | None = Field(None, max_length=254)
    is_admin: bool | None = None
    disabled: bool | None = None
    # Avisa a pessoa por e-mail do que mudou.
    notify: bool = True


class PasswordAction(BaseModel):
    # link: e-mail com o link de criar senha nova; temporary: senha devolvida
    # aqui, para o admin passar à pessoa.
    mode: Literal["link", "temporary"]
    notify: bool = True


class Notice(BaseModel):
    subject: str = Field(min_length=1, max_length=120)
    message: str = Field(min_length=1, max_length=4000)


class AccountPatch(BaseModel):
    username: str | None = Field(None, max_length=64)
    name: str | None = Field(None, max_length=120)
    email: str | None = Field(None, max_length=254)


class PasswordChange(BaseModel):
    current_password: str = Field("", max_length=256)
    new_password: str = Field(min_length=1, max_length=256)


class Forgot(BaseModel):
    login: str = Field(min_length=1, max_length=254)


def _out(row, cls=AccountOut, **extra):
    return cls(
        id=row["id"], username=row["username"], name=row["name"], email=row["email"],
        is_admin=row["is_admin"], disabled=row["disabled_at"] is not None,
        linked=service.linked(row), managed_by_authentik=service.managed(row),
        admin_managed_by_authentik=service.admin_managed(row),
        has_password=row["password_hash"] is not None, last_login_at=row["last_login_at"],
        created_at=row["created_at"], **extra)


def _fail(exc: AccountError):
    return HTTPException(exc.status, detail=exc.message)


async def _row(pool, user_id: str):
    row = await service.get(pool, user_id)
    if row is None:
        raise HTTPException(404, detail="Usuário não encontrado")
    return row


async def _tell(row, notice: tuple[str, str], to: str | None = None) -> bool:
    subject, text = notice
    return await mail.send(to or row["email"], subject, text)


async def _tell_changes(row, changes: dict) -> None:
    """E-mails do que mudou no usuário e no e-mail (o e-mail antigo também
    fica sabendo: se não foi a pessoa, ela percebe)."""
    if "username" in changes:
        old, new = changes["username"]
        await _tell(row, notices.username_changed(row["name"], old, new))
    if "email" in changes:
        old, new = changes["email"]
        if old:
            await _tell(row, notices.email_changed_old(row["name"], new or "(nenhum)"), old)
        if new:
            await _tell(row, notices.email_changed_new(row["name"]), new)


# ── Admin: pessoas ───────────────────────────────────────────────

@admin_router.get("/users", response_model=UsersPage)
async def list_users(_: CurrentUser = Depends(admin_user)):
    rows = await service.list_all(get_pool())
    return UsersPage(
        users=[_out(r, sessions=r["sessions"]) for r in rows],
        mail_enabled=mail.enabled(), oidc_enabled=settings.oidc_enabled,
        password_login_enabled=settings.password_login_enabled,
        authentik_admin_url=settings.authentik_admin_url or None)


@admin_router.post("/users", response_model=AccountOut, status_code=201)
async def create_user(body: NewUser, admin: CurrentUser = Depends(admin_user)):
    """Conta nova sem senha. Com o Authentik, ela é ligada no 1º login pelo
    mesmo usuário ou e-mail; com senha, o convite leva o link de criar."""
    pool = get_pool()
    try:
        row = await service.create(pool, body.username, body.name, body.email, body.is_admin)
    except AccountError as exc:
        raise _fail(exc)
    logger.info("[contas] %s criou a conta %s", admin.id, row["id"])
    if body.invite and row["email"]:
        url = None
        if settings.password_login_enabled and settings.public_url:
            url = service.reset_url(await service.create_reset(pool, row["id"], settings.invite_hours))
        await _tell(row, notices.invite(row["name"], row["username"], url, settings.invite_hours))
    return _out(row)


@admin_router.patch("/users/{user_id}", response_model=AccountOut)
async def update_user(user_id: str, body: UserPatch, admin: CurrentUser = Depends(admin_user)):
    pool = get_pool()
    row = await _row(pool, user_id)
    try:
        row, changes = await service.update_identity(
            pool, row, username=body.username, name=body.name, email=body.email,
            clear_email=body.email == "")
        if body.is_admin is not None:
            row = await service.set_admin(pool, admin.id, row, body.is_admin)
        was_disabled = row["disabled_at"] is not None
        if body.disabled is not None:
            row = await service.set_disabled(pool, admin.id, row, body.disabled)
    except AccountError as exc:
        raise _fail(exc)
    if changes:
        logger.info("[contas] %s alterou %s na conta %s", admin.id, sorted(changes), row["id"])
    if body.notify:
        await _tell_changes(row, changes)
        now_disabled = row["disabled_at"] is not None
        if now_disabled != was_disabled:
            await _tell(row, notices.disabled(row["name"]) if now_disabled
                        else notices.enabled(row["name"]))
    return _out(row)


@admin_router.post("/users/{user_id}/password")
async def reset_password(user_id: str, body: PasswordAction,
                         admin: CurrentUser = Depends(admin_user)):
    """Redefine a senha do Bergastream. Com o Authentik, a senha é a de lá."""
    pool = get_pool()
    row = await _row(pool, user_id)
    if not service.can_change_password(row):
        raise HTTPException(409, detail="A senha desta conta é a do Authentik: redefina lá."
                            if service.managed(row) else "O login por senha está desligado.")
    if body.mode == "link":
        if not row["email"] or not mail.enabled() or not settings.public_url:
            raise HTTPException(409, detail="Precisa de e-mail na conta, SMTP configurado e "
                                            "APP_URL (ou OIDC_REDIRECT_URI) no .env.")
        token = await service.create_reset(pool, row["id"], settings.password_reset_hours)
        sent = await _tell(row, notices.reset_link(row["name"], service.reset_url(token),
                                                   settings.password_reset_hours))
        if not sent:
            raise HTTPException(502, detail="O e-mail não foi enviado. Confira o SMTP em "
                                            "Usuários → Testar e-mail.")
        logger.info("[contas] %s mandou link de senha para a conta %s", admin.id, row["id"])
        return {"sent": True}
    password = service.temporary_password()
    await service.set_password(pool, row, password)
    logger.info("[contas] %s definiu senha temporária na conta %s", admin.id, row["id"])
    sent = body.notify and await _tell(row, notices.temporary_password(row["name"]))
    return {"password": password, "sent": bool(sent)}


@admin_router.post("/users/{user_id}/sessions/revoke", status_code=204)
async def revoke_sessions(user_id: str, admin: CurrentUser = Depends(admin_user)):
    """Desconecta todos os aparelhos (em até 15 min, quando o acesso vence)."""
    from app.auth import repository as auth_repo
    row = await _row(get_pool(), user_id)
    await auth_repo.revoke_all_for_user(get_pool(), row["id"])
    logger.info("[contas] %s encerrou as sessões da conta %s", admin.id, row["id"])


@admin_router.post("/users/{user_id}/unlink", response_model=AccountOut)
async def unlink(user_id: str, admin: CurrentUser = Depends(admin_user)):
    """Desfaz a ligação com o Authentik (ligou na conta errada): o próximo
    login liga de novo pelo usuário ou e-mail."""
    pool = get_pool()
    row = await _row(pool, user_id)
    await service.unlink(pool, row)
    logger.info("[contas] %s desligou do Authentik a conta %s", admin.id, row["id"])
    return _out(await _row(pool, user_id))


@admin_router.post("/users/{user_id}/notice")
async def send_notice(user_id: str, body: Notice, admin: CurrentUser = Depends(admin_user)):
    row = await _row(get_pool(), user_id)
    if not row["email"]:
        raise HTTPException(409, detail="Esta conta não tem e-mail.")
    if not await _tell(row, notices.custom(row["name"], body.subject, body.message)):
        raise HTTPException(502, detail="O e-mail não foi enviado. Confira o SMTP.")
    return {"sent": True}


# ── Admin: e-mail ────────────────────────────────────────────────

@admin_router.get("/mail")
async def mail_status(_: CurrentUser = Depends(admin_user)):
    return {"enabled": mail.enabled(), "from": settings.smtp_from or None,
            "host": settings.smtp_host or None, "app_url": settings.public_url or None}


@admin_router.post("/mail/test")
async def mail_test(admin: CurrentUser = Depends(admin_user)):
    """Manda um e-mail de teste para o próprio admin."""
    row = await _row(get_pool(), admin.id)
    if not row["email"]:
        raise HTTPException(409, detail="Cadastre um e-mail na sua conta para receber o teste.")
    subject, text = notices.test(row["name"])
    try:
        await mail.send_or_raise(row["email"], subject, text)
    except mail.MailError as exc:
        raise HTTPException(502, detail=str(exc))
    return {"sent": True}


# ── Minha conta ──────────────────────────────────────────────────

def _mine(row) -> MyAccount:
    return _out(row, MyAccount, can_change_password=service.can_change_password(row),
                account_url=(settings.authentik_account_url or None)
                if service.managed(row) else None,
                mail_enabled=mail.enabled(), oidc_enabled=settings.oidc_enabled)


@me_router.get("/account", response_model=MyAccount)
async def my_account(user: CurrentUser = Depends(current_user)):
    return _mine(await _row(get_pool(), user.id))


@me_router.patch("/account", response_model=MyAccount)
async def update_my_account(body: AccountPatch, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    row = await _row(pool, user.id)
    # Conta ainda não ligada com o Authentik ligado: usuário e e-mail é que
    # vão casar as contas no 1º login. Se a própria pessoa pudesse trocar,
    # poria o e-mail do Authentik de outra e ficaria com o login dela.
    wants_identity = ((body.username is not None and body.username.strip() != row["username"])
                      or (body.email is not None
                          and (body.email.strip().lower() or None) != row["email"]))
    if settings.oidc_enabled and not service.linked(row) and wants_identity:
        raise HTTPException(409, detail="Enquanto sua conta não entrar pelo Authentik, usuário "
                                        "e e-mail só o administrador muda.")
    try:
        row, changes = await service.update_identity(
            pool, row, username=body.username, name=body.name, email=body.email,
            clear_email=body.email == "")
    except AccountError as exc:
        raise _fail(exc)
    await _tell_changes(row, changes)
    return _mine(row)


@me_router.post("/account/password", response_model=TokenPair)
async def change_my_password(body: PasswordChange, request: Request,
                             user: CurrentUser = Depends(current_user)):
    """Troca a própria senha. Derruba as outras sessões e devolve tokens novos
    para este aparelho seguir conectado."""
    pool = get_pool()
    row = await _row(pool, user.id)
    if not service.can_change_password(row):
        raise HTTPException(409, detail="Sua senha é a do Authentik: troque lá."
                            if service.managed(row) else "O login por senha está desligado.")
    from app.auth.security import verify_password
    if row["password_hash"] and not verify_password(row["password_hash"], body.current_password):
        raise HTTPException(403, detail="Senha atual incorreta.")
    try:
        await service.set_password(pool, row, body.new_password)
    except AccountError as exc:
        raise _fail(exc)
    await _tell(row, notices.password_changed(row["name"], by_admin=False))
    return await auth_service.issue_for(pool, row, request.headers.get("user-agent"))


# ── Esqueci a senha (público) ────────────────────────────────────

def _client_ip(request: Request) -> str:
    return request.headers.get("x-real-ip") or (request.client.host if request.client else "?")


def reset_enabled() -> bool:
    return settings.password_login_enabled and mail.enabled() and bool(settings.public_url)


@me_router.post("/password/forgot", status_code=202)
async def forgot_password(body: Forgot, request: Request, background: BackgroundTasks):
    """Manda o link de redefinir para o e-mail da conta. Responde igual com ou
    sem conta (não revela quem existe); limite por IP."""
    if not reset_enabled():
        raise HTTPException(403, detail="Redefinir senha por e-mail não está disponível.")
    ip = _client_ip(request)
    if await rate_limit.seconds_blocked("esqueci-a-senha", ip):
        raise HTTPException(429, detail="Muitos pedidos. Tente mais tarde.")
    await rate_limit.register_failure("esqueci-a-senha", ip)
    pool = get_pool()
    row = await service.find_for_reset(pool, body.login)
    if row is not None and row["email"] and service.can_change_password(row):
        token = await service.create_reset(pool, row["id"], settings.password_reset_hours)
        # Depois da resposta: o tempo de envio não denuncia quem tem conta.
        background.add_task(_tell, row, notices.reset_link(
            row["name"], service.reset_url(token), settings.password_reset_hours))
        logger.info("[contas] link de senha pedido para a conta %s", row["id"])
    return JSONResponse(
        {"detail": "Se houver uma conta com e-mail, o link chega em instantes."},
        status_code=202)


def _form(token: str, error: str = "") -> str:
    err = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return f"""{err}<form method="post">
<input type="hidden" name="token" value="{html.escape(token)}">
<label>Senha nova<input type="password" name="password" minlength="8" required
autocomplete="new-password" autofocus></label>
<label>Repita a senha<input type="password" name="confirm" minlength="8" required
autocomplete="new-password"></label>
<button type="submit">Salvar senha</button></form>"""


_INVALID = "Este link não vale mais (já foi usado ou venceu). Peça outro."


@me_router.get("/password/reset")
async def reset_form(token: str = Query("", max_length=200)):
    row = await service.peek_reset(get_pool(), token) if token else None
    if row is None:
        return page("Link inválido", _INVALID, "/", status_code=400)
    return page("Senha nova", f"Conta: {row['username']}", body=_form(token))


@me_router.post("/password/reset")
async def reset_submit(token: str = Form("", max_length=200),
                       password: str = Form("", max_length=256),
                       confirm: str = Form("", max_length=256)):
    pool = get_pool()
    if password != confirm:
        return page("Senha nova", "", body=_form(token, "As senhas não conferem."),
                    status_code=400)
    if len(password) < 8:
        return page("Senha nova", "",
                    body=_form(token, "A senha precisa ter pelo menos 8 caracteres."),
                    status_code=400)
    row = await service.use_reset(pool, token, password)
    if row is None:
        return page("Link inválido", _INVALID, "/", status_code=400)
    await _tell(row, notices.password_changed(row["name"], by_admin=False))
    logger.info("[contas] senha redefinida pelo link na conta %s", row["id"])
    return page("Senha salva", f"Pronto! Entre no Bergastream com o usuário "
                               f"\"{row['username']}\" e a senha nova.", "/")
