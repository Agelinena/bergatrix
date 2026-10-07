"""Rotas de playlists: /api/me/playlists, /api/playlists/*, /api/users/directory."""
from __future__ import annotations

import logging
import uuid
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core.db import get_pool
from app.core.redis import get_redis
from app.downloads import queue as q
from app.playlists import ops as playlist_ops
from app.playlists import repository as repo
from app.playlists import service
from app.tracks import service as tracks_service
from app.tracks.models import PlayRequest

logger = logging.getLogger("bergastream.playlists")
router = APIRouter(prefix="/api", tags=["playlists"])

_COVERS = Path(settings.music_dir) / "covers"
_IMAGE_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
_MAX_COVER = 5 * 1024 * 1024
_ORDER = {"viewer": 0, "editor": 1, "owner": 2}


async def _require(playlist_id: str, user: CurrentUser, minimum: str) -> str:
    """Papel do usuário, exigindo pelo menos [minimum]. 404 se não vê (para
    não revelar playlists alheias), 403 se vê mas não pode."""
    try:
        uuid.UUID(playlist_id)
    except ValueError:
        raise HTTPException(404, detail="Playlist não encontrada")
    role = await service.access(get_pool(), playlist_id, user)
    if role is None:
        raise HTTPException(404, detail="Playlist não encontrada")
    if _ORDER[role] < _ORDER[minimum]:
        raise HTTPException(403, detail="Sem permissão para alterar esta playlist")
    return role


class NewPlaylist(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    description: str = Field("", max_length=500)


class PlaylistPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=100)
    description: str | None = Field(None, max_length=500)


class BulkTracks(BaseModel):
    tracks: list[PlayRequest] = Field(min_length=1, max_length=500)


class Order(BaseModel):
    track_ids: list[str] = Field(max_length=5000)


class MemberRole(BaseModel):
    role: str = Field(pattern="^(viewer|editor)$")


@router.get("/me/playlists", response_model=list[service.PlaylistSummary])
async def my_playlists(user: CurrentUser = Depends(current_user)):
    return await service.list_for(get_pool(), user.id)


@router.get("/users/directory", response_model=list[service.Person])
async def directory(user: CurrentUser = Depends(current_user)):
    """Usuários do servidor (para a tela "Pessoas" da playlist)."""
    rows = await get_pool().fetch("SELECT id, username, name FROM users ORDER BY name")
    return [service.Person(id=str(r["id"]), username=r["username"], name=r["name"]) for r in rows]


@router.post("/playlists", status_code=201, response_model=service.PlaylistSummary)
async def create(body: NewPlaylist, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    row = await pool.fetchrow(
        "INSERT INTO playlists (user_id, name, description) VALUES ($1, $2, $3) RETURNING id",
        user.id, body.name.strip(), body.description.strip())
    return await service.summary(pool, str(row["id"]), user.id)


@router.post("/playlists/ops", response_model=playlist_ops.BatchResult)
async def apply_ops(body: playlist_ops.OpBatch, user: CurrentUser = Depends(current_user)):
    """Alterações em lote, na ordem (inclusive as feitas offline nos apps).
    Ver app/playlists/ops.py: intenções, conflitos e reenvio seguro."""
    return await playlist_ops.apply_batch(get_pool(), user, body)


@router.get("/playlists/{playlist_id}", response_model=service.PlaylistDetail)
async def get_detail(playlist_id: str, user: CurrentUser = Depends(current_user)):
    role = await _require(playlist_id, user, "viewer")
    return await service.detail(get_pool(), playlist_id, user, role)


@router.patch("/playlists/{playlist_id}", response_model=service.PlaylistSummary)
async def update(playlist_id: str, body: PlaylistPatch, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "editor")
    pool = get_pool()
    if body.name is not None:
        await pool.execute("UPDATE playlists SET name = $2, updated_at = now() WHERE id = $1",
                           playlist_id, body.name.strip())
    if body.description is not None:
        await pool.execute("UPDATE playlists SET description = $2, updated_at = now() WHERE id = $1",
                           playlist_id, body.description.strip())
    return await service.summary(pool, playlist_id, user.id)


@router.delete("/playlists/{playlist_id}", status_code=204)
async def remove(playlist_id: str, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "owner")
    pool = get_pool()
    row = await pool.fetchrow("SELECT cover_path FROM playlists WHERE id = $1", playlist_id)
    for track_id in await service.delete(pool, playlist_id):
        await repo.release_if_orphan(pool, track_id)
    if row and row["cover_path"]:
        Path(row["cover_path"]).unlink(missing_ok=True)


@router.post("/playlists/{playlist_id}/tracks")
async def add_track(playlist_id: str, body: PlayRequest, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "editor")
    pool = get_pool()
    result = await tracks_service.resolve_and_register(pool, body)
    await repo.add_track_to_playlist(pool, playlist_id, result.track_id, user.id)
    if result.status != "ready":
        r = await get_redis()
        await q.enqueue(r, result.track_id, body.provider, priority=3,
                        external_id=body.external_id, title=body.title, artist=body.artist)
    return {"track_id": result.track_id, "playlist_id": playlist_id, "status": "permanent"}


async def _add_tracks_in_background(playlist_id: str, user_id: str, tracks: list[PlayRequest]) -> None:
    """Registra cada faixa, põe na playlist e enfileira o download com
    prioridade baixa (Seção 6.3: "baixa todas as faixas no servidor")."""
    pool = get_pool()
    r = await get_redis()
    added = 0
    for body in tracks:
        try:
            result = await tracks_service.resolve_and_register(pool, body)
            await repo.add_track_to_playlist(pool, playlist_id, result.track_id, user_id)
            if result.status != "ready":
                await q.enqueue(r, result.track_id, body.provider, priority=3,
                                external_id=body.external_id, title=body.title, artist=body.artist)
            added += 1
        except Exception as exc:
            logger.warning("[bulk] falhou %s - %s: %s", body.artist, body.title, exc)
    logger.info("[bulk] %d/%d faixas adicionadas à playlist %s", added, len(tracks), playlist_id)


@router.post("/playlists/{playlist_id}/tracks/bulk", status_code=202)
async def add_many(playlist_id: str, body: BulkTracks, background: BackgroundTasks,
                   user: CurrentUser = Depends(current_user)):
    """Adiciona várias faixas (link importado). Responde na hora; o
    registro e os downloads seguem em segundo plano."""
    await _require(playlist_id, user, "editor")
    background.add_task(_add_tracks_in_background, playlist_id, user.id, body.tracks)
    return {"playlist_id": playlist_id, "accepted": len(body.tracks)}


@router.delete("/playlists/{playlist_id}/tracks/{track_id}")
async def remove_track(playlist_id: str, track_id: str, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "editor")
    pool = get_pool()
    await repo.remove_track_from_playlist(pool, playlist_id, track_id)
    remaining = await repo.get_track_playlist_count(pool, track_id)
    return {"track_id": track_id, "playlist_id": playlist_id,
            "status": "permanent" if remaining else "cache", "remaining_playlists": remaining}


@router.put("/playlists/{playlist_id}/order", status_code=204)
async def reorder(playlist_id: str, body: Order, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "editor")
    await service.reorder(get_pool(), playlist_id, body.track_ids)


@router.put("/playlists/{playlist_id}/cover", response_model=service.PlaylistSummary)
async def upload_cover(playlist_id: str, file: UploadFile = File(...), user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "editor")
    ext = _IMAGE_TYPES.get(file.content_type or "")
    if ext is None:
        raise HTTPException(415, detail="Use uma imagem JPG, PNG ou WebP")
    data = await file.read(_MAX_COVER + 1)
    if len(data) > _MAX_COVER:
        raise HTTPException(413, detail="Imagem maior que 5 MB")
    pool = get_pool()
    _COVERS.mkdir(parents=True, exist_ok=True)
    old = await pool.fetchval("SELECT cover_path FROM playlists WHERE id = $1", playlist_id)
    path = _COVERS / f"{playlist_id}{ext}"
    if old and old != str(path):
        Path(old).unlink(missing_ok=True)
    path.write_bytes(data)
    await pool.execute("UPDATE playlists SET cover_path = $2, updated_at = now() WHERE id = $1",
                       playlist_id, str(path))
    return await service.summary(pool, playlist_id, user.id)


@router.get("/playlists/{playlist_id}/cover")
async def get_cover(playlist_id: str):
    """Pública (o id é um UUID): imagens da web não mandam cabeçalho de login."""
    try:
        uuid.UUID(playlist_id)
    except ValueError:
        raise HTTPException(404)
    path = await get_pool().fetchval("SELECT cover_path FROM playlists WHERE id = $1", playlist_id)
    if not path or not Path(path).exists():
        raise HTTPException(404)
    return FileResponse(path, headers={"Cache-Control": "public, max-age=31536000, immutable"})


@router.put("/playlists/{playlist_id}/members/{member_id}", status_code=204)
async def set_member(playlist_id: str, member_id: str, body: MemberRole, user: CurrentUser = Depends(current_user)):
    """Dono define quem vê e quem edita (tela "Pessoas")."""
    await _require(playlist_id, user, "owner")
    pool = get_pool()
    owner = await pool.fetchval("SELECT user_id FROM playlists WHERE id = $1", playlist_id)
    if str(owner) == member_id:
        raise HTTPException(400, detail="O dono já tem acesso total")
    if not await pool.fetchval("SELECT 1 FROM users WHERE id = $1", member_id):
        raise HTTPException(404, detail="Usuário não encontrado")
    await pool.execute(
        """INSERT INTO playlist_members (playlist_id, user_id, role) VALUES ($1, $2, $3)
           ON CONFLICT (playlist_id, user_id) DO UPDATE SET role = EXCLUDED.role""",
        playlist_id, member_id, body.role)
    await pool.execute("UPDATE playlists SET updated_at = now() WHERE id = $1", playlist_id)


@router.delete("/playlists/{playlist_id}/members/{member_id}", status_code=204)
async def remove_member(playlist_id: str, member_id: str, user: CurrentUser = Depends(current_user)):
    await _require(playlist_id, user, "owner")
    pool = get_pool()
    await pool.execute("DELETE FROM playlist_members WHERE playlist_id = $1 AND user_id = $2",
                       playlist_id, member_id)
    await pool.execute("UPDATE playlists SET updated_at = now() WHERE id = $1", playlist_id)
