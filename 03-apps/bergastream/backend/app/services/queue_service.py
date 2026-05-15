"""
Redis-backed download queue with 10 async workers.
Deduplicates by track_id. Priority queue for streaming requests.
"""
import asyncio
import json
import logging
from redis.asyncio import Redis
from app.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

QUEUE_HIGH = "bergastream:queue:high"    # streaming priority
QUEUE_LOW = "bergastream:queue:low"      # prefetch
DOWNLOADING_SET = "bergastream:downloading"


class DownloadQueueService:
    _redis: Redis | None = None

    @classmethod
    def _get_redis(cls) -> Redis:
        if cls._redis is None:
            cls._redis = Redis.from_url(settings.redis_url, decode_responses=True)
        return cls._redis

    @classmethod
    async def enqueue(cls, track_id: str, priority: bool = False, permanent: bool = False) -> None:
        r = cls._get_redis()
        is_downloading = await r.sismember(DOWNLOADING_SET, track_id)
        if is_downloading:
            return

        queue = QUEUE_HIGH if priority else QUEUE_LOW
        await r.rpush(queue, json.dumps({"track_id": track_id, "permanent": permanent}))

    @classmethod
    async def enqueue_batch(cls, track_ids: list[str], permanent: bool = False) -> None:
        r = cls._get_redis()
        for track_id in track_ids:
            is_downloading = await r.sismember(DOWNLOADING_SET, track_id)
            if not is_downloading:
                await r.rpush(QUEUE_LOW, json.dumps({"track_id": track_id, "permanent": permanent}))

    @classmethod
    async def _worker(cls, worker_id: int) -> None:
        from app.services import downloader_service
        from app.database import AsyncSessionLocal
        from sqlalchemy import select, update
        from app.models.track import Track
        from datetime import datetime, timezone, timedelta

        r = cls._get_redis()
        logger.info(f"Download worker {worker_id} started")

        while True:
            try:
                # High-priority first, then low
                item = await r.blpop([QUEUE_HIGH, QUEUE_LOW], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)

                # Mark as downloading
                await r.sadd(DOWNLOADING_SET, track_id)

                try:
                    async with AsyncSessionLocal() as db:
                        result = await db.execute(select(Track).where(Track.id == track_id))
                        track = result.scalar_one_or_none()
                        if track is None:
                            continue

                        # If permanent and already in cache, promote immediately
                        from pathlib import Path as _Path
                        from app.services.downloader_service import _resolve_existing, move_to_permanent
                        existing = _resolve_existing(track_id)
                        if existing:
                            if permanent and not str(existing).startswith(str(settings.music_permanent_path)):
                                perm = move_to_permanent(track_id)
                                if perm:
                                    await db.execute(
                                        update(Track).where(Track.id == track_id).values(
                                            file_path=str(perm),
                                            cache_path=None,
                                            cache_expires_at=None,
                                            is_permanent=True,
                                        )
                                    )
                                    await db.commit()
                                    logger.info(f"Worker {worker_id}: promoted {track_id} → permanent")
                            continue

                        path, quality = await downloader_service.ensure_track_file(
                            track_id, track.source, track.source_id or "", track.title, track.artist,
                            duration_ms=track.duration_ms,
                        )

                        if path:
                            if permanent:
                                perm = move_to_permanent(track_id)
                                final_path = perm or path
                                await db.execute(
                                    update(Track).where(Track.id == track_id).values(
                                        file_path=str(final_path),
                                        cache_path=None,
                                        cache_expires_at=None,
                                        is_permanent=True,
                                        audio_quality=quality,
                                    )
                                )
                                logger.info(f"Worker {worker_id}: downloaded permanent {track_id} → {final_path}")
                            else:
                                await db.execute(
                                    update(Track).where(Track.id == track_id).values(
                                        cache_path=str(path),
                                        audio_quality=quality,
                                        cache_expires_at=datetime.now(timezone.utc) + timedelta(hours=settings.cache_expire_hours),
                                    )
                                )
                                logger.info(f"Worker {worker_id}: downloaded {track_id} → {path}")
                            await db.commit()
                        else:
                            logger.warning(f"Worker {worker_id}: failed to download {track_id}")
                finally:
                    await r.srem(DOWNLOADING_SET, track_id)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Worker {worker_id} error: {e}")
                await asyncio.sleep(1)

    @classmethod
    async def start_workers(cls) -> None:
        workers = [
            asyncio.create_task(cls._worker(i))
            for i in range(settings.max_download_workers)
        ]
        await asyncio.gather(*workers, return_exceptions=True)
