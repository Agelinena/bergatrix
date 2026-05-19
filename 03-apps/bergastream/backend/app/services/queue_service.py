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

Concurrency invariants
----------------------
* `DOWNLOADING_SET` is the atomic "currently downloading" lock.  Workers
  reserve their slot via `SADD` and check the return value: 0 means another
  worker beat us to it, so the duplicate job is dropped.  This eliminates
  the race where the same track is downloaded twice when promoted from BG
  to STREAM (the old BG entry stays in the queue until a worker pops it).

* `STREAM_PROMOTED` marks tracks that were elevated to QUEUE_STREAM after
  already being in a background queue.  BG workers check this set and
  discard the duplicate job instead of starting a parallel download.

* `QUEUED_SET` is informational — it tells `_trigger_and_wait` and `enqueue`
  whether a track is already in flight so they don't enqueue twice.
"""
import asyncio
import json
import logging
import time
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
STREAM_PROMOTED = "bergastream:promoted"   # tracks elevated from BG to STREAM

# Pub/sub channel for "track file is ready on disk".
# _trigger_and_wait subscribes; workers publish in _save_result.
TRACK_READY_CHANNEL = "bergastream:track_ready"

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
        """
        Enqueue a track for download.

        Fast paths (no enqueue happens):
          * File already on disk
          * Track already in DOWNLOADING_SET

        Promotion path: when `priority=True` and the track is already in a
        background queue, push a duplicate to QUEUE_STREAM and mark it in
        STREAM_PROMOTED.  The bg worker will drop the stale entry when it
        pops it from QUEUE_BG/QUEUE_YTDLP.
        """
        # Fast skip: file already exists on disk
        from app.services.downloader_service import _resolve_existing
        if _resolve_existing(track_id):
            return

        r = cls._get_redis()
        if await r.sismember(DOWNLOADING_SET, track_id):
            return  # already downloading — let it finish

        if await r.sismember(QUEUED_SET, track_id):
            if priority:
                # Elevate: push to front of QUEUE_STREAM and mark the existing
                # background entry as superseded so BG worker drops it.
                await r.sadd(STREAM_PROMOTED, track_id)
                await r.lpush(
                    QUEUE_STREAM,
                    json.dumps({
                        "track_id": track_id,
                        "permanent": permanent,
                        "enqueued_at": time.time(),
                    }),
                )
            return

        queue = QUEUE_STREAM if priority else QUEUE_BG
        payload = json.dumps({
            "track_id": track_id,
            "permanent": permanent,
            "enqueued_at": time.time(),
        })
        await r.rpush(queue, payload)
        await r.sadd(QUEUED_SET, track_id)

    @classmethod
    async def enqueue_batch(cls, track_ids: list[str], permanent: bool = False) -> int:
        """
        Bulk-enqueue background downloads.  Uses SADD return value to atomically
        decide which IDs are new (not already queued/downloading).
        """
        from app.services.downloader_service import _resolve_existing

        r = cls._get_redis()
        if not track_ids:
            return 0

        # Pre-filter: drop IDs whose file is already on disk.
        track_ids = [tid for tid in track_ids if not _resolve_existing(tid)]
        if not track_ids:
            return 0

        # Filter out IDs already downloading.
        pipe = r.pipeline()
        for tid in track_ids:
            pipe.sismember(DOWNLOADING_SET, tid)
        downloading = await pipe.execute()
        candidates = [tid for tid, dl in zip(track_ids, downloading) if not dl]
        if not candidates:
            return 0

        # Atomic insert into QUEUED_SET; SADD returns count of newly-added.
        # For each candidate, sadd individually so we know which ones were new.
        pipe = r.pipeline()
        for tid in candidates:
            pipe.sadd(QUEUED_SET, tid)
        added = await pipe.execute()

        now = time.time()
        new_payloads: list[str] = []
        for tid, was_new in zip(candidates, added):
            if was_new:
                new_payloads.append(json.dumps({
                    "track_id": tid,
                    "permanent": permanent,
                    "enqueued_at": now,
                }))

        if new_payloads:
            await r.rpush(QUEUE_BG, *new_payloads)
        return len(new_payloads)

    # -------------------------------------------------------------------------
    # Shared helpers
    # -------------------------------------------------------------------------

    @classmethod
    async def _try_reserve(cls, track_id: str) -> bool:
        """
        Atomically reserve a download slot for this track.  Returns True if we
        got the slot, False if another worker is already handling it.
        Caller must call `_release_reservation` in a `finally` block.
        """
        r = cls._get_redis()
        # SADD returns 1 if newly added, 0 if already present.
        added = await r.sadd(DOWNLOADING_SET, track_id)
        return bool(added)

    @classmethod
    async def _release_reservation(cls, track_id: str) -> None:
        r = cls._get_redis()
        await r.srem(DOWNLOADING_SET, track_id)

    @classmethod
    async def _publish_ready(cls, track_id: str) -> None:
        try:
            r = cls._get_redis()
            await r.publish(TRACK_READY_CHANNEL, track_id)
        except Exception as e:
            logger.warning(f"[publish_ready] failed for {track_id}: {e}")

    @classmethod
    async def _save_result(
        cls, label: str, track_id: str, path, quality: str, permanent: bool,
        wait_ms: int | None = None, download_ms: int | None = None,
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
                timing = ""
                if wait_ms is not None or download_ms is not None:
                    timing = f" | wait_ms={wait_ms} download_ms={download_ms}"
                logger.info(f"[{label}] Saved permanent {track_id} → {final_path}{timing}")
            else:
                await db.execute(
                    update(Track).where(Track.id == track_id).values(
                        cache_path=str(path),
                        audio_quality=quality,
                        cache_expires_at=datetime.now(timezone.utc)
                        + timedelta(hours=settings.cache_expire_hours),
                    )
                )
                timing = ""
                if wait_ms is not None or download_ms is not None:
                    timing = f" | wait_ms={wait_ms} download_ms={download_ms}"
                logger.info(f"[{label}] Saved cache {track_id} → {path}{timing}")
            await db.commit()

        # Notify any waiting _trigger_and_wait callers.
        await cls._publish_ready(track_id)

    @classmethod
    def _parse_payload(cls, payload_str: str) -> tuple[dict, int]:
        """Returns (payload_dict, wait_in_queue_ms)."""
        payload = json.loads(payload_str)
        enqueued_at = payload.get("enqueued_at")
        if enqueued_at:
            wait_ms = int((time.time() - enqueued_at) * 1000)
        else:
            wait_ms = -1
        return payload, wait_ms

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
                payload, wait_ms = cls._parse_payload(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)

                # Atomic slot reservation. If False, another worker is on it.
                if not await cls._try_reserve(track_id):
                    logger.info(f"[{label}] {track_id} already being downloaded — skipping")
                    # Clear promotion marker if we set one
                    await r.srem(STREAM_PROMOTED, track_id)
                    continue

                forwarded = False
                t0 = time.time()
                try:
                    # Stream worker is the destination of promotions; clear the marker.
                    await r.srem(STREAM_PROMOTED, track_id)

                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        await cls._publish_ready(track_id)
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
                        f"wait_ms={wait_ms} | "
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
                    download_ms = int((time.time() - t0) * 1000)
                    if path:
                        await cls._save_result(
                            label, track_id, path, quality, permanent,
                            wait_ms=wait_ms, download_ms=download_ms,
                        )
                    else:
                        # yt-dlp failed — hand off to deemix queue as fallback.
                        # Keep QUEUED_SET alive so _trigger_and_wait keeps polling.
                        logger.warning(
                            f"[{label}] yt-dlp FAILED for stream {track_id} "
                            f"('{track.title}' by '{track.artist}') | "
                            f"download_ms={download_ms} — forwarding to deemix queue"
                        )
                        forwarded = True
                        # lpush = front of queue → user-triggered deemix job
                        # gets priority over background prefetch jobs (rpush).
                        await r.lpush(
                            QUEUE_BG,
                            json.dumps({
                                "track_id": track_id,
                                "permanent": permanent,
                                "enqueued_at": time.time(),
                                "from_stream_fallback": True,
                            }),
                        )

                finally:
                    await cls._release_reservation(track_id)
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
                payload, wait_ms = cls._parse_payload(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)

                # If this track was promoted to QUEUE_STREAM after being enqueued
                # here, drop this duplicate.  Stream worker will handle it.
                if await r.sismember(STREAM_PROMOTED, track_id):
                    logger.info(
                        f"[{label}] {track_id} promoted to STREAM — dropping bg duplicate"
                    )
                    continue

                # Atomic slot reservation
                if not await cls._try_reserve(track_id):
                    logger.info(f"[{label}] {track_id} already being downloaded — skipping")
                    continue

                forwarded = False
                t0 = time.time()
                try:
                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        await cls._publish_ready(track_id)
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
                        f"wait_ms={wait_ms} | "
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
                        download_ms = int((time.time() - t0) * 1000)
                        if path:
                            await cls._save_result(
                                label, track_id, path, quality, permanent,
                                wait_ms=wait_ms, download_ms=download_ms,
                            )
                            continue  # success
                        logger.warning(
                            f"[{label}] Deemix download FAILED for {track_id} (deezer/{deezer_id}) | "
                            f"download_ms={download_ms} — forwarding to yt-dlp"
                        )
                    else:
                        logger.warning(
                            f"[{label}] No Deezer candidate for {track_id} "
                            f"('{track.title}' by '{track.artist}') — forwarding to yt-dlp"
                        )

                    # Forward to yt-dlp queue; keep QUEUED_SET entry alive for the retry
                    forwarded = True
                    await r.rpush(QUEUE_YTDLP, json.dumps({
                        **payload,
                        "retries": 0,
                        "enqueued_at": time.time(),
                    }))

                finally:
                    await cls._release_reservation(track_id)
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
                payload, wait_ms = cls._parse_payload(payload_str)
                track_id = payload["track_id"]
                permanent = payload.get("permanent", False)
                retries = payload.get("retries", 0)

                # Same promotion check as deemix worker.
                if await r.sismember(STREAM_PROMOTED, track_id):
                    logger.info(
                        f"[{label}] {track_id} promoted to STREAM — dropping ytdlp duplicate"
                    )
                    continue

                # Atomic slot reservation
                if not await cls._try_reserve(track_id):
                    logger.info(f"[{label}] {track_id} already being downloaded — skipping")
                    continue

                t0 = time.time()
                try:
                    if _resolve_existing(track_id):
                        logger.info(f"[{label}] {track_id} already on disk — skipping")
                        await cls._publish_ready(track_id)
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
                        f"wait_ms={wait_ms} | "
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
                    download_ms = int((time.time() - t0) * 1000)

                    if path:
                        await cls._save_result(
                            label, track_id, path, quality, permanent,
                            wait_ms=wait_ms, download_ms=download_ms,
                        )
                    elif retries < _MAX_RETRIES:
                        wait = 30 * (retries + 1)  # 30 s, 60 s
                        logger.warning(
                            f"[{label}] yt-dlp FAILED for {track_id} "
                            f"('{track.title}' by '{track.artist}') | "
                            f"download_ms={download_ms} — "
                            f"requeueing in {wait}s (retry {retries + 1}/{_MAX_RETRIES})"
                        )
                        await asyncio.sleep(wait)
                        payload["retries"] = retries + 1
                        payload["enqueued_at"] = time.time()
                        await r.rpush(QUEUE_YTDLP, json.dumps(payload))
                        continue  # keep in QUEUED_SET for the retry
                    else:
                        logger.error(
                            f"[{label}] All retries exhausted for {track_id} "
                            f"('{track.title}' by '{track.artist}') | "
                            f"total_download_ms={download_ms}"
                        )

                finally:
                    await cls._release_reservation(track_id)
                    await r.srem(QUEUED_SET, track_id)

                await asyncio.sleep(_BG_SLEEP)

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"[{label}] Unhandled error: {e}")
                await asyncio.sleep(1)

    # -------------------------------------------------------------------------
    # Queue maintenance
    # -------------------------------------------------------------------------

    @classmethod
    async def clear_pending(
        cls, cutoff_time: float | None = None,
    ) -> dict[str, int]:
        """
        Drop background queue entries that were enqueued before `cutoff_time`.

        This is used when the user switches the active radio: the previous
        radio's tracks are still queued in QUEUE_BG / QUEUE_YTDLP, and the
        deemix worker (single consumer) would process all of them before
        getting to the new radio's tracks. Clearing the stale entries lets
        the next-in-line user-relevant track start downloading immediately.

        Entries with `enqueued_at >= cutoff_time` are preserved, so a
        concurrent prefetch arriving slightly after this call doesn't lose
        its just-enqueued entries.  Tracks currently downloading
        (DOWNLOADING_SET) are NOT interrupted — they finish naturally.

        Default cutoff_time = now, i.e. drop everything queued so far.

        Returns a dict {queue_name: cleared_count}.
        """
        if cutoff_time is None:
            cutoff_time = time.time()

        r = cls._get_redis()
        result: dict[str, int] = {}
        all_dropped_ids: list[str] = []

        for queue_name in (QUEUE_BG, QUEUE_YTDLP):
            items = await r.lrange(queue_name, 0, -1)
            kept_payloads: list[str] = []
            dropped_ids: list[str] = []
            for raw in items:
                try:
                    payload = json.loads(raw)
                except Exception:
                    # Malformed entry — drop it.
                    continue
                enqueued_at = payload.get("enqueued_at", 0)
                if enqueued_at >= cutoff_time:
                    kept_payloads.append(raw)
                else:
                    tid = payload.get("track_id", "")
                    if tid:
                        dropped_ids.append(tid)

            # Atomically replace the queue with only the kept entries.
            pipe = r.pipeline()
            pipe.delete(queue_name)
            if kept_payloads:
                pipe.rpush(queue_name, *kept_payloads)
            await pipe.execute()

            result[queue_name] = len(dropped_ids)
            all_dropped_ids.extend(dropped_ids)

        # Remove dropped IDs from QUEUED_SET so future enqueues for the same
        # tracks (e.g. user comes back) aren't blocked by the dedupe gate.
        # Filter out IDs that might still be in another (non-cleared) queue
        # entry — we only srem IDs that don't appear in any kept payload.
        if all_dropped_ids:
            await r.srem(QUEUED_SET, *all_dropped_ids)

        # Also clear STREAM_PROMOTED entries that pointed at dropped tracks.
        if all_dropped_ids:
            await r.srem(STREAM_PROMOTED, *all_dropped_ids)

        total = sum(result.values())
        if total > 0:
            logger.info(
                f"[clear_pending] Dropped {total} stale jobs "
                f"(bg={result.get(QUEUE_BG, 0)} ytdlp={result.get(QUEUE_YTDLP, 0)}) "
                f"cutoff={cutoff_time:.3f}"
            )
        else:
            logger.debug(f"[clear_pending] Nothing to drop (cutoff={cutoff_time:.3f})")
        return result

    # -------------------------------------------------------------------------
    # Diagnostics
    # -------------------------------------------------------------------------

    @classmethod
    async def queue_stats(cls) -> dict:
        """Snapshot of every queue and control set.  Used by /api/admin/queue-stats."""
        r = cls._get_redis()
        pipe = r.pipeline()
        pipe.llen(QUEUE_STREAM)
        pipe.llen(QUEUE_BG)
        pipe.llen(QUEUE_YTDLP)
        pipe.smembers(DOWNLOADING_SET)
        pipe.smembers(QUEUED_SET)
        pipe.smembers(STREAM_PROMOTED)
        results = await pipe.execute()
        return {
            "queues": {
                "stream": results[0],
                "bg":     results[1],
                "ytdlp":  results[2],
            },
            "downloading": sorted(list(results[3])),
            "queued":      sorted(list(results[4])),
            "promoted":    sorted(list(results[5])),
            "workers": {
                "stream":   settings.stream_workers,
                "deemix":   settings.deemix_bg_workers,
                "ytdlp":    settings.ytdlp_bg_workers,
                "max_yt_concurrent": settings.max_yt_concurrent,
            },
        }

    # -------------------------------------------------------------------------
    # Start all workers
    # -------------------------------------------------------------------------

    @classmethod
    async def start_workers(cls) -> None:
        r = cls._get_redis()

        # All per-process control sets must be wiped at startup — they reflect
        # the in-memory state of a no-longer-running worker pool, and stale
        # entries will block new downloads forever.
        for key in (DOWNLOADING_SET, STREAM_PROMOTED):
            stale = await r.smembers(key)
            if stale:
                await r.delete(key)
                logger.warning(
                    f"[startup] Cleared {len(stale)} stale entries from {key}: {stale}"
                )
            else:
                logger.info(f"[startup] {key} clean — no stale entries")

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
