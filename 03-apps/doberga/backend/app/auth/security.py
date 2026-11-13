"""Access tokens (JWT, curtos) e refresh tokens (opacos, só o hash no banco)."""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

import jwt

from app.config import settings
from app.core.keys import SECRET

_ALGORITHM = "HS256"
_ISSUER = "doberga"


class TokenError(Exception):
    """Token ausente, inválido, expirado ou do tipo errado."""


def create_access_token(user_id: str, is_admin: bool) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode({
        "sub": user_id, "adm": is_admin, "typ": "access", "iss": _ISSUER,
        "iat": now, "exp": now + timedelta(minutes=settings.access_token_minutes),
    }, SECRET, algorithm=_ALGORITHM)


def decode_token(token: str, expected_type: str) -> dict:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[_ALGORITHM], issuer=_ISSUER,
                             options={"require": ["exp", "sub", "typ"]})
    except jwt.PyJWTError as e:
        raise TokenError(str(e)) from e
    if payload.get("typ") != expected_type:
        raise TokenError("tipo de token incorreto")
    return payload


def new_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
