"""Resolve Spotify / Deezer / YouTube URLs to track or playlist metadata."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.track import TrackSchema
from app.services import metadata_service

router = APIRouter(prefix="/resolve", tags=["resolve"])


class ResolveRequest(BaseModel):
    url: str


class TrackResolveResponse(BaseModel):
    type: str = "track"
    track: TrackSchema


class PlaylistResolveResponse(BaseModel):
    type: str = "playlist"
    name: str
    tracks: list[TrackSchema]
    track_count: int


@router.post("/track", response_model=TrackResolveResponse)
async def resolve_track(
    body: ResolveRequest,
    _: User = Depends(get_current_user),
):
    """Resolve a Spotify / Deezer / YouTube track URL to track metadata."""
    track = await metadata_service.resolve_track_url(body.url.strip())
    if track is None:
        raise HTTPException(
            status_code=422,
            detail="URL não reconhecida. Cole um link válido do Spotify, Deezer ou YouTube.",
        )
    return TrackResolveResponse(track=track)


@router.post("/playlist", response_model=PlaylistResolveResponse)
async def resolve_playlist(
    body: ResolveRequest,
    _: User = Depends(get_current_user),
):
    """Resolve a Spotify / Deezer / YouTube playlist URL to track list."""
    result = await metadata_service.resolve_playlist_url(body.url.strip())
    if result is None:
        raise HTTPException(
            status_code=422,
            detail="URL de playlist não reconhecida. Cole um link válido do Spotify, Deezer ou YouTube.",
        )
    name, tracks = result
    return PlaylistResolveResponse(name=name, tracks=tracks, track_count=len(tracks))
