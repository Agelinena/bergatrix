"""Doberga — API."""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager, suppress

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app import modules  # noqa: F401  (registra as tabelas dos módulos no sync)
from app.auth.repository import delete_expired_refresh_tokens
from app.auth.routes import router as auth_router
from app.config import settings
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
from app.prefs.routes import router as prefs_router
from app.spaces.routes import router as spaces_router
from app.sync import engine
from app.sync.routes import router as sync_router
from app.users.routes import router as users_router

VERSION = "0.1.0"

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO),
                    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("doberga")

CLEANUP_HOURS = 6


async def _maintenance(pool) -> None:
    """Limpeza periódica: lápides, operações aplicadas, convites, sessões."""
    while True:
        try:
            done = await engine.cleanup(pool, settings.sync_retention_days)
            tokens = await delete_expired_refresh_tokens(pool)
            if any(done.values()) or tokens:
                logger.info("Limpeza: %s, sessões vencidas: %d", done, tokens)
        except Exception as exc:
            logger.warning("Limpeza falhou: %s", exc)
        await asyncio.sleep(CLEANUP_HOURS * 3600)


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool = await create_pool()
    await get_redis()
    task = asyncio.create_task(_maintenance(pool))
    logger.info("API pronta (versão %s)", VERSION)
    yield
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task
    await close_redis()
    await close_pool()


# Sem /docs públicos: a API é só do app.
app = FastAPI(title="Doberga", version=VERSION, lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok", "version": VERSION})


@app.get("/api/app/version")
async def app_version():
    """O app confere ao abrir: abaixo da mínima, pede para atualizar."""
    return {"server": VERSION, "min_version": settings.app_min_version,
            "latest_version": settings.app_latest_version or None,
            "download_url": settings.app_download_url or None,
            "sync_protocol": settings.sync_protocol,
            "sync_min_protocol": settings.sync_min_protocol}


for router in (auth_router, users_router, prefs_router, spaces_router, sync_router):
    app.include_router(router)
