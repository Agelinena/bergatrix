"""Segredo do servidor: assina os JWT e os links de imagem."""
from __future__ import annotations

import hashlib
import hmac
import logging
import secrets

from app.config import settings

logger = logging.getLogger("berganews")

if settings.jwt_secret:
    SECRET = settings.jwt_secret
else:
    SECRET = secrets.token_urlsafe(48)
    logger.warning("JWT_SECRET vazio: usando um segredo aleatório. As sessões e os links de "
                   "imagem deixam de valer a cada reinício. Defina JWT_SECRET no .env.")


def sign(purpose: str, value: str, length: int = 22) -> str:
    key = hashlib.sha256(f"{purpose}:{SECRET}".encode()).digest()
    return hmac.new(key, value.encode(), hashlib.sha256).hexdigest()[:length]


def verify(purpose: str, value: str, signature: str, length: int = 22) -> bool:
    return hmac.compare_digest(sign(purpose, value, length), signature or "")
