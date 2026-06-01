"""Resolve Spotify / Deezer / YouTube URLs to track or playlist metadata."""
import logging
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from app.config import get_settings
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.track import TrackSchema
from app.services import metadata_service

logger = logging.getLogger(__name__)
settings = get_settings()
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


def _explain_resolve_failure(url: str) -> str:
    """Best-effort explanation of why a URL couldn't be resolved."""
    parsed = metadata_service._parse_track_url(url)
    if parsed is None:
        return (
            "URL não reconhecida. Use um link como "
            "https://open.spotify.com/track/<id>, "
            "https://www.deezer.com/track/<id> ou "
            "https://youtu.be/<id>."
        )
    platform, _ = parsed
    if platform == "spotify" and (
        not settings.spotipy_client_id or not settings.spotipy_client_secret
    ):
        return (
            "Links do Spotify exigem SPOTIPY_CLIENT_ID e "
            "SPOTIPY_CLIENT_SECRET configurados no servidor. "
            "Peça ao admin para cadastrar."
        )
    return f"Falha ao resolver o link {platform}/{parsed[1]} — o serviço pode estar fora do ar."


@router.post("/track", response_model=TrackResolveResponse)
async def resolve_track(
    body: ResolveRequest,
    _: User = Depends(get_current_user),
):
    """Resolve a Spotify / Deezer / YouTube track URL to track metadata."""
    url = body.url.strip()
    logger.info(f"[resolve] track URL request: {url[:200]}")
    track = await metadata_service.resolve_track_url(url)
    if track is None:
        detail = _explain_resolve_failure(url)
        logger.warning(f"[resolve] failed: {url[:200]} → {detail}")
        raise HTTPException(status_code=422, detail=detail)
    logger.info(f"[resolve] track URL resolved: {url[:200]} → {track.id}")
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
