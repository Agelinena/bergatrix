"""Berganews — API."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app.articles.routes import router as articles_router
from app.auth.repository import delete_expired_refresh_tokens
from app.auth.routes import router as auth_router
from app.config import settings
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
from app.feeds.routes import router as feeds_router
from app.images.routes import router as images_router
from app.prefs.routes import router as prefs_router
from app.stories.routes import admin_router as stories_admin_router
from app.stories.routes import router as stories_router
from app.users.routes import router as users_router

VERSION = "0.2.0"

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO),
                    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("berganews")


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool = await create_pool()
    removed = await delete_expired_refresh_tokens(pool)
    if removed:
        logger.info("Refresh tokens vencidos removidos: %d", removed)
    await get_redis()
    logger.info("API pronta (versão %s)", VERSION)
    yield
    await close_redis()
    await close_pool()


# Sem /docs públicos: a API é só do app.
app = FastAPI(title="Berganews", version=VERSION, lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok", "version": VERSION})


for router in (auth_router, users_router, prefs_router, feeds_router, articles_router,
               stories_router, stories_admin_router, images_router):
    app.include_router(router)
