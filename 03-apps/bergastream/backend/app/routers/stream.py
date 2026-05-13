from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.schemas.track import TrackSchema
from app.services import stream_service
from app.services.queue_service import DownloadQueueService

router = APIRouter(tags=["stream"])


@router.get("/stream/{track_id}")
async def stream_track(
    track_id: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    range_header = request.headers.get("range")
    return await stream_service.serve_stream(track_id, range_header, db)


@router.post("/queue/prefetch", status_code=202)
async def prefetch_queue(
    body: dict,
    _: User = Depends(get_current_user),
):
    """Pre-downloads upcoming tracks in the player queue."""
    track_ids: list[str] = body.get("track_ids", [])
    if not track_ids:
        return {"queued": 0}
    await DownloadQueueService.enqueue_batch(track_ids[:10])
    return {"queued": len(track_ids[:10])}


@router.post("/tracks/register", status_code=201)
async def register_track(
    track: TrackSchema,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """
    Registers a track from search results in the DB so it can be streamed.
    Called by the frontend before streaming an unknown track.
    """
    result = await db.execute(select(Track).where(Track.id == track.id))
    existing = result.scalar_one_or_none()
    if existing:
        return existing

    db_track = Track(
        id=track.id,
        title=track.title,
        artist=track.artist,
        album=track.album,
        album_id=track.album_id,
        artist_id=track.artist_id,
        duration_ms=track.duration_ms,
        year=track.year,
        cover_url=track.cover_url,
        source=track.source,
        source_id=track.source_id,
    )
    db.add(db_track)
    await db.flush()
    return db_track
