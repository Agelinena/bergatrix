import asyncio
import logging
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from app.config import get_settings
from app.routers import auth, search, stream, library, playlists, history, radio, users, admin, resolve
from app.routers.users import offline_router

settings = get_settings()
logging.basicConfig(level=getattr(logging, settings.log_level))
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("BergaStream API starting up")
    from app.services.cleanup_service import CleanupService
    from app.services.queue_service import DownloadQueueService

    cleanup_task = asyncio.create_task(CleanupService.run_periodic())
    queue_task = asyncio.create_task(DownloadQueueService.start_workers())

    yield

    cleanup_task.cancel()
    queue_task.cancel()
    logger.info("BergaStream API shut down")


app = FastAPI(
    title="BergaStream API",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/api")
app.include_router(search.router, prefix="/api")
app.include_router(stream.router, prefix="/api")
app.include_router(library.router, prefix="/api")
app.include_router(playlists.router, prefix="/api")
app.include_router(history.router, prefix="/api")
app.include_router(radio.router, prefix="/api")
app.include_router(users.router, prefix="/api")
app.include_router(offline_router, prefix="/api")
app.include_router(admin.router, prefix="/api")
app.include_router(resolve.router, prefix="/api")


os.makedirs(settings.media_covers_path, exist_ok=True)
app.mount("/media/covers", StaticFiles(directory=settings.media_covers_path), name="covers")


@app.get("/api/health")
async def health():
    return {"status": "ok", "service": "bergastream-api"}
