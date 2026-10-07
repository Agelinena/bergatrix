"""Situação do servidor para Ajustes: GET /api/server/status.

Quantas músicas estão baixadas, quanto espaço ocupam, espaço livre no disco,
fila de downloads do Bergastream e a fila do Deemix.
"""
from __future__ import annotations

import asyncio
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


class DeemixQueue(BaseModel):
    available: bool
    downloading: int = 0
    waiting: int = 0
    failed: int = 0
    completed: int = 0
    items: list[DeemixItem] = []


class ServerStatus(BaseModel):
    storage: Storage
    queue: DownloadQueue
    deemix: DeemixQueue


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


@router.get("/server/status", response_model=ServerStatus)
async def server_status(user: CurrentUser = Depends(current_user)):
    storage, queue, deemix = await asyncio.gather(_storage(), _queue(), _deemix())
    return ServerStatus(storage=storage, queue=queue, deemix=deemix)
