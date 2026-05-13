from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, delete
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.models.playlist import LikedSong
from app.models.offline import OfflineTrack
from app.schemas.track import TrackSchema

router = APIRouter(prefix="/likes", tags=["likes"])


@router.post("/{track_id}", status_code=201)
async def like_track(
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Track).where(Track.id == track_id))
    if result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Track not found")

    existing = await db.execute(
        select(LikedSong).where(LikedSong.user_id == current_user.id, LikedSong.track_id == track_id)
    )
    if existing.scalar_one_or_none() is None:
        db.add(LikedSong(user_id=current_user.id, track_id=track_id))
        await db.flush()
    return {"liked": True}


@router.delete("/{track_id}", status_code=204)
async def unlike_track(
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await db.execute(
        delete(LikedSong).where(LikedSong.user_id == current_user.id, LikedSong.track_id == track_id)
    )


# Offline router (kept here to avoid extra file)
offline_router = APIRouter(prefix="/offline", tags=["offline"])


@offline_router.post("/{track_id}", status_code=201)
async def mark_offline(
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Track).where(Track.id == track_id))
    if result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Track not found")

    existing = await db.execute(
        select(OfflineTrack).where(OfflineTrack.user_id == current_user.id, OfflineTrack.track_id == track_id)
    )
    if existing.scalar_one_or_none() is None:
        db.add(OfflineTrack(user_id=current_user.id, track_id=track_id))
        await db.flush()
    return {"offline": True}


@offline_router.delete("/{track_id}", status_code=204)
async def unmark_offline(
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await db.execute(
        delete(OfflineTrack).where(OfflineTrack.user_id == current_user.id, OfflineTrack.track_id == track_id)
    )
