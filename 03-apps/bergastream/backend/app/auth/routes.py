"""Rotas de autenticação: /api/auth/*."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from app.auth import rate_limit, repository as repo, service
from app.auth.dependencies import CurrentUser, current_user
from app.auth.models import (
    AuthConfig,
    Credentials,
    RefreshRequest,
    RegisterRequest,
    TokenPair,
    UserOut,
)
from app.auth.security import hash_password
from app.config import settings
from app.core.db import get_pool

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
    return AuthConfig(registration_enabled=settings.allow_registration)


@router.post("/login", response_model=TokenPair)
async def login(body: Credentials, request: Request, response: Response):
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
    except service.InvalidCredentials:
        await rate_limit.register_failure(body.username, ip)
        logger.info("Login falhou para %r de %s", body.username, ip)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Usuário ou senha incorretos")
    await rate_limit.reset(body.username, ip)
    response.headers["Cache-Control"] = "no-store"
    return pair


@router.post("/register", response_model=TokenPair, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterRequest, request: Request, response: Response):
    if not settings.allow_registration:
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
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Usuário não existe mais")
    return UserOut(
        id=row["id"], username=row["username"], name=row["name"], is_admin=row["is_admin"]
    )
