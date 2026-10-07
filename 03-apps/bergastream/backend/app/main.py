"""Bergastream — Entrypoint da API."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.core.db import create_pool, close_pool
from app.api.routes import router as api_router
from app.auth.routes import router as auth_router
from app.playlists.routes import router as playlists_router
from app.history.routes import router as history_router
from app.images.routes import router as images_router

logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("bergastream")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Iniciando pool DB e Redis...")
    pool = await create_pool()
    from app.auth.repository import delete_expired_refresh_tokens
    removed = await delete_expired_refresh_tokens(pool)
    if removed:
        logger.info("Refresh tokens vencidos removidos: %d", removed)
    from app.core.redis import get_redis
    await get_redis()

    for d in ("cache", "deemix_dl", "permanent"):
        (Path(settings.music_dir) / d).mkdir(parents=True, exist_ok=True)

    # Faixas em playlist que ficaram como cache (ou o contrário): conserta.
    from app.storage.permanence import reconcile
    await reconcile(pool)

    from app.storage.service import run_forever as cl
    t = asyncio.create_task(cl(pool))
    logger.info("Limpeza agendada (1h)")
    logger.info("API pronta")
    yield
    t.cancel()
    logger.info("Encerrando...")
    await close_pool()


app = FastAPI(title="Bergastream", version="0.2.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok", "version": "0.2.0"})


app.include_router(auth_router)
app.include_router(playlists_router)
app.include_router(history_router)
app.include_router(images_router)
app.include_router(api_router)

_st = Path(__file__).parent.parent / "static"
if _st.is_dir():
    app.mount("/", StaticFiles(directory=str(_st), html=True), name="static")