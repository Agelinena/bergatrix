from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, delete
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.models.playlist import PlaylistTrack, LikedSong, Playlist
from app.models.offline import OfflineTrack
from app.schemas.track import TrackSchema

router = APIRouter(prefix="/library", tags=["library"])


@router.get("/tracks", response_model=list[TrackSchema])
async def get_library_tracks(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """All tracks in any of the user's playlists."""
    result = await db.execute(
        select(Track)
        .join(PlaylistTrack, PlaylistTrack.track_id == Track.id)
        .join(Playlist, Playlist.id == PlaylistTrack.playlist_id)
        .where(Playlist.owner_id == current_user.id)
        .distinct()
    )
    return [TrackSchema.model_validate(t) for t in result.scalars().all()]


@router.get("/stats")
async def get_library_stats(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    playlist_count_result = await db.execute(
        select(func.count()).where(Playlist.owner_id == current_user.id)
    )
    track_count_result = await db.execute(
        select(func.count(func.distinct(PlaylistTrack.track_id)))
        .join(Playlist, Playlist.id == PlaylistTrack.playlist_id)
        .where(Playlist.owner_id == current_user.id)
    )
    liked_count_result = await db.execute(
        select(func.count()).where(LikedSong.user_id == current_user.id)
    )

    return {
        "playlist_count": playlist_count_result.scalar_one(),
        "unique_tracks": track_count_result.scalar_one(),
        "liked_songs": liked_count_result.scalar_one(),
    }


# Liked songs
@router.get("/likes", response_model=list[TrackSchema])
async def get_liked_songs(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Track)
        .join(LikedSong, LikedSong.track_id == Track.id)
        .where(LikedSong.user_id == current_user.id)
        .order_by(LikedSong.liked_at.desc())
    )
    return [TrackSchema.model_validate(t) for t in result.scalars().all()]


# Offline tracks
@router.get("/offline", response_model=list[TrackSchema])
async def get_offline_tracks(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Track)
        .join(OfflineTrack, OfflineTrack.track_id == Track.id)
        .where(OfflineTrack.user_id == current_user.id)
    )
    return [TrackSchema.model_validate(t) for t in result.scalars().all()]
