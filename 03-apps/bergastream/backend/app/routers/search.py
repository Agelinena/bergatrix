from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
import httpx
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.track import SearchResponse, TrackSchema, AlbumSchema, ArtistSchema
from app.services import metadata_service

router = APIRouter(tags=["search"])


@router.get("/search", response_model=SearchResponse)
async def search(
    q: str = Query(..., min_length=1),
    source: str = Query("deezer", pattern="^(deezer|spotify|youtube|all)$"),
    limit: int = Query(20, ge=1, le=50),
    _: User = Depends(get_current_user),
):
    if source == "deezer":
        return await metadata_service.search_deezer(q, limit)
    if source == "spotify":
        return await metadata_service.search_spotify(q, limit)
    if source == "youtube":
        return await metadata_service.search_youtube(q, limit)
    return await metadata_service.search_all(q, limit)


@router.get("/artist/{artist_id}")
async def get_artist(
    artist_id: str,
    source: str = Query("deezer"),
    _: User = Depends(get_current_user),
):
    if source == "deezer":
        raw_id = artist_id.removeprefix("deezer_")
        artist, albums, top_tracks = await metadata_service.get_deezer_artist(raw_id)
        if artist is None:
            raise HTTPException(status_code=404, detail="Artist not found")
        return {"artist": artist, "albums": albums, "top_tracks": top_tracks}
    raise HTTPException(status_code=400, detail="Unsupported source for artist lookup")


@router.get("/album/{album_id}")
async def get_album(
    album_id: str,
    source: str = Query("deezer"),
    _: User = Depends(get_current_user),
):
    if source == "deezer":
        raw_id = album_id.removeprefix("deezer_")
        album, tracks = await metadata_service.get_deezer_album(raw_id)
        if album is None:
            raise HTTPException(status_code=404, detail="Album not found")
        return {"album": album, "tracks": tracks}
    raise HTTPException(status_code=400, detail="Unsupported source for album lookup")


@router.get("/cover/proxy")
async def cover_proxy(url: str = Query(...)):
    """Proxies album art to avoid CORS issues on the frontend."""
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as client:
            resp = await client.get(url)
        if resp.status_code != 200:
            raise HTTPException(status_code=502, detail="Failed to fetch cover")
        content_type = resp.headers.get("content-type", "image/jpeg")
        return StreamingResponse(iter([resp.content]), media_type=content_type)
    except httpx.RequestError:
        raise HTTPException(status_code=502, detail="Failed to fetch cover")
