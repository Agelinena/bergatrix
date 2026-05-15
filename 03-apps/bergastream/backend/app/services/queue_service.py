"""
Redis-backed download queue with isolated worker pools.

Stream workers  (QUEUE_HIGH): pull exclusively from the high-priority queue.
  — No inter-job throttle; serve streaming/on-demand requests as fast as possible.

Background workers (QUEUE_LOW): pull exclusively from the low-priority queue.
  — 3-second sleep between jobs to avoid hammering external APIs.
  — Failed jobs are re-queued with exponential backoff (up to _MAX_RETRIES times).
"""
import asyncio
import json
import logging
from redis.asyncio import Redis
from app.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

QUEUE_HIGH = "bergastream:queue:high"    # streaming priority (on-demand)
QUEUE_LOW  = "bergastream:queue:low"     # prefetch / bulk background downloads
DOWNLOADING_SET = "bergastream:downloading"

_MAX_RETRIES = 2
_BACKGROUND_INTER_JOB_SLEEP = 3.0  # seconds between background jobs


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

    # -------------------------------------------------------------------------
    # Shared job processor
    # -------------------------------------------------------------------------

    @classmethod
    async def _process_job(cls, label: str, payload: dict) -> bool:
        """
        Process a single download job.
        Returns True on success (or when the track is not found / already done),
        False when the download itself failed (worth retrying).
        """
        from app.services import downloader_service
        from app.database import AsyncSessionLocal
        from sqlalchemy import select, update
        from app.models.track import Track
        from datetime import datetime, timezone, timedelta

        r = cls._get_redis()
        track_id = payload["track_id"]
        permanent = payload.get("permanent", False)

        await r.sadd(DOWNLOADING_SET, track_id)
        try:
            async with AsyncSessionLocal() as db:
                result = await db.execute(select(Track).where(Track.id == track_id))
                track = result.scalar_one_or_none()
                if track is None:
                    logger.debug(f"[{label}] Track {track_id} not found in DB — skipping")
                    return True

                from app.services.downloader_service import _resolve_existing, move_to_permanent

                existing = _resolve_existing(track_id)
                if existing:
                    if permanent and not str(existing).startswith(
                        str(settings.music_permanent_path)
                    ):
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
                            logger.info(f"[{label}] Promoted {track_id} → permanent")
                    return True  # already on disk, nothing to download

                path, quality = await downloader_service.ensure_track_file(
                    track_id,
                    track.source,
                    track.source_id or "",
                    track.title,
                    track.artist,
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
                        logger.info(f"[{label}] Downloaded permanent {track_id} → {final_path}")
                    else:
                        await db.execute(
                            update(Track).where(Track.id == track_id).values(
                                cache_path=str(path),
                                audio_quality=quality,
                                cache_expires_at=datetime.now(timezone.utc)
                                + timedelta(hours=settings.cache_expire_hours),
                            )
                        )
                        logger.info(f"[{label}] Downloaded {track_id} → {path}")
                    await db.commit()
                    return True
                else:
                    logger.warning(f"[{label}] Failed to download {track_id}")
                    return False

        finally:
            await r.srem(DOWNLOADING_SET, track_id)

    # -------------------------------------------------------------------------
    # Stream worker — QUEUE_HIGH only, no throttle
    # -------------------------------------------------------------------------

    @classmethod
    async def _stream_worker(cls, worker_id: int) -> None:
        """
        High-priority worker: pulls exclusively from QUEUE_HIGH.
        No inter-job sleep — serves on-demand streaming requests immediately.
        """
        r = cls._get_redis()
        label = f"stream-{worker_id}"
        logger.info(f"[{label}] Stream worker started")

        while True:
            try:
                item = await r.blpop([QUEUE_HIGH], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                logger.debug(f"[{label}] Processing {payload['track_id']}")
                await cls._process_job(label, payload)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"[{label}] Unhandled error: {e}")
                await asyncio.sleep(1)

    # -------------------------------------------------------------------------
    # Background worker — QUEUE_LOW only, throttled, with retry
    # -------------------------------------------------------------------------

    @classmethod
    async def _background_worker(cls, worker_id: int) -> None:
        """
        Background worker: pulls exclusively from QUEUE_LOW.
        Sleeps _BACKGROUND_INTER_JOB_SLEEP seconds between jobs to avoid rate limits.
        Re-queues failed jobs with exponential backoff (up to _MAX_RETRIES times).
        """
        r = cls._get_redis()
        label = f"bg-{worker_id}"
        logger.info(f"[{label}] Background worker started")

        while True:
            try:
                item = await r.blpop([QUEUE_LOW], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                retries = payload.get("retries", 0)
                track_id = payload["track_id"]

                logger.debug(
                    f"[{label}] Processing {track_id} "
                    f"(attempt {retries + 1}/{_MAX_RETRIES + 1})"
                )
                success = await cls._process_job(label, payload)

                if not success and retries < _MAX_RETRIES:
                    wait = 30 * (retries + 1)   # 30 s, 60 s
                    logger.info(
                        f"[{label}] Requeueing {track_id} in {wait}s "
                        f"(retry {retries + 1}/{_MAX_RETRIES})"
                    )
                    await asyncio.sleep(wait)
                    payload["retries"] = retries + 1
                    await r.rpush(QUEUE_LOW, json.dumps(payload))

                # Throttle: pause before picking up the next background job
                await asyncio.sleep(_BACKGROUND_INTER_JOB_SLEEP)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"[{label}] Unhandled error: {e}")
                await asyncio.sleep(1)

    # -------------------------------------------------------------------------
    # Start all workers
    # -------------------------------------------------------------------------

    @classmethod
    async def start_workers(cls) -> None:
        logger.info(
            f"Starting {settings.stream_workers} stream worker(s) + "
            f"{settings.background_workers} background worker(s) | "
            f"max_yt_concurrent={settings.max_yt_concurrent}"
        )
        stream_tasks = [
            asyncio.create_task(cls._stream_worker(i))
            for i in range(settings.stream_workers)
        ]
        background_tasks = [
            asyncio.create_task(cls._background_worker(i))
            for i in range(settings.background_workers)
        ]
        await asyncio.gather(*stream_tasks, *background_tasks, return_exceptions=True)
