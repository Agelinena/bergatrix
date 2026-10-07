"""Senhas (Argon2), access tokens (JWT) e tokens opacos."""
from __future__ import annotations

import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from app.config import settings

logger = logging.getLogger("bergastream.auth")

_hasher = PasswordHasher()
_ALGORITHM = "HS256"
_ISSUER = "bergastream"

if settings.jwt_secret:
    _secret = settings.jwt_secret
else:
    _secret = secrets.token_urlsafe(48)
    logger.warning(
        "JWT_SECRET vazio: usando um segredo aleatório. As sessões caem a cada "
        "reinício da API. Defina JWT_SECRET no .env."
    )

# Hash usado quando o usuário não existe, para o tempo de resposta não revelar
# quais usernames existem.
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(16))


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        return _hasher.verify(password_hash or _DUMMY_HASH, password) and bool(
            password_hash
        )
    except (VerificationError, InvalidHashError):
        return False


def _now() -> datetime:
    return datetime.now(timezone.utc)


def create_access_token(user_id: str, is_admin: bool) -> str:
    now = _now()
    payload = {
        "sub": user_id,
        "adm": is_admin,
        "typ": "access",
        "iss": _ISSUER,
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_minutes),
    }
    return jwt.encode(payload, _secret, algorithm=_ALGORITHM)


def create_stream_token(user_id: str, track_id: str) -> str:
    """Token curto para `?t=` no stream: o `<audio>` da web não envia o
    cabeçalho Authorization. Vale só para uma faixa."""
    now = _now()
    payload = {
        "sub": user_id,
        "trk": track_id,
        "typ": "stream",
        "iss": _ISSUER,
        "iat": now,
        "exp": now + timedelta(hours=settings.stream_token_hours),
    }
    return jwt.encode(payload, _secret, algorithm=_ALGORITHM)


class TokenError(Exception):
    """Token ausente, inválido, expirado ou do tipo errado."""


def decode_token(token: str, expected_type: str) -> dict:
    try:
        payload = jwt.decode(
            token,
            _secret,
            algorithms=[_ALGORITHM],
            issuer=_ISSUER,
            options={"require": ["exp", "sub", "typ"]},
        )
    except jwt.PyJWTError as e:
        raise TokenError(str(e)) from e
    if payload.get("typ") != expected_type:
        raise TokenError("tipo de token incorreto")
    return payload


def new_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
