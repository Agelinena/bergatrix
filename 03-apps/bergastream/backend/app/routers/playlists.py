import uuid
import aiofiles
from pathlib import Path
from fastapi import APIRouter, Depends, HTTPException, status, Query, UploadFile, File
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, update, delete
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.models.track import Track
from app.models.playlist import Playlist, PlaylistTrack
from app.schemas.playlist import (
    PlaylistCreateRequest, PlaylistUpdateRequest, PlaylistSchema, PlaylistDetailSchema,
    AddTrackRequest, ReorderRequest, ShareResponse, PlaylistTrackSchema,
)
from app.config import get_settings

ALLOWED_COVER_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_COVER_BYTES = 5 * 1024 * 1024

settings = get_settings()
router = APIRouter(prefix="/playlists", tags=["playlists"])


async def _get_user_playlist(db: AsyncSession, playlist_id: uuid.UUID, user_id: uuid.UUID) -> Playlist:
    result = await db.execute(
        select(Playlist).where(Playlist.id == playlist_id, Playlist.owner_id == user_id)
    )
    pl = result.scalar_one_or_none()
    if pl is None:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return pl


async def _track_count(db: AsyncSession, playlist_id: uuid.UUID) -> int:
    result = await db.execute(
        select(func.count()).where(PlaylistTrack.playlist_id == playlist_id)
    )
    return result.scalar_one()


@router.get("", response_model=list[PlaylistSchema])
async def list_playlists(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Playlist).where(Playlist.owner_id == current_user.id).order_by(Playlist.updated_at.desc())
    )
    playlists = result.scalars().all()
    out = []
    for pl in playlists:
        count = await _track_count(db, pl.id)
        schema = PlaylistSchema.model_validate(pl)
        schema.track_count = count
        out.append(schema)
    return out


@router.post("", response_model=PlaylistSchema, status_code=201)
async def create_playlist(
    body: PlaylistCreateRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = Playlist(owner_id=current_user.id, name=body.name, description=body.description, is_public=body.is_public)
    db.add(pl)
    await db.flush()
    schema = PlaylistSchema.model_validate(pl)
    schema.track_count = 0
    return schema


@router.get("/shared/{token}", response_model=PlaylistDetailSchema)
async def get_shared_playlist(token: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Playlist).where(Playlist.share_token == token, Playlist.is_shared == True))
    pl = result.scalar_one_or_none()
    if pl is None:
        raise HTTPException(status_code=404, detail="Shared playlist not found")
    return await _build_detail(db, pl)


@router.post("/shared/{token}/follow", status_code=201)
async def follow_shared_playlist(
    token: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Playlist).where(Playlist.share_token == token, Playlist.is_shared == True))
    source = result.scalar_one_or_none()
    if source is None:
        raise HTTPException(status_code=404, detail="Shared playlist not found")

    new_pl = Playlist(owner_id=current_user.id, name=source.name, description=source.description)
    db.add(new_pl)
    await db.flush()

    # Copy tracks
    result = await db.execute(
        select(PlaylistTrack).where(PlaylistTrack.playlist_id == source.id).order_by(PlaylistTrack.position)
    )
    for pt in result.scalars().all():
        db.add(PlaylistTrack(playlist_id=new_pl.id, track_id=pt.track_id, position=pt.position, added_by=current_user.id))

    await db.flush()
    return {"id": str(new_pl.id)}


@router.get("/{playlist_id}", response_model=PlaylistDetailSchema)
async def get_playlist(
    playlist_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)
    return await _build_detail(db, pl)


@router.put("/{playlist_id}", response_model=PlaylistSchema)
async def update_playlist(
    playlist_id: uuid.UUID,
    body: PlaylistUpdateRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)
    if body.name is not None:
        pl.name = body.name
    if body.description is not None:
        pl.description = body.description
    if body.cover_url is not None:
        pl.cover_url = body.cover_url
    if body.is_public is not None:
        pl.is_public = body.is_public
    await db.flush()
    schema = PlaylistSchema.model_validate(pl)
    schema.track_count = await _track_count(db, pl.id)
    return schema


@router.delete("/{playlist_id}", status_code=204)
async def delete_playlist(
    playlist_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)
    await db.delete(pl)


@router.post("/{playlist_id}/tracks", status_code=201)
async def add_track(
    playlist_id: uuid.UUID,
    body: AddTrackRequest,
    force: bool = Query(default=False),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)

    # Ensure track exists
    result = await db.execute(select(Track).where(Track.id == body.track_id))
    if result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Track not found. Register it first via /api/tracks/register")

    # Duplicate check (skip if force=true)
    if not force:
        dup = await db.execute(
            select(PlaylistTrack).where(
                PlaylistTrack.playlist_id == playlist_id,
                PlaylistTrack.track_id == body.track_id,
            )
        )
        if dup.scalar_one_or_none() is not None:
            raise HTTPException(status_code=409, detail="Track already in playlist")

    # Determine position
    if body.position is None:
        max_pos = await db.execute(
            select(func.coalesce(func.max(PlaylistTrack.position), -1)).where(PlaylistTrack.playlist_id == pl.id)
        )
        position = max_pos.scalar_one() + 1
    else:
        position = body.position

    pt = PlaylistTrack(playlist_id=pl.id, track_id=body.track_id, position=position, added_by=current_user.id)
    db.add(pt)
    await db.flush()
    return {"id": str(pt.id)}


@router.post("/{playlist_id}/cover")
async def upload_cover(
    playlist_id: uuid.UUID,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)

    if file.content_type not in ALLOWED_COVER_TYPES:
        raise HTTPException(status_code=400, detail="Apenas JPEG, PNG e WebP são suportados")

    content = await file.read()
    if len(content) > MAX_COVER_BYTES:
        raise HTTPException(status_code=400, detail="Arquivo muito grande (máx. 5 MB)")

    covers_dir = Path(settings.media_covers_path)
    covers_dir.mkdir(parents=True, exist_ok=True)

    suffix = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}[file.content_type]
    filename = f"{playlist_id}_{uuid.uuid4().hex[:8]}{suffix}"
    filepath = covers_dir / filename

    async with aiofiles.open(filepath, "wb") as f:
        await f.write(content)

    cover_url = f"https://{settings.api_domain}/media/covers/{filename}"
    pl.cover_url = cover_url
    return {"cover_url": cover_url}


@router.delete("/{playlist_id}/tracks/{track_id}", status_code=204)
async def remove_track(
    playlist_id: uuid.UUID,
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await _get_user_playlist(db, playlist_id, current_user.id)
    await db.execute(
        delete(PlaylistTrack).where(PlaylistTrack.playlist_id == playlist_id, PlaylistTrack.track_id == track_id)
    )


@router.patch("/{playlist_id}/tracks/reorder", status_code=204)
async def reorder_tracks(
    playlist_id: uuid.UUID,
    body: ReorderRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await _get_user_playlist(db, playlist_id, current_user.id)
    for position, track_id in enumerate(body.track_ids):
        await db.execute(
            update(PlaylistTrack)
            .where(PlaylistTrack.playlist_id == playlist_id, PlaylistTrack.track_id == track_id)
            .values(position=position)
        )


@router.post("/{playlist_id}/share", response_model=ShareResponse)
async def share_playlist(
    playlist_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_user_playlist(db, playlist_id, current_user.id)
    token = pl.generate_share_token()
    await db.flush()
    return ShareResponse(
        share_token=token,
        share_url=f"https://{settings.web_domain}/shared/{token}",
    )


async def _build_detail(db: AsyncSession, pl: Playlist) -> PlaylistDetailSchema:
    result = await db.execute(
        select(PlaylistTrack).where(PlaylistTrack.playlist_id == pl.id).order_by(PlaylistTrack.position)
    )
    pts = result.scalars().all()

    track_schemas = []
    for pt in pts:
        track_result = await db.execute(select(Track).where(Track.id == pt.track_id))
        track = track_result.scalar_one_or_none()
        if track:
            from app.schemas.track import TrackSchema
            ts = TrackSchema.model_validate(track)
            track_schemas.append(PlaylistTrackSchema(
                id=str(pt.id), track=ts, position=pt.position, added_at=pt.added_at
            ))

    # model_validate(pl) would trigger lazy-load of pl.tracks; build from PlaylistSchema instead
    base = PlaylistSchema.model_validate(pl)
    base_data = base.model_dump()
    base_data['track_count'] = len(track_schemas)
    return PlaylistDetailSchema(**base_data, tracks=track_schemas)
