"""
Redis-backed download queue with three isolated worker pools.

Stream workers  (QUEUE_STREAM): yt-dlp only, no inter-job sleep.
  — Serve on-demand streaming as fast as possible.
  — Never touch deemix; yt-dlp gives results in 30–60 s.

Deemix worker   (QUEUE_BG): exactly ONE worker, sequential, no lock needed.
  — Single consumer means deemix's internal queue never accumulates stale entries.
  — Tries Deezer via deemix for quality (FLAC / MP3-320).
  — On any failure: forwards the job to QUEUE_YTDLP for yt-dlp fallback.
  — 3-second sleep between jobs.

yt-dlp workers  (QUEUE_YTDLP): concurrent, global asyncio.Semaphore.
  — Handle YouTube-sourced tracks and deemix failures.
  — Semaphore shared with stream workers caps total yt-dlp processes.
  — Exponential backoff retry (30 s / 60 s) up to _MAX_RETRIES times.
  — 3-second sleep between jobs.
"""
import asyncio
import json
import logging
from redis.asyncio import Redis
from app.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

QUEUE_STREAM = "bergastream:queue:stream"   # on-demand / streaming (yt-dlp)
QUEUE_BG     = "bergastream:queue:bg"       # background deemix downloads
QUEUE_YTDLP  = "bergastream:queue:ytdlp"   # yt-dlp bg + deemix fallback

# Backward-compat aliases (stream_service and other callers use the old names)
QUEUE_HIGH = QUEUE_STREAM
QUEUE_LOW  = QUEUE_BG

DOWNLOADING_SET = "bergastream:downloading"
QUEUED_SET      = "bergastream:queued"

_MAX_RETRIES = 2
_BG_SLEEP    = 3.0  # seconds between background jobs


class DownloadQueueService:
    _redis: Redis | None = None

    @classmethod
    def _get_redis(cls) -> Redis:
        if cls._redis is None:
            cls._redis = Redis.from_url(settings.redis_url, decode_responses=True)
        return cls._redis

    # -------------------------------------------------------------------------
    # Enqueue
    # -------------------------------------------------------------------------

    @classmethod
    async def enqueue(cls, track_id: str, priority: bool = False, permanent: bool = False) -> None:
        r = cls._get_redis()
        if await r.sismember(DOWNLOADING_SET, track_id):
            return  # already downloading — let it finish
        if await r.sismember(QUEUED_SET, track_id):
            if priority:
                # Elevate: push to front of QUEUE_STREAM so stream workers pick it up now.
                # The existing QUEUE_BG / QUEUE_YTDLP entry becomes a no-op:
                # _resolve_existing() will find the file before any download starts.
                await r.lpush(QUEUE_STREAM, json.dumps({"track_id": track_id, "permanent": permanent}))
            return
        queue = QUEUE_STREAM if priority else QUEUE_BG
        await r.rpush(queue, json.dumps({"track_id": track_id, "permanent": permanent}))
        await r.sadd(QUEUED_SET, track_id)

    @classmethod
    async def enqueue_batch(cls, track_ids: list[str], permanent: bool = False) -> int:
        r = cls._get_redis()
        if not track_ids:
            return 0
        pipe = r.pipeline()
        for tid in track_ids:
            pipe.sismember(DOWNLOADING_SET, tid)
            pipe.sismember(QUEUED_SET, tid)
        results = await pipe.execute()

        new_payloads: list[str] = []
        new_ids: list[str] = []
        for i, tid in enumerate(track_ids):
            if not results[i * 2] and not results[i * 2 + 1]:
                new_payloads.append(json.dumps({"track_id": tid, "permanent": permanent}))
                new_ids.append(tid)

        if new_payloads:
            pipe = r.pipeline()
            pipe.rpush(QUEUE_BG, *new_payloads)
            pipe.sadd(QUEUED_SET, *new_ids)
            await pipe.execute()
        return len(new_ids)

    # -------------------------------------------------------------------------
    # Shared helper — persist download result to DB
    # -------------------------------------------------------------------------

    @classmethod
    async def _save_result(
        cls, label: str, track_id: str, path, quality: str, permanent: bool
    ) -> None:
        from app.database import AsyncSessionLocal
        from sqlalchemy import update
        from app.models.track import Track
        from app.services.downloader_service import move_to_permanent
        from datetime import datetime, timezone, timedelta

        async with AsyncSessionLocal() as db:
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
                logger.info(f"[{label}] Saved permanent {track_id} → {final_path}")
            else:
                await db.execute(
                    update(Track).where(Track.id == track_id).values(
                        cache_path=str(path),
                        audio_quality=quality,
                        cache_expires_at=datetime.now(timezone.utc)
                        + timedelta(hours=settings.cache_expire_hours),
                    )
                )
                logger.info(f"[{label}] Saved cache {track_id} → {path}")
            await db.commit()

    # -------------------------------------------------------------------------
    # Stream workers — QUEUE_STREAM, yt-dlp only, no sleep
    # -------------------------------------------------------------------------

    @classmethod
    async def _stream_worker(cls, worker_id: int) -> None:
        from app.services.downloader_service import _resolve_existing, download_youtube
        from app.database import AsyncSessionLocal
        from sqlalchemy import select
        from app.models.track import Track

        r = cls._get_redis()
        label = f"stream-{worker_id}"
        logger.info(f"[{label}] Stream worker started")

        while True:
            try:
                item = await r.blpop([QUEUE_STREAM], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)

                await r.sadd(DOWNLOADING_SET, track_id)
                forwarded = False  # True when handed off to deemix queue
                try:
                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        continue

                    async with AsyncSessionLocal() as db:
                        result = await db.execute(select(Track).where(Track.id == track_id))
                        track = result.scalar_one_or_none()
                    if track is None:
                        logger.info(f"[{label}] Track {track_id} not in DB yet — skipping")
                        continue

                    yt_source_id = track.source_id if track.source == "youtube" else ""
                    logger.info(
                        f"[{label}] START stream download: {track_id} | "
                        f"source={track.source} source_id={track.source_id!r} | "
                        f"title={track.title!r} artist={track.artist!r} | "
                        f"duration_ms={track.duration_ms} | "
                        f"yt_source_id={yt_source_id!r}"
                    )
                    path, quality = await download_youtube(
                        track_id,
                        yt_source_id,
                        track.title or "",
                        track.artist or "",
                        track.duration_ms,
                    )
                    if path:
                        await cls._save_result(label, track_id, path, quality, permanent)
                    else:
                        # yt-dlp failed — hand off to deemix queue as fallback.
                        # Keep QUEUED_SET alive so _trigger_and_wait keeps polling.
                        logger.warning(
                            f"[{label}] yt-dlp FAILED for stream {track_id} "
                            f"('{track.title}' by '{track.artist}') "
                            "— forwarding to deemix queue"
                        )
                        forwarded = True
                        # lpush = front of queue → user-triggered deemix job
                        # gets priority over background prefetch jobs (rpush).
                        await r.lpush(QUEUE_BG, json.dumps({"track_id": track_id, "permanent": permanent}))

                finally:
                    await r.srem(DOWNLOADING_SET, track_id)
                    if not forwarded:
                        await r.srem(QUEUED_SET, track_id)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"[{label}] Unhandled error: {e}")
                await asyncio.sleep(1)

    # -------------------------------------------------------------------------
    # Deemix worker — QUEUE_BG, single worker, sequential, no lock needed
    # -------------------------------------------------------------------------

    @classmethod
    async def _deemix_worker(cls, worker_id: int = 0) -> None:
        from app.services.downloader_service import (
            _resolve_existing, find_deezer_candidate, download_deezer,
        )
        from app.database import AsyncSessionLocal
        from sqlalchemy import select
        from app.models.track import Track

        r = cls._get_redis()
        label = f"deemix-{worker_id}"
        logger.info(f"[{label}] Deemix worker started")

        while True:
            try:
                item = await r.blpop([QUEUE_BG], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)

                await r.sadd(DOWNLOADING_SET, track_id)
                forwarded = False  # True when pushed to QUEUE_YTDLP
                try:
                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        continue

                    async with AsyncSessionLocal() as db:
                        result = await db.execute(select(Track).where(Track.id == track_id))
                        track = result.scalar_one_or_none()
                    if track is None:
                        logger.info(f"[{label}] Track {track_id} not in DB yet — skipping")
                        continue

                    deezer_known = track.source_id if track.source == "deezer" else None
                    logger.info(
                        f"[{label}] START deemix download: {track_id} | "
                        f"source={track.source} source_id={track.source_id!r} | "
                        f"title={track.title!r} artist={track.artist!r} | "
                        f"duration_ms={track.duration_ms} | "
                        f"deezer_known={deezer_known!r}"
                    )
                    deezer_id = await find_deezer_candidate(
                        track.title or "", track.artist or "", track.duration_ms, deezer_known
                    )

                    if deezer_id:
                        logger.info(f"[{label}] Deemix download: {track_id} via deezer/{deezer_id}")
                        path, quality = await download_deezer(track_id, deezer_id, track.duration_ms)
                        if path:
                            await cls._save_result(label, track_id, path, quality, permanent)
                            continue  # success
                        logger.warning(
                            f"[{label}] Deemix download FAILED for {track_id} (deezer/{deezer_id}) "
                            "— forwarding to yt-dlp"
                        )
                    else:
                        logger.warning(
                            f"[{label}] No Deezer candidate for {track_id} "
                            f"('{track.title}' by '{track.artist}') — forwarding to yt-dlp"
                        )

                    # Forward to yt-dlp queue; keep QUEUED_SET entry alive for the retry
                    forwarded = True
                    await r.rpush(QUEUE_YTDLP, json.dumps({**payload, "retries": 0}))

                finally:
                    await r.srem(DOWNLOADING_SET, track_id)
                    if not forwarded:
                        # Only remove from queued when the track is truly done (not forwarded)
                        await r.srem(QUEUED_SET, track_id)

                await asyncio.sleep(_BG_SLEEP)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"[{label}] Unhandled error: {e}")
                await asyncio.sleep(1)

    # -------------------------------------------------------------------------
    # yt-dlp workers — QUEUE_YTDLP, concurrent, semaphore-limited
    # -------------------------------------------------------------------------

    @classmethod
    async def _ytdlp_worker(cls, worker_id: int) -> None:
        from app.services.downloader_service import _resolve_existing, download_youtube
        from app.database import AsyncSessionLocal
        from sqlalchemy import select
        from app.models.track import Track

        r = cls._get_redis()
        label = f"ytdlp-{worker_id}"
        logger.info(f"[{label}] yt-dlp worker started")

        while True:
            try:
                item = await r.blpop([QUEUE_YTDLP], timeout=5)
                if item is None:
                    continue

                _, payload_str = item
                payload = json.loads(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)
                retries = payload.get("retries", 0)

                await r.sadd(DOWNLOADING_SET, track_id)
                try:
                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        continue

                    async with AsyncSessionLocal() as db:
                        result = await db.execute(select(Track).where(Track.id == track_id))
                        track = result.scalar_one_or_none()
                    if track is None:
                        logger.info(f"[{label}] Track {track_id} not in DB yet — skipping")
                        continue

                    yt_source_id = track.source_id if track.source == "youtube" else ""
                    logger.info(
                        f"[{label}] START yt-dlp download: {track_id} "
                        f"(attempt {retries + 1}/{_MAX_RETRIES + 1}) | "
                        f"source={track.source} source_id={track.source_id!r} | "
                        f"title={track.title!r} artist={track.artist!r} | "
                        f"duration_ms={track.duration_ms} | "
                        f"yt_source_id={yt_source_id!r}"
                    )
                    path, quality = await download_youtube(
                        track_id,
                        yt_source_id,
                        track.title or "",
                        track.artist or "",
                        track.duration_ms,
                    )

                    if path:
                        await cls._save_result(label, track_id, path, quality, permanent)
                    elif retries < _MAX_RETRIES:
                        wait = 30 * (retries + 1)  # 30 s, 60 s
                        logger.warning(
                            f"[{label}] yt-dlp FAILED for {track_id} "
                            f"('{track.title}' by '{track.artist}') — "
                            f"requeueing in {wait}s (retry {retries + 1}/{_MAX_RETRIES})"
                        )
                        await asyncio.sleep(wait)
                        payload["retries"] = retries + 1
                        await r.rpush(QUEUE_YTDLP, json.dumps(payload))
                        continue  # keep in QUEUED_SET for the retry
                    else:
                        logger.error(
                            f"[{label}] All retries exhausted for {track_id} "
                            f"('{track.title}' by '{track.artist}')"
                        )

                finally:
                    await r.srem(DOWNLOADING_SET, track_id)
                    await r.srem(QUEUED_SET, track_id)

                await asyncio.sleep(_BG_SLEEP)

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
        r = cls._get_redis()

        # DOWNLOADING_SET entries are per-process state: every entry left from a
        # previous run belongs to a worker that no longer exists.  Clear it so
        # enqueue() doesn't mistake them for active downloads and block forever.
        stale = await r.smembers(DOWNLOADING_SET)
        if stale:
            await r.delete(DOWNLOADING_SET)
            logger.warning(
                f"[startup] Cleared {len(stale)} stale DOWNLOADING_SET entries "
                f"from previous run: {stale}"
            )
        else:
            logger.info("[startup] DOWNLOADING_SET clean — no stale entries")

        n_stream = settings.stream_workers
        n_deemix = settings.deemix_bg_workers  # keep at 1 — deemix is single-consumer
        n_ytdlp  = settings.ytdlp_bg_workers
        logger.info(
            f"Starting workers: "
            f"{n_stream}× stream (yt-dlp) | "
            f"{n_deemix}× deemix-bg | "
            f"{n_ytdlp}× ytdlp-bg | "
            f"max_yt_concurrent={settings.max_yt_concurrent}"
        )
        tasks = [
            *[asyncio.create_task(cls._stream_worker(i)) for i in range(n_stream)],
            *[asyncio.create_task(cls._deemix_worker(i)) for i in range(n_deemix)],
            *[asyncio.create_task(cls._ytdlp_worker(i))  for i in range(n_ytdlp)],
        ]
        await asyncio.gather(*tasks, return_exceptions=True)
