"""Rotas de autenticação: /api/auth/*."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import RedirectResponse

from app.auth import rate_limit, repository as repo, service
from app.auth.dependencies import CurrentUser, current_user
from app.auth.models import (
    AuthConfig,
    Credentials,
    OIDCExchange,
    RefreshRequest,
    RegisterRequest,
    TokenPair,
    UserOut,
)
from app.auth.security import hash_password
from app.config import settings
from app.core.db import get_pool
from app.core.pages import page
from app.core.redis import get_redis
from app.auth import oidc
from app.accounts import routes as accounts

logger = logging.getLogger("bergastream.auth")
router = APIRouter(prefix="/api/auth", tags=["auth"])


def _client_ip(request: Request) -> str:
    # Atrás do nginx do app web o IP real vem em X-Real-IP.
    return request.headers.get("x-real-ip") or (
        request.client.host if request.client else "?"
    )


@router.get("/config", response_model=AuthConfig)
async def config():
    """Público: o app usa para mostrar ou não o link "Criar conta"."""
    return AuthConfig(
        registration_enabled=settings.allow_registration and settings.password_login_enabled,
        oidc_enabled=settings.oidc_enabled,
        password_login_enabled=settings.password_login_enabled,
        password_reset_enabled=accounts.reset_enabled(),
    )


@router.post("/login", response_model=TokenPair)
async def login(body: Credentials, request: Request, response: Response):
    if not settings.password_login_enabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Entre pelo Authentik")
    ip = _client_ip(request)
    wait = await rate_limit.seconds_blocked(body.username, ip)
    if wait:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Muitas tentativas. Tente novamente mais tarde.",
            headers={"Retry-After": str(wait)},
        )
    try:
        pair = await service.login(
            get_pool(), body.username, body.password, request.headers.get("user-agent")
        )
    except service.AccountDisabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Conta desativada")
    except service.InvalidCredentials:
        await rate_limit.register_failure(body.username, ip)
        logger.info("Login falhou para %r de %s", body.username, ip)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Usuário ou senha incorretos")
    await rate_limit.reset(body.username, ip)
    response.headers["Cache-Control"] = "no-store"
    return pair


@router.post("/register", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterRequest, request: Request, response: Response):
    if not settings.allow_registration or not settings.password_login_enabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Cadastro desativado")
    pool = get_pool()
    if await repo.get_user_by_username(pool, body.username):
        raise HTTPException(status.HTTP_409_CONFLICT, detail="Usuário já existe")
    await repo.create_user(pool, body.username, hash_password(body.password))
    response.headers["Cache-Control"] = "no-store"
    return await service.login(
        pool, body.username, body.password, request.headers.get("user-agent")
    )


@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshRequest, request: Request, response: Response):
    try:
        pair = await service.refresh(
            get_pool(), body.refresh_token, request.headers.get("user-agent")
        )
    except service.InvalidRefreshToken:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Sessão expirada")
    response.headers["Cache-Control"] = "no-store"
    return pair


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(body: RefreshRequest):
    await service.logout(get_pool(), body.refresh_token)


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser = Depends(current_user)):
    row = await repo.get_user_by_id(get_pool(), user.id)
    if row is None or row["disabled_at"] is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Usuário não existe mais")
    return UserOut(
        id=row["id"], username=row["username"], name=row["name"], is_admin=row["is_admin"]
    )


# ── Login pelo Authentik (OIDC) ──────────────────────────────────────

def _page(title: str, message: str, back: str | None = None):
    """Página simples no navegador (erro do login, ou "pode voltar ao app")."""
    return page(title, message, back)


@router.get("/oidc/start")
async def oidc_start(redirect: str = Query(..., max_length=300),
                     challenge: str = Query(..., max_length=128)):
    """O app abre esta página no navegador: vai para o login do Authentik."""
    if not settings.oidc_enabled:
        return _page("Login indisponível", "O login pelo Authentik não está configurado neste servidor.")
    try:
        url = await oidc.begin(await get_redis(), redirect, challenge)
    except oidc.OIDCError as exc:
        return _page("Não foi possível entrar", str(exc))
    except Exception as exc:  # Authentik fora do ar, discovery inválida
        logger.warning("[oidc] início do login falhou: %s", exc)
        return _page("Authentik indisponível", "Não foi possível falar com o Authentik. Tente de novo em instantes.")
    return RedirectResponse(url, status_code=302, headers={"Cache-Control": "no-store"})


@router.get("/oidc/callback")
async def oidc_callback(code: str = "", state: str = "", error: str = "",
                        error_description: str = ""):
    """O Authentik volta aqui; o servidor confere tudo e devolve o app."""
    if error:
        message = "Login cancelado." if error == "access_denied" else (error_description or error)
        return _page("Não foi possível entrar", message, "/")
    redis = await get_redis()
    try:
        identity, pending = await oidc.finish(redis, code, state)
        user = await oidc.link_user(get_pool(), identity)
        one_time = await oidc.issue_code(redis, str(user["id"]), pending["app_challenge"])
    except oidc.OIDCError as exc:
        return _page("Não foi possível entrar", str(exc), "/")
    except Exception as exc:
        logger.exception("[oidc] callback falhou: %s", exc)
        return _page("Não foi possível entrar", "Erro inesperado no servidor. Tente de novo.", "/")
    logger.info("[oidc] login de %s", identity.username)
    target = oidc.with_query(pending["redirect"], oidc_code=one_time)
    return RedirectResponse(target, status_code=302, headers={"Cache-Control": "no-store"})


@router.post("/oidc/exchange", response_model=TokenPair)
async def oidc_exchange(body: OIDCExchange, request: Request, response: Response):
    """O app troca o código de uso único pelos tokens do Bergastream."""
    user_id = await oidc.redeem_code(await get_redis(), body.code, body.verifier)
    row = await repo.get_user_by_id(get_pool(), user_id) if user_id else None
    if row is None or row["disabled_at"] is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Login expirado. Tente de novo.")
    response.headers["Cache-Control"] = "no-store"
    return await service.issue_for(get_pool(), row, request.headers.get("user-agent"))
