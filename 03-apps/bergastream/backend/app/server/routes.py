"""Situação do servidor para Ajustes: GET /api/server/status.

Quantas músicas estão baixadas, quanto espaço ocupam, espaço livre no disco,
fila de downloads do Bergastream, a fila do Deemix, a qualidade das faixas
(e a fila de melhoria das playlists) e o último teste do Spotify.
"""
from __future__ import annotations

import asyncio
import json
import shutil

import httpx
from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core.db import get_pool
from app.core.redis import get_redis
from app.downloads import queue as q

router = APIRouter(prefix="/api", tags=["server"])

# Itens mostrados da fila do Deemix (os mais relevantes primeiro).
_DEEMIX_ITEMS = 30
_ORDER = {"downloading": 0, "inQueue": 1, "failed": 2, "completed": 3}


class Storage(BaseModel):
    tracks: int
    permanent: int
    cache: int
    bytes: int
    bytes_permanent: int
    bytes_cache: int
    disk_total: int | None = None
    disk_free: int | None = None


class DownloadQueue(BaseModel):
    waiting: int     # na fila do Bergastream, ainda não começaram
    active: int      # baixando agora


class DeemixItem(BaseModel):
    title: str
    artist: str
    status: str      # downloading | inQueue | failed | completed
    progress: int = 0


class DeemixFailure(BaseModel):
    title: str
    artist: str
    error: str
    recovered: bool  # baixada pelo YouTube no lugar
    at: str


class DeemixQueue(BaseModel):
    available: bool
    downloading: int = 0
    waiting: int = 0
    failed: int = 0
    completed: int = 0
    items: list[DeemixItem] = []
    # Falhas recentes registradas pelo servidor (o item sai da fila do Deemix).
    recent_failures: list[DeemixFailure] = []


class QualityStatus(BaseModel):
    # Faixas baixadas por qualidade (audio_info.rank).
    lossless: int = 0     # FLAC (16 ou 24 bits)
    high: int = 0         # MP3 320
    medium: int = 0       # MP3 192 / Opus do YouTube
    low: int = 0          # MP3 128
    unknown: int = 0      # ainda não medidas
    # Faixas de playlist buscando qualidade melhor.
    upgrades_pending: int = 0
    upgrades_waiting: int = 0   # aguardando o Lidarr achar na Usenet
    upgrades_done: int = 0
    lidarr: bool = False


class ServerStatus(BaseModel):
    storage: Storage
    queue: DownloadQueue
    deemix: DeemixQueue
    quality: QualityStatus | None = None
    # Último teste diário do Spotify (ver app.search.spotify_health).
    spotify: dict | None = None


async def _storage() -> Storage:
    row = await get_pool().fetchrow(
        """SELECT count(*) AS tracks,
                  count(*) FILTER (WHERE kind = 'permanent') AS permanent,
                  count(*) FILTER (WHERE kind = 'cache') AS cache,
                  coalesce(sum(size_bytes), 0) AS bytes,
                  coalesce(sum(size_bytes) FILTER (WHERE kind = 'permanent'), 0) AS bytes_permanent,
                  coalesce(sum(size_bytes) FILTER (WHERE kind = 'cache'), 0) AS bytes_cache
           FROM files""")
    storage = Storage(**{k: int(row[k]) for k in row.keys()})
    try:
        usage = await asyncio.to_thread(shutil.disk_usage, settings.music_dir)
        storage.disk_total, storage.disk_free = usage.total, usage.free
    except OSError:
        pass
    return storage


async def _queue() -> DownloadQueue:
    redis = await get_redis()
    waiting = sum([await redis.llen(name) for name in q.PRIORITY_QUEUES.values()])
    return DownloadQueue(waiting=waiting, active=await q.active_count(redis))


async def _deemix() -> DeemixQueue:
    try:
        async with httpx.AsyncClient(base_url=settings.deemix_url, timeout=5) as cli:
            await cli.get("/api/connect")
            data = (await cli.get("/api/getQueue")).json() or {}
    except (httpx.HTTPError, ValueError):
        return DeemixQueue(available=False)
    queue = data.get("queue") or {}
    counts = {"downloading": 0, "inQueue": 0, "failed": 0, "completed": 0}
    items = []
    for item in queue.values():
        status = item.get("status") or "inQueue"
        counts[status] = counts.get(status, 0) + 1
        items.append(DeemixItem(
            title=str(item.get("title") or ""), artist=str(item.get("artist") or ""),
            status=status, progress=int(item.get("progress") or 0)))
    items.sort(key=lambda i: _ORDER.get(i.status, 9))
    return DeemixQueue(
        available=True, downloading=counts["downloading"], waiting=counts["inQueue"],
        failed=counts["failed"], completed=counts["completed"],
        items=[i for i in items if i.status != "completed"][:_DEEMIX_ITEMS])


async def _failures() -> list[DeemixFailure]:
    redis = await get_redis()
    raw = await redis.lrange("bergastream:deemix:failures", 0, 49)
    out = []
    for item in raw:
        try:
            out.append(DeemixFailure(**json.loads(item)))
        except (ValueError, TypeError):
            continue
    return out


async def _quality() -> QualityStatus:
    from app.quality.lidarr import enabled
    pool = get_pool()
    ranks = await pool.fetchrow(
        """SELECT count(*) FILTER (WHERE quality_rank >= 40) AS lossless,
                  count(*) FILTER (WHERE quality_rank = 30) AS high,
                  count(*) FILTER (WHERE quality_rank = 20) AS medium,
                  count(*) FILTER (WHERE quality_rank = 10) AS low,
                  count(*) FILTER (WHERE quality_rank = 0) AS unknown
           FROM files""")
    upgrades = {r["status"]: r["n"] for r in await pool.fetch(
        "SELECT status, count(*) AS n FROM quality_upgrades GROUP BY status")}
    return QualityStatus(
        **{k: int(ranks[k]) for k in ranks.keys()},
        upgrades_pending=upgrades.get("pending", 0), upgrades_waiting=upgrades.get("waiting", 0),
        upgrades_done=upgrades.get("done", 0), lidarr=enabled())


async def _spotify() -> dict | None:
    from app.search.spotify_health import read_health
    try:
        return await read_health(await get_redis())
    except Exception:
        return None


@router.get("/server/status", response_model=ServerStatus)
async def server_status(user: CurrentUser = Depends(current_user)):
    storage, queue, deemix, failures, quality, spotify = await asyncio.gather(
        _storage(), _queue(), _deemix(), _failures(), _quality(), _spotify())
    deemix.recent_failures = failures
    return ServerStatus(storage=storage, queue=queue, deemix=deemix, quality=quality, spotify=spotify)
