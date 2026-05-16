"""
Chunked streaming with byte-range support.
Resolves: permanent → cache → download-while-streaming.

For complete files: serves with Content-Length + byte-range (seekable).
For files still being downloaded: serves without Content-Length using a
follow-file generator (like tail -f), so playback starts immediately.
"""
import asyncio
from pathlib import Path
from typing import AsyncGenerator
from fastapi import HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update
from datetime import datetime, timezone, timedelta
from app.config import get_settings
from app.models.track import Track
from app.services.queue_service import DownloadQueueService

settings = get_settings()

CHUNK = 65536       # 64 KB chunks
LOCK_SUFFIX = ".lock"


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

    file_path = Path(track.current_file_path) if track.current_file_path else None

    if file_path is None or not file_path.exists():
        file_path = await _trigger_and_wait(track, db)
        if file_path is None:
            raise HTTPException(status_code=503, detail="Track could not be resolved for streaming")

    ext = file_path.suffix.lower()
    media_type = "audio/flac" if ext == ".flac" else "audio/mpeg"

    # File still being written → follow mode (no Content-Length, not seekable)
    if _is_downloading(file_path):
        return StreamingResponse(
            _follow_file_generator(file_path),
            status_code=200,
            media_type=media_type,
            headers={"Cache-Control": "no-cache", "Accept-Ranges": "none"},
        )

    # Complete file → byte-range support
    file_size = file_path.stat().st_size
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
        _range_file_generator(file_path, start, end),
        status_code=status_code,
        media_type=media_type,
        headers=headers,
    )


async def _trigger_and_wait(track: Track, db: AsyncSession) -> Path | None:
    """
    Adds track to QUEUE_STREAM and waits up to 150 s for the file to appear.

    150 s covers the full cascade: yt-dlp search+download (~30–60 s) +
    deemix fallback when yt-dlp fails (~60 s) with headroom for queue wait.
    Streaming begins as soon as the file is created (follow-file mode kicks in).
    """
    import logging as _logging
    _log = _logging.getLogger(__name__)
    _log.info(
        f"[stream] _trigger_and_wait START: {track.id} | "
        f"source={track.source} source_id={track.source_id!r} | "
        f"title={track.title!r} artist={track.artist!r} | "
        f"current_file_path={track.current_file_path!r}"
    )
    await DownloadQueueService.enqueue(track.id, priority=True)

    for elapsed_quarter in range(600):  # 150 seconds (600 × 0.25 s)
        await asyncio.sleep(0.25)
        for base in (settings.music_cache_path, settings.music_permanent_path):
            for ext in ("flac", "mp3"):
                p = Path(base) / f"{track.id}.{ext}"
                if p.exists() and p.stat().st_size > 0:
                    _log.info(
                        f"[stream] _trigger_and_wait FOUND: {track.id} → {p} "
                        f"after {elapsed_quarter * 0.25:.1f}s"
                    )
                    await _update_track_cache_path(db, track.id, str(p), ext)
                    return p

    _log.error(
        f"[stream] _trigger_and_wait TIMEOUT (150s): {track.id} "
        f"('{track.title}' by '{track.artist}') — no file appeared"
    )
    return None
