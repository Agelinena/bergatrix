"""
Chunked streaming with byte-range support.
Resolves: permanent → cache → download-while-streaming.

For complete files: serves with Content-Length + byte-range (seekable).
For files still being downloaded: serves without Content-Length using a
follow-file generator (like tail -f), so playback starts immediately.

Trigger-and-wait combines pub/sub notifications (instant wake when worker
saves the file) with a slow filesystem fallback poll (every 1 s) for
robustness if pub/sub misses an event.
"""
import asyncio
import logging
from pathlib import Path
from typing import AsyncGenerator
from fastapi import HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update
from datetime import datetime, timezone, timedelta
from app.config import get_settings
from app.models.track import Track
from app.services.queue_service import (
    DownloadQueueService, TRACK_READY_CHANNEL,
)

settings = get_settings()
logger = logging.getLogger(__name__)

CHUNK = 65536       # 64 KB chunks
LOCK_SUFFIX = ".lock"
TRIGGER_TIMEOUT_SECONDS = 150


def _lock_path(file_path: Path) -> Path:
    return file_path.with_suffix(file_path.suffix + LOCK_SUFFIX)


def _is_downloading(file_path: Path) -> bool:
    return _lock_path(file_path).exists()


async def _get_or_create_track(db: AsyncSession, track_id: str) -> Track | None:
    result = await db.execute(select(Track).where(Track.id == track_id))
    return result.scalar_one_or_none()


async def _update_track_cache_path(db: AsyncSession, track_id: str, path: str, quality: str) -> None:
    await db.execute(
        update(Track)
        .where(Track.id == track_id)
        .values(
            cache_path=path,
            audio_quality=quality,
            cache_expires_at=datetime.now(timezone.utc) + timedelta(hours=settings.cache_expire_hours),
            last_accessed_at=datetime.now(timezone.utc),
        )
    )
    await db.commit()


def _existing_file_for(track_id: str) -> tuple[Path, str] | None:
    """Returns (path, ext) for any existing audio file for this track_id."""
    for base in (settings.music_permanent_path, settings.music_cache_path):
        for ext in ("flac", "mp3"):
            p = Path(base) / f"{track_id}.{ext}"
            if p.exists() and p.stat().st_size > 0:
                return p, ext
    return None


async def _range_file_generator(file_path: Path, start: int, end: int) -> AsyncGenerator[bytes, None]:
    loop = asyncio.get_event_loop()
    with open(file_path, "rb") as f:
        f.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk_size = min(CHUNK, remaining)
            chunk = await loop.run_in_executor(None, f.read, chunk_size)
            if not chunk:
                break
            yield chunk
            remaining -= len(chunk)


async def _follow_file_generator(file_path: Path, timeout: float = 300.0) -> AsyncGenerator[bytes, None]:
    """Reads a file while it's still being written (like tail -f).
    Stops when the lock file disappears (download complete) and all bytes are read.
    """
    loop = asyncio.get_event_loop()
    pos = 0
    deadline = loop.time() + timeout

    while True:
        try:
            current_size = file_path.stat().st_size
        except FileNotFoundError:
            await asyncio.sleep(0.1)
            if loop.time() > deadline:
                break
            continue

        if current_size > pos:
            with open(file_path, "rb") as f:
                f.seek(pos)
                chunk = await loop.run_in_executor(None, f.read, min(CHUNK, current_size - pos))
            if chunk:
                yield chunk
                pos += len(chunk)
            continue

        # No new bytes — check if download is finished
        if not _is_downloading(file_path):
            break

        if loop.time() > deadline:
            break

        await asyncio.sleep(0.25)


def _parse_range(range_header: str | None, file_size: int) -> tuple[int, int]:
    if not range_header or not range_header.startswith("bytes="):
        return 0, file_size - 1
    parts = range_header[6:].split("-")
    start = int(parts[0]) if parts[0] else 0
    end = int(parts[1]) if len(parts) > 1 and parts[1] else file_size - 1
    return start, min(end, file_size - 1)


async def serve_stream(
    track_id: str,
    range_header: str | None,
    db: AsyncSession,
) -> StreamingResponse:
    track = await _get_or_create_track(db, track_id)
    if track is None:
        # Registration (fire-and-forget from client) may still be in-flight.
        # Retry for up to 1 s before giving up.
        for _ in range(10):
            await asyncio.sleep(0.1)
            track = await _get_or_create_track(db, track_id)
            if track is not None:
                break
    if track is None:
        raise HTTPException(status_code=404, detail="Track not found")

    await db.execute(
        update(Track).where(Track.id == track_id).values(last_accessed_at=datetime.now(timezone.utc))
    )
    await db.commit()

    # Clean DB columns one at a time so a stale cache_path doesn't take down a
    # valid file_path (and vice versa).
    file_path_to_use: Path | None = None

    if track.file_path:
        permanent_path = Path(track.file_path)
        if permanent_path.exists():
            file_path_to_use = permanent_path
        else:
            logger.warning(
                f"[stream] Stale permanent path for {track_id}: {permanent_path} — clearing"
            )
            await db.execute(
                update(Track).where(Track.id == track_id).values(
                    file_path=None, is_permanent=False,
                )
            )
            await db.commit()

    if file_path_to_use is None and track.cache_path:
        cache_path = Path(track.cache_path)
        if cache_path.exists():
            file_path_to_use = cache_path
        else:
            logger.warning(
                f"[stream] Stale cache path for {track_id}: {cache_path} — clearing"
            )
            await db.execute(
                update(Track).where(Track.id == track_id).values(
                    cache_path=None, cache_expires_at=None,
                )
            )
            await db.commit()

    # DB may not point anywhere, but the actual file might already exist on disk
    # (e.g., from a previous failed save).  Try filesystem lookup before triggering.
    if file_path_to_use is None:
        found = _existing_file_for(track_id)
        if found:
            file_path_to_use, ext = found
            await _update_track_cache_path(db, track_id, str(file_path_to_use), ext)

    if file_path_to_use is None:
        file_path_to_use = await _trigger_and_wait(track, db)
        if file_path_to_use is None:
            raise HTTPException(status_code=503, detail="Track could not be resolved for streaming")

    ext = file_path_to_use.suffix.lower()
    media_type = "audio/flac" if ext == ".flac" else "audio/mpeg"

    # File still being written → follow mode (no Content-Length, not seekable)
    if _is_downloading(file_path_to_use):
        return StreamingResponse(
            _follow_file_generator(file_path_to_use),
            status_code=200,
            media_type=media_type,
            headers={"Cache-Control": "no-cache", "Accept-Ranges": "none"},
        )

    # Complete file → byte-range support
    file_size = file_path_to_use.stat().st_size
    start, end = _parse_range(range_header, file_size)
    content_length = end - start + 1

    headers = {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Accept-Ranges": "bytes",
        "Content-Length": str(content_length),
        "Cache-Control": "no-cache",
    }

    status_code = 206 if range_header else 200
    return StreamingResponse(
        _range_file_generator(file_path_to_use, start, end),
        status_code=status_code,
        media_type=media_type,
        headers=headers,
    )


async def _trigger_and_wait(track: Track, db: AsyncSession) -> Path | None:
    """
    Adds track to QUEUE_STREAM and waits up to TRIGGER_TIMEOUT_SECONDS for the
    file to appear.

    Uses Redis pub/sub for instant wakeup when the worker publishes
    TRACK_READY_CHANNEL, with a slow filesystem fallback (every 1 s) in case
    pub/sub misses an event (e.g., subscription lag at startup).
    """
    logger.info(
        f"[stream] _trigger_and_wait START: {track.id} | "
        f"source={track.source} source_id={track.source_id!r} | "
        f"title={track.title!r} artist={track.artist!r} | "
        f"current_file_path={track.current_file_path!r}"
    )

    # Subscribe BEFORE enqueueing so we don't miss a fast-completing job.
    redis_client = DownloadQueueService._get_redis()
    pubsub = redis_client.pubsub()
    await pubsub.subscribe(TRACK_READY_CHANNEL)

    try:
        await DownloadQueueService.enqueue(track.id, priority=True)

        loop = asyncio.get_event_loop()
        start_time = loop.time()
        deadline = start_time + TRIGGER_TIMEOUT_SECONDS

        async def _check_disk() -> Path | None:
            found = _existing_file_for(track.id)
            return found[0] if found else None

        # Check disk once after enqueue, in case the worker already finished
        # (e.g., another concurrent request triggered the download).
        found = await _check_disk()
        if found:
            elapsed = loop.time() - start_time
            logger.info(
                f"[stream] _trigger_and_wait FOUND (immediate): {track.id} → {found} "
                f"after {elapsed:.1f}s"
            )
            await _update_track_cache_path(db, track.id, str(found), found.suffix.lstrip("."))
            return found

        while loop.time() < deadline:
            remaining = deadline - loop.time()
            # Block up to 1 s waiting for a publish; outer asyncio.wait_for
            # protects us against drivers that don't honour the kwarg timeout.
            wait_for = min(1.0, remaining)
            msg = None
            try:
                msg = await asyncio.wait_for(
                    pubsub.get_message(
                        ignore_subscribe_messages=True, timeout=wait_for,
                    ),
                    timeout=wait_for + 0.5,
                )
            except asyncio.TimeoutError:
                msg = None
            except Exception as e:
                logger.debug(f"[stream] pubsub.get_message error (non-fatal): {e}")

            if msg is not None and msg.get("type") == "message":
                ready_id = msg.get("data")
                if ready_id == track.id:
                    found = await _check_disk()
                    if found:
                        elapsed = loop.time() - start_time
                        logger.info(
                            f"[stream] _trigger_and_wait FOUND (pubsub): {track.id} → {found} "
                            f"after {elapsed:.1f}s"
                        )
                        await _update_track_cache_path(
                            db, track.id, str(found), found.suffix.lstrip("."),
                        )
                        return found

            # Slow polling fallback — covers pub/sub miss.
            found = await _check_disk()
            if found:
                elapsed = loop.time() - start_time
                logger.info(
                    f"[stream] _trigger_and_wait FOUND (poll): {track.id} → {found} "
                    f"after {elapsed:.1f}s"
                )
                await _update_track_cache_path(db, track.id, str(found), found.suffix.lstrip("."))
                return found

        elapsed = loop.time() - start_time
        logger.error(
            f"[stream] _trigger_and_wait TIMEOUT ({elapsed:.1f}s): {track.id} "
            f"('{track.title}' by '{track.artist}') — no file appeared"
        )
        return None
    finally:
        try:
            await pubsub.unsubscribe(TRACK_READY_CHANNEL)
            await pubsub.close()
        except Exception:
            pass
