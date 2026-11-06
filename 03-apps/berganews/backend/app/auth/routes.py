"""Rotas de autenticação: /api/auth/*. Só pelo Authentik (OIDC)."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import RedirectResponse

from app.auth import oidc, repository as repo, service
from app.auth.dependencies import CurrentUser, current_user
from app.auth.models import AuthConfig, OIDCExchange, RefreshRequest, TokenPair, UserOut
from app.config import settings
from app.core.db import get_pool
from app.core.pages import page
from app.core.redis import get_redis

logger = logging.getLogger("berganews.auth")
router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.get("/config", response_model=AuthConfig)
async def config():
    return AuthConfig(oidc_enabled=settings.oidc_enabled,
                      account_url=settings.authentik_account_url)


@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshRequest, request: Request, response: Response):
    try:
        pair = await service.refresh(get_pool(), body.refresh_token,
                                     request.headers.get("user-agent"))
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
    return service.user_out(row)


@router.get("/oidc/start")
async def oidc_start(redirect: str = Query(..., max_length=300),
                     challenge: str = Query(..., max_length=128)):
    """O app abre esta página no navegador: vai para o login do Authentik."""
    if not settings.oidc_enabled:
        return page("Login indisponível", "O login pelo Authentik não está configurado neste servidor.")
    try:
        url = await oidc.begin(await get_redis(), redirect, challenge)
    except oidc.OIDCError as exc:
        return page("Não foi possível entrar", str(exc))
    except Exception as exc:  # Authentik fora do ar, discovery inválida
        logger.warning("[oidc] início do login falhou: %s", exc)
        return page("Authentik indisponível",
                    "Não foi possível falar com o Authentik. Tente de novo em instantes.")
    return RedirectResponse(url, status_code=302, headers={"Cache-Control": "no-store"})


@router.get("/oidc/callback")
async def oidc_callback(code: str = "", state: str = "", error: str = "",
                        error_description: str = ""):
    """O Authentik volta aqui; o servidor confere tudo e devolve o app."""
    if error:
        message = "Login cancelado." if error == "access_denied" else (error_description or error)
        return page("Não foi possível entrar", message, "/")
    redis = await get_redis()
    try:
        identity, pending = await oidc.finish(redis, code, state)
        user = await oidc.link_user(get_pool(), identity)
        one_time = await oidc.issue_code(redis, str(user["id"]), pending["app_challenge"])
    except oidc.OIDCError as exc:
        return page("Não foi possível entrar", str(exc), "/")
    except Exception as exc:
        logger.exception("[oidc] callback falhou: %s", exc)
        return page("Não foi possível entrar", "Erro inesperado no servidor. Tente de novo.", "/")
    logger.info("[oidc] login de %s", identity.username)
    target = oidc.with_query(pending["redirect"], oidc_code=one_time)
    return RedirectResponse(target, status_code=302, headers={"Cache-Control": "no-store"})


@router.post("/oidc/exchange", response_model=TokenPair)
async def oidc_exchange(body: OIDCExchange, request: Request, response: Response):
    """O app troca o código de uso único pelos tokens do Berganews."""
    user_id = await oidc.redeem_code(await get_redis(), body.code, body.verifier)
    row = await repo.get_user_by_id(get_pool(), user_id) if user_id else None
    if row is None or row["disabled_at"] is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Login expirado. Tente de novo.")
    response.headers["Cache-Control"] = "no-store"
    return await service.issue_for(get_pool(), row, request.headers.get("user-agent"))
