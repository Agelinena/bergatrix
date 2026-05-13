"""
Chunked streaming with byte-range support.
Resolves: permanent → cache → download-while-streaming.
"""
import asyncio
import os
from pathlib import Path
from typing import AsyncGenerator
from fastapi import HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update
from datetime import datetime, timezone, timedelta
from app.config import get_settings
from app.models.track import Track
from app.services import downloader_service
from app.services.queue_service import DownloadQueueService

settings = get_settings()

CHUNK = 65536  # 64 KB chunks


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
        raise HTTPException(status_code=404, detail="Track not found")

    # Update last access
    await db.execute(
        update(Track).where(Track.id == track_id).values(last_accessed_at=datetime.now(timezone.utc))
    )
    await db.commit()

    file_path = Path(track.current_file_path) if track.current_file_path else None

    if file_path is None or not file_path.exists():
        # Trigger download and wait for the file to become available
        file_path = await _download_and_wait(track, db)
        if file_path is None:
            raise HTTPException(status_code=503, detail="Track could not be resolved for streaming")

    file_size = file_path.stat().st_size
    start, end = _parse_range(range_header, file_size)
    content_length = end - start + 1

    ext = file_path.suffix.lower()
    media_type = "audio/flac" if ext == ".flac" else "audio/mpeg"

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


async def _download_and_wait(track: Track, db: AsyncSession) -> Path | None:
    """Triggers download and waits up to 30s for the file to appear."""
    # Queue the download
    await DownloadQueueService.enqueue(track.id, priority=True)

    # Poll until file appears (max 30 seconds)
    for _ in range(30):
        await asyncio.sleep(1)
        path, quality = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: (
                next(
                    (
                        Path(b) / f"{track.id}.{ext}"
                        for b in (settings.music_cache_path, settings.music_permanent_path)
                        for ext in ("flac", "mp3")
                        if (Path(b) / f"{track.id}.{ext}").exists()
                    ),
                    None,
                ),
                "",
            ),
        )
        if path:
            await _update_track_cache_path(db, track.id, str(path), quality)
            return path
    return None
