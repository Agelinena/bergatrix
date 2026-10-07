"""Worker de downloads — processo isolado."""
from __future__ import annotations
import asyncio
import logging
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from app.config import settings
from app.core.redis import get_redis, close_redis
from app.downloads import queue as q
from app.downloads import deemix, youtube as yt_downloader
from app.core.db import create_pool, close_pool
from app.tracks import repository as track_repo

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO), format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("bergastream.worker")
MAX_CONCURRENT = 2; _POLL_TIMEOUT = 3


async def process_job(redis, pool, job_id: str) -> None:
    job = await q.get_job(redis, job_id)
    if not job:
        return
    track_id = job["track_id"]; provider = job.get("provider", "spotify")
    if not await q.mark_active(redis, track_id):
        return
    await q.set_job_status(redis, job_id, "downloading")
    logger.info("[worker] processando %s (%s)", track_id[:8], provider)
    try:
        metadata = await track_repo.get_track_by_id(pool, track_id)
        if not metadata:
            await q.set_job_status(redis, job_id, "error", error="Track nao encontrada")
            return
        from app.downloads.service import _do_download_deezer, _do_download_spotify, _do_download_youtube_direct
        from app.tracks.models import PlayRequest
        req = PlayRequest(provider=provider, external_id=job.get("external_id", ""),
            title=metadata.title, artist=metadata.artist, album=metadata.album or "",
            duration_seconds=metadata.duration_seconds, isrc=metadata.isrc, cover_url=metadata.cover_url)
        if provider in ("youtube", "ytmusic"):
            success, prov = await _do_download_youtube_direct(job.get("external_id", ""), track_id)
        elif provider == "deezer":
            success, prov = await _do_download_deezer(req, track_id)
        else:
            success, prov = await _do_download_spotify(req, track_id)
        if success:
            await q.set_job_status(redis, job_id, "done", provider_used=prov or "")
        else:
            await q.set_job_status(redis, job_id, "error", error="Falhou")
    except Exception as exc:
        logger.exception("[worker] erro em %s: %s", track_id[:8], exc)
        await q.set_job_status(redis, job_id, "error", error=str(exc))
    finally:
        await q.mark_done(redis, track_id)


async def main_loop() -> None:
    redis = await get_redis()
    pool = await create_pool()
    logger.info("[worker] iniciado (max_concurrent=%d)", MAX_CONCURRENT)
    active_tasks = set()
    def _clean(t): active_tasks.discard(t)
    while True:
        while len(active_tasks) < MAX_CONCURRENT:
            job_id = await q.dequeue(redis, timeout=_POLL_TIMEOUT)
            if not job_id:
                break
            t = asyncio.create_task(process_job(redis, pool, job_id))
            active_tasks.add(t); t.add_done_callback(_clean)
        await asyncio.sleep(0.1)


async def main():
    try:
        await main_loop()
    finally:
        await close_pool()
        await close_redis()

if __name__ == "__main__":
    asyncio.run(main())
