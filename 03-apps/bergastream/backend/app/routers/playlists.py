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
from app.models.playlist import Playlist, PlaylistTrack, PlaylistCollaborator
from app.schemas.playlist import (
    PlaylistCreateRequest, PlaylistUpdateRequest, PlaylistSchema, PlaylistDetailSchema,
    AddTrackRequest, ReorderRequest, ShareResponse, PlaylistTrackSchema, CollaboratorSchema,
)
from app.config import get_settings

ALLOWED_COVER_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_COVER_BYTES = 5 * 1024 * 1024

settings = get_settings()
router = APIRouter(prefix="/playlists", tags=["playlists"])


async def _get_owner_playlist(db: AsyncSession, playlist_id: uuid.UUID, user_id: uuid.UUID) -> Playlist:
    """Retorna a playlist somente se o usuário for o dono. Usar para editar/excluir."""
    result = await db.execute(
        select(Playlist).where(Playlist.id == playlist_id, Playlist.owner_id == user_id)
    )
    pl = result.scalar_one_or_none()
    if pl is None:
        raise HTTPException(status_code=404, detail="Playlist não encontrada")
    return pl


async def _get_writable_playlist(db: AsyncSession, playlist_id: uuid.UUID, user_id: uuid.UUID) -> tuple[Playlist, bool]:
    """Retorna (playlist, is_owner). Aceita dono OU colaborador."""
    result = await db.execute(select(Playlist).where(Playlist.id == playlist_id))
    pl = result.scalar_one_or_none()
    if pl is None:
        raise HTTPException(status_code=404, detail="Playlist não encontrada")

    if pl.owner_id == user_id:
        return pl, True

    # Check collaborator
    collab = await db.execute(
        select(PlaylistCollaborator).where(
            PlaylistCollaborator.playlist_id == playlist_id,
            PlaylistCollaborator.user_id == user_id,
        )
    )
    if collab.scalar_one_or_none() is not None:
        return pl, False

    raise HTTPException(status_code=403, detail="Você não tem permissão para editar esta playlist")


async def _track_count(db: AsyncSession, playlist_id: uuid.UUID) -> int:
    result = await db.execute(
        select(func.count()).where(PlaylistTrack.playlist_id == playlist_id)
    )
    return result.scalar_one()


async def _is_collaborator(db: AsyncSession, playlist_id: uuid.UUID, user_id: uuid.UUID) -> bool:
    result = await db.execute(
        select(PlaylistCollaborator).where(
            PlaylistCollaborator.playlist_id == playlist_id,
            PlaylistCollaborator.user_id == user_id,
        )
    )
    return result.scalar_one_or_none() is not None


@router.get("", response_model=list[PlaylistSchema])
async def list_playlists(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # Own playlists
    result = await db.execute(
        select(Playlist).where(Playlist.owner_id == current_user.id).order_by(Playlist.updated_at.desc())
    )
    own_playlists = result.scalars().all()

    # Collaborative playlists (where user is collaborator but not owner)
    collab_result = await db.execute(
        select(Playlist)
        .join(PlaylistCollaborator, PlaylistCollaborator.playlist_id == Playlist.id)
        .where(PlaylistCollaborator.user_id == current_user.id)
        .order_by(Playlist.updated_at.desc())
    )
    collab_playlists = collab_result.scalars().all()

    out = []
    for pl in own_playlists:
        count = await _track_count(db, pl.id)
        schema = PlaylistSchema.model_validate(pl)
        schema.track_count = count
        schema.is_collaborative = False
        out.append(schema)

    for pl in collab_playlists:
        count = await _track_count(db, pl.id)
        schema = PlaylistSchema.model_validate(pl)
        schema.track_count = count
        schema.is_collaborative = True
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
    await db.refresh(pl)
    schema = PlaylistSchema.model_validate(pl)
    schema.track_count = 0
    return schema


@router.get("/shared/{token}", response_model=PlaylistDetailSchema)
async def get_shared_playlist(token: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Playlist).where(Playlist.share_token == token, Playlist.is_shared == True))
    pl = result.scalar_one_or_none()
    if pl is None:
        raise HTTPException(status_code=404, detail="Playlist compartilhada não encontrada")
    return await _build_detail(db, pl, viewer_id=None)


@router.post("/shared/{token}/follow", status_code=201)
async def follow_shared_playlist(
    token: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Playlist).where(Playlist.share_token == token, Playlist.is_shared == True))
    source = result.scalar_one_or_none()
    if source is None:
        raise HTTPException(status_code=404, detail="Playlist compartilhada não encontrada")

    new_pl = Playlist(owner_id=current_user.id, name=source.name, description=source.description)
    db.add(new_pl)
    await db.flush()

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
    pl, _ = await _get_writable_playlist(db, playlist_id, current_user.id)
    return await _build_detail(db, pl, viewer_id=current_user.id)


@router.put("/{playlist_id}", response_model=PlaylistSchema)
async def update_playlist(
    playlist_id: uuid.UUID,
    body: PlaylistUpdateRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_owner_playlist(db, playlist_id, current_user.id)
    if body.name is not None:
        pl.name = body.name
    if body.description is not None:
        pl.description = body.description
    if body.cover_url is not None:
        pl.cover_url = body.cover_url
    if body.is_public is not None:
        pl.is_public = body.is_public
    await db.flush()
    await db.refresh(pl)
    schema = PlaylistSchema.model_validate(pl)
    schema.track_count = await _track_count(db, pl.id)
    return schema


@router.delete("/{playlist_id}", status_code=204)
async def delete_playlist(
    playlist_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    count = await db.execute(
        select(func.count()).select_from(Playlist).where(
            Playlist.id == playlist_id,
            Playlist.owner_id == current_user.id,
        )
    )
    if count.scalar_one() == 0:
        raise HTTPException(status_code=404, detail="Playlist não encontrada")
    await db.execute(delete(PlaylistTrack).where(PlaylistTrack.playlist_id == playlist_id))
    await db.execute(delete(PlaylistCollaborator).where(PlaylistCollaborator.playlist_id == playlist_id))
    await db.execute(delete(Playlist).where(Playlist.id == playlist_id))
    await db.flush()


@router.post("/{playlist_id}/tracks", status_code=201)
async def add_track(
    playlist_id: uuid.UUID,
    body: AddTrackRequest,
    force: bool = Query(default=False),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl, _ = await _get_writable_playlist(db, playlist_id, current_user.id)

    result = await db.execute(select(Track).where(Track.id == body.track_id))
    if result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Faixa não encontrada. Registre-a via /api/tracks/register")

    if not force:
        dup = await db.execute(
            select(PlaylistTrack).where(
                PlaylistTrack.playlist_id == playlist_id,
                PlaylistTrack.track_id == body.track_id,
            )
        )
        if dup.scalar_one_or_none() is not None:
            raise HTTPException(status_code=409, detail="Faixa já está na playlist")

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
    pl = await _get_owner_playlist(db, playlist_id, current_user.id)

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
    await db.flush()
    return {"cover_url": cover_url}


@router.delete("/{playlist_id}/tracks/{track_id}", status_code=204)
async def remove_track(
    playlist_id: uuid.UUID,
    track_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await _get_writable_playlist(db, playlist_id, current_user.id)
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
    await _get_writable_playlist(db, playlist_id, current_user.id)
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
    pl = await _get_owner_playlist(db, playlist_id, current_user.id)
    token = pl.generate_share_token()
    await db.flush()
    return ShareResponse(
        share_token=token,
        share_url=f"https://{settings.web_domain}/shared/{token}",
    )


# ── Collaborator endpoints ─────────────────────────────────────────────────────

@router.get("/{playlist_id}/collaborators", response_model=list[CollaboratorSchema])
async def get_collaborators(
    playlist_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # Only owner or collaborators can view the list
    await _get_writable_playlist(db, playlist_id, current_user.id)
    result = await db.execute(
        select(PlaylistCollaborator, User)
        .join(User, User.id == PlaylistCollaborator.user_id)
        .where(PlaylistCollaborator.playlist_id == playlist_id)
        .order_by(PlaylistCollaborator.added_at.asc())
    )
    out = []
    for collab, user in result.all():
        out.append(CollaboratorSchema(
            user_id=str(user.id),
            username=user.username,
            email=user.email,
            added_at=collab.added_at,
        ))
    return out


@router.post("/{playlist_id}/collaborators", status_code=201)
async def add_collaborator(
    playlist_id: uuid.UUID,
    body: dict,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Add a collaborator by username or email. Only the owner can do this."""
    pl = await _get_owner_playlist(db, playlist_id, current_user.id)

    identifier = body.get("username") or body.get("email")
    if not identifier:
        raise HTTPException(status_code=422, detail="Informe 'username' ou 'email'")

    from app.services import auth_service
    if "@" in identifier:
        user = await auth_service.get_user_by_email(db, identifier)
    else:
        user = await auth_service.get_user_by_username(db, identifier)

    if user is None:
        raise HTTPException(status_code=404, detail="Usuário não encontrado")
    if user.id == current_user.id:
        raise HTTPException(status_code=400, detail="Você já é o dono desta playlist")

    existing = await db.execute(
        select(PlaylistCollaborator).where(
            PlaylistCollaborator.playlist_id == playlist_id,
            PlaylistCollaborator.user_id == user.id,
        )
    )
    if existing.scalar_one_or_none() is not None:
        raise HTTPException(status_code=409, detail="Usuário já é colaborador desta playlist")

    db.add(PlaylistCollaborator(playlist_id=pl.id, user_id=user.id))
    await db.flush()
    return {"user_id": str(user.id), "username": user.username}


@router.delete("/{playlist_id}/collaborators/{user_id}", status_code=204)
async def remove_collaborator(
    playlist_id: uuid.UUID,
    user_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pl = await _get_owner_playlist(db, playlist_id, current_user.id)
    await db.execute(
        delete(PlaylistCollaborator).where(
            PlaylistCollaborator.playlist_id == playlist_id,
            PlaylistCollaborator.user_id == user_id,
        )
    )


# ── Helpers ────────────────────────────────────────────────────────────────────

async def _build_detail(db: AsyncSession, pl: Playlist, viewer_id: uuid.UUID | None) -> PlaylistDetailSchema:
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

    # Load collaborators
    collab_result = await db.execute(
        select(PlaylistCollaborator, User)
        .join(User, User.id == PlaylistCollaborator.user_id)
        .where(PlaylistCollaborator.playlist_id == pl.id)
        .order_by(PlaylistCollaborator.added_at.asc())
    )
    collaborator_schemas = [
        CollaboratorSchema(
            user_id=str(u.id),
            username=u.username,
            email=u.email,
            added_at=c.added_at,
        )
        for c, u in collab_result.all()
    ]

    is_collaborative = viewer_id is not None and pl.owner_id != viewer_id

    await db.refresh(pl)
    base = PlaylistSchema.model_validate(pl)
    base_data = base.model_dump()
    base_data['track_count'] = len(track_schemas)
    base_data['is_collaborative'] = is_collaborative
    return PlaylistDetailSchema(**base_data, tracks=track_schemas, collaborators=collaborator_schemas)
