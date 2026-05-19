from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.schemas.track import TrackSchema
from app.services import stream_service, auth_service
from app.services.queue_service import DownloadQueueService

router = APIRouter(tags=["stream"])


async def get_stream_user(
    request: Request,
    token: str | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
) -> User:
    """Resolves user from Bearer header or ?token= query param (web audio fallback)."""
    raw = token
    if raw is None:
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            raw = auth_header[7:]
    if not raw:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    user = await auth_service.get_current_user_from_token(db, raw)
    if user is None or not user.is_active:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")
    return user


@router.get("/stream/{track_id}")
async def stream_track(
    track_id: str,
    request: Request,
    token: str | None = Query(default=None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_stream_user),
):
    range_header = request.headers.get("range")
    return await stream_service.serve_stream(track_id, range_header, db)


@router.post("/queue/prefetch", status_code=202)
async def prefetch_queue(
    body: dict,
    db: AsyncSession = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """
    Pre-downloads upcoming tracks in the player queue.

    Body formats:
      * `{"tracks": [<TrackSchema>, ...]}` — preferred. Auto-registers each
        track in the DB before enqueueing.  Required for prefetch to actually
        do anything: bg workers look up the Track row and skip with
        "not in DB yet" otherwise.
      * `{"track_ids": [...]}` — legacy. Only works if every track is
        already registered.
    """
    tracks_payload = body.get("tracks") or []
    track_ids: list[str] = list(body.get("track_ids", []))

    if tracks_payload:
        # Bulk auto-register: skip any track row that already exists.
        ids = [t.get("id") for t in tracks_payload if t.get("id")]
        if ids:
            existing = await db.execute(select(Track.id).where(Track.id.in_(ids)))
            existing_ids = {r[0] for r in existing.all()}
            new_rows: list[Track] = []
            for t in tracks_payload:
                tid = t.get("id")
                if not tid or tid in existing_ids:
                    continue
                new_rows.append(Track(
                    id=tid,
                    title=t.get("title", "") or "",
                    artist=t.get("artist", "") or "",
                    album=t.get("album"),
                    album_id=t.get("album_id"),
                    artist_id=t.get("artist_id"),
                    duration_ms=t.get("duration_ms"),
                    year=t.get("year"),
                    cover_url=t.get("cover_url"),
                    source=t.get("source", "") or "",
                    source_id=t.get("source_id"),
                ))
            if new_rows:
                db.add_all(new_rows)
                await db.flush()
                await db.commit()
            track_ids = ids  # everything we just registered or already had

    if not track_ids:
        return {"queued": 0}

    queued = await DownloadQueueService.enqueue_batch(track_ids[:20])
    return {"queued": queued}


@router.delete("/stream/{track_id}/cache", status_code=204)
async def delete_track_cache(
    track_id: str,
    _: User = Depends(get_current_user),
):
    """Deletes cached/permanent audio file so the track is re-downloaded on next play."""
    from app.services.downloader_service import delete_file
    delete_file(track_id)


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
