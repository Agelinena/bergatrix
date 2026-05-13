from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, delete
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.models.history import PlayHistory
from app.schemas.history import RecordPlayRequest, PlayHistorySchema, HistoryStatsSchema
from app.schemas.track import TrackSchema

router = APIRouter(prefix="/history", tags=["history"])


@router.post("", status_code=201)
async def record_play(
    body: RecordPlayRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # Skip silently if track not in DB (avoids FK violation for unregistered tracks)
    track_result = await db.execute(select(Track).where(Track.id == body.track_id))
    if track_result.scalar_one_or_none() is None:
        return {"id": None}

    entry = PlayHistory(
        user_id=current_user.id,
        track_id=body.track_id,
        duration_played_ms=body.duration_played_ms,
        completed=body.completed,
        source_context=body.source_context,
        context_id=body.context_id,
    )
    db.add(entry)
    await db.flush()
    return {"id": str(entry.id)}


@router.get("", response_model=list[PlayHistorySchema])
async def get_history(
    page: int = Query(1, ge=1),
    limit: int = Query(50, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    offset = (page - 1) * limit
    result = await db.execute(
        select(PlayHistory)
        .where(PlayHistory.user_id == current_user.id)
        .order_by(PlayHistory.played_at.desc())
        .offset(offset)
        .limit(limit)
    )
    entries = result.scalars().all()

    out = []
    for entry in entries:
        track_result = await db.execute(select(Track).where(Track.id == entry.track_id))
        track = track_result.scalar_one_or_none()
        if track:
            out.append(PlayHistorySchema(
                id=entry.id,
                track=TrackSchema.model_validate(track),
                played_at=entry.played_at,
                duration_played_ms=entry.duration_played_ms,
                completed=entry.completed,
                source_context=entry.source_context,
            ))
    return out


@router.get("/stats", response_model=HistoryStatsSchema)
async def get_stats(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    total_plays_result = await db.execute(
        select(func.count()).where(PlayHistory.user_id == current_user.id)
    )
    total_plays = total_plays_result.scalar_one()

    total_ms_result = await db.execute(
        select(func.coalesce(func.sum(PlayHistory.duration_played_ms), 0)).where(PlayHistory.user_id == current_user.id)
    )
    total_ms = total_ms_result.scalar_one()

    unique_tracks_result = await db.execute(
        select(func.count(func.distinct(PlayHistory.track_id))).where(PlayHistory.user_id == current_user.id)
    )
    unique_tracks = unique_tracks_result.scalar_one()

    # Top artists (join with tracks)
    top_artists_result = await db.execute(
        select(Track.artist, func.count().label("plays"))
        .join(PlayHistory, PlayHistory.track_id == Track.id)
        .where(PlayHistory.user_id == current_user.id)
        .group_by(Track.artist)
        .order_by(func.count().desc())
        .limit(10)
    )
    top_artists = [{"artist": row.artist, "plays": row.plays} for row in top_artists_result]

    unique_artists_result = await db.execute(
        select(func.count(func.distinct(Track.artist)))
        .join(PlayHistory, PlayHistory.track_id == Track.id)
        .where(PlayHistory.user_id == current_user.id)
    )
    unique_artists = unique_artists_result.scalar_one()

    # Top tracks
    top_tracks_result = await db.execute(
        select(Track.id, Track.title, Track.artist, func.count().label("plays"))
        .join(PlayHistory, PlayHistory.track_id == Track.id)
        .where(PlayHistory.user_id == current_user.id)
        .group_by(Track.id, Track.title, Track.artist)
        .order_by(func.count().desc())
        .limit(10)
    )
    top_tracks = [
        {"id": row.id, "title": row.title, "artist": row.artist, "plays": row.plays}
        for row in top_tracks_result
    ]

    return HistoryStatsSchema(
        total_plays=total_plays,
        total_ms_played=total_ms,
        unique_tracks=unique_tracks,
        unique_artists=unique_artists,
        top_artists=top_artists,
        top_tracks=top_tracks,
        hours_per_day=[],
    )


@router.delete("", status_code=204)
async def clear_history(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await db.execute(delete(PlayHistory).where(PlayHistory.user_id == current_user.id))
