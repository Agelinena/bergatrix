"""Dependências do FastAPI: usuário atual e admin."""
from __future__ import annotations

from dataclasses import dataclass

from fastapi import Depends, HTTPException, Query, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.security import TokenError, decode_token

_bearer = HTTPBearer(auto_error=False)

_UNAUTHORIZED = HTTPException(
    status.HTTP_401_UNAUTHORIZED,
    detail="Não autenticado",
    headers={"WWW-Authenticate": "Bearer"},
)


@dataclass(frozen=True)
class CurrentUser:
    id: str
    is_admin: bool


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> CurrentUser:
    if credentials is None:
        raise _UNAUTHORIZED
    try:
        payload = decode_token(credentials.credentials, "access")
    except TokenError:
        raise _UNAUTHORIZED
    return CurrentUser(id=payload["sub"], is_admin=bool(payload.get("adm")))


async def admin_user(user: CurrentUser = Depends(current_user)) -> CurrentUser:
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Só administradores")
    return user


async def stream_user(
    track_id: str,
    t: str | None = Query(None, description="Token de stream (web)"),
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> CurrentUser:
    """Aceita o Bearer normal (app) ou `?t=` com token de stream da faixa (web)."""
    if credentials is not None:
        return await current_user(credentials)
    if not t:
        raise _UNAUTHORIZED
    try:
        payload = decode_token(t, "stream")
    except TokenError:
        raise _UNAUTHORIZED
    if payload.get("trk") != track_id:
        raise _UNAUTHORIZED
    return CurrentUser(id=payload["sub"], is_admin=False)
