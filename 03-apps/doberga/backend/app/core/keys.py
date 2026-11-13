"""Segredo do servidor: assina os JWT."""
from __future__ import annotations

import logging
import secrets

from app.config import settings

logger = logging.getLogger("doberga")

if settings.jwt_secret:
    SECRET = settings.jwt_secret
else:
    SECRET = secrets.token_urlsafe(48)
    logger.warning("JWT_SECRET vazio: usando um segredo aleatório. As sessões deixam de valer a "
                   "cada reinício. Defina JWT_SECRET no .env.")
