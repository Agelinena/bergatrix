"""Alterações de playlist em lote (POST /api/playlists/ops).

Os apps guardam cada alteração como uma *intenção* ("adicionar X", "remover
Y", "mover Z para depois de W", "renomear de A para B") e mandam a fila
quando há servidor. Aplicar intenções sobre o estado atual combina o que foi
feito offline com o que outra pessoa (ou a web) mudou nesse meio-tempo:

- adicionar/remover/mover nunca sobrescrevem a lista inteira;
- renomear compara com o nome que o aparelho conhecia (`base`): se o nome no
  servidor também mudou, é conflito e nada é sobrescrito;
- apagar compara com o `updated_at` que o aparelho conhecia: se a playlist
  mudou desde então, é conflito (a não ser com `force`).

Cada operação tem `op_id` (UUID do aparelho). Reenviar a mesma operação
devolve o resultado guardado em `playlist_ops`, sem aplicar de novo.

Referências temporárias: uma playlist criada offline tem um `ref` (ex.
"tmp:…") até existir no servidor; uma faixa adicionada offline também. As
operações seguintes do mesmo lote podem usar esses refs no lugar dos ids.
"""
from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal

from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser
from app.core.redis import get_redis
from app.downloads import queue as q
from app.images import routes as images
from app.playlists import repository as repo
from app.playlists import service
from app.tracks import service as tracks_service
from app.tracks.models import PlayRequest

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.playlists.ops")

_ORDER = {"viewer": 0, "editor": 1, "owner": 2}

# Prefixo dos ids temporários criados no aparelho.
REF_PREFIX = "tmp:"

# Estados finais: o aparelho tira a operação da fila. "retry" fica na fila.
Status = Literal["applied", "conflict", "gone", "forbidden", "invalid", "retry"]


class Op(BaseModel):
    op_id: uuid.UUID
    type: Literal["create", "rename", "add", "remove", "move", "delete", "cover"]
    playlist: str | None = None     # id ou ref (todas menos create)
    ref: str | None = None          # create: ref da playlist; add: ref da faixa
    name: str | None = Field(None, max_length=100)
    description: str | None = Field(None, max_length=500)  # create
    url: str | None = Field(None, max_length=2048)  # cover: capa da origem
    base: str | None = None         # rename: nome que o aparelho conhecia
    track: Any = None               # add: SearchResult; remove/move: id ou ref
    after: str | None = None        # move: faixa que fica antes (None = topo)
    before: str | None = None       # move: faixa que fica depois (reserva)
    base_updated_at: str | None = None  # delete
    force: bool = False             # delete / rename: aplica mesmo em conflito


class OpBatch(BaseModel):
    ops: list[Op] = Field(min_length=1, max_length=500)


class OpResult(BaseModel):
    op_id: str
    status: Status
    playlist_id: str | None = None
    track_id: str | None = None
    current: dict | None = None     # conflito: o que está no servidor
    message: str | None = None


class BatchResult(BaseModel):
    results: list[OpResult]
    refs: dict[str, str]


class _Fail(Exception):
    def __init__(self, status: Status, message: str, current: dict | None = None):
        self.status, self.message, self.current = status, message, current


async def apply_batch(pool: "asyncpg.Pool", user: CurrentUser, batch: OpBatch) -> BatchResult:
    refs: dict[str, str] = {}
    results: list[OpResult] = []
    for op in batch.ops:
        stored = await pool.fetchval(
            "SELECT result FROM playlist_ops WHERE op_id = $1 AND user_id = $2", op.op_id, user.id)
        if stored is not None:
            result = OpResult(**json.loads(stored))
        else:
            result = await _apply_one(pool, user, op, refs)
            if result.status != "retry" and op.type != "create":
                # create grava o registro na mesma transação (ver _create).
                await _remember(pool, user, result)
        if op.ref and result.status == "applied":
            if op.type == "create" and result.playlist_id:
                refs[op.ref] = result.playlist_id
            elif op.type == "add" and result.track_id:
                refs[op.ref] = result.track_id
        results.append(result)
    return BatchResult(results=results, refs=refs)


async def _remember(conn, user: CurrentUser, result: OpResult) -> None:
    await conn.execute(
        "INSERT INTO playlist_ops (op_id, user_id, result) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
        uuid.UUID(result.op_id), user.id, result.model_dump_json())


async def _apply_one(pool, user: CurrentUser, op: Op, refs: dict[str, str]) -> OpResult:
    op_id = str(op.op_id)
    if op.type == "create":
        return await _create(pool, user, op)
    pending = [v for v in (op.playlist, op.track if isinstance(op.track, str) else None,
                           op.after, op.before)
               if isinstance(v, str) and v.startswith(REF_PREFIX) and v not in refs]
    if pending:
        # Depende de algo que ainda não existe no servidor (a criação ou a
        # adição ficou para depois): espera junto, na mesma ordem.
        return OpResult(op_id=op_id, status="retry", message="Aguardando " + pending[0])
    playlist_id = refs.get(op.playlist or "", op.playlist)
    try:
        if not playlist_id or not _is_uuid(playlist_id):
            # Ref de playlist que não foi criada (create falhou neste lote).
            raise _Fail("gone", "Playlist não encontrada")
        role = await service.access(pool, playlist_id, user)
        if role is None:
            raise _Fail("gone", "Playlist não encontrada")
        need = "owner" if op.type == "delete" else "editor"
        if _ORDER[role] < _ORDER[need]:
            raise _Fail("forbidden", "Sem permissão para alterar esta playlist")
        handler = {"rename": _rename, "add": _add, "remove": _remove,
                   "move": _move, "delete": _delete, "cover": _cover}[op.type]
        return await handler(pool, user, op, playlist_id, refs)
    except _Fail as e:
        return OpResult(op_id=op_id, status=e.status, playlist_id=playlist_id,
                        current=e.current, message=e.message)


async def _create(pool, user: CurrentUser, op: Op) -> OpResult:
    name = (op.name or "").strip()
    if not name:
        return OpResult(op_id=str(op.op_id), status="invalid", message="Nome vazio")
    async with pool.acquire() as conn:
        async with conn.transaction():
            # Playlist e registro juntos: reenviar nunca cria duas.
            playlist_id = str(await conn.fetchval(
                "INSERT INTO playlists (user_id, name, description) VALUES ($1, $2, $3) RETURNING id",
                user.id, name, (op.description or "").strip()[:500]))
            result = OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id)
            await _remember(conn, user, result)
    return result


async def _rename(pool, user, op: Op, playlist_id: str, refs) -> OpResult:
    name = (op.name or "").strip()
    if not name:
        raise _Fail("invalid", "Nome vazio")
    current = await pool.fetchval("SELECT name FROM playlists WHERE id = $1", playlist_id)
    if current != name:
        if not op.force and op.base is not None and current != op.base:
            # Mudou nos dois lados: o servidor fica com o que tem.
            raise _Fail("conflict", "O nome mudou em outro lugar", {"name": current})
        await pool.execute("UPDATE playlists SET name = $2, updated_at = now() WHERE id = $1",
                           playlist_id, name)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id)


async def _add(pool, user: CurrentUser, op: Op, playlist_id: str, refs) -> OpResult:
    try:
        body = PlayRequest.model_validate(op.track)
    except Exception:
        raise _Fail("invalid", "Faixa inválida")
    try:
        result = await tracks_service.resolve_and_register(pool, body)
    except Exception as exc:
        # Falha passageira (rede para o YouTube, por exemplo): fica na fila.
        logger.warning("[ops] não registrou %s - %s: %s", body.artist, body.title, exc)
        return OpResult(op_id=str(op.op_id), status="retry", playlist_id=playlist_id,
                        message="Não foi possível registrar a faixa agora")
    await repo.add_track_to_playlist(pool, playlist_id, result.track_id, user.id)
    if result.status != "ready":
        await q.enqueue(await get_redis(), result.track_id, body.provider, priority=3,
                        external_id=body.external_id, title=body.title, artist=body.artist)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id,
                    track_id=result.track_id)


async def _remove(pool, user, op: Op, playlist_id: str, refs) -> OpResult:
    track_id = refs.get(op.track, op.track) if isinstance(op.track, str) else None
    if track_id and _is_uuid(track_id):
        # Já removida (aqui ou em outro lugar): não é erro.
        await repo.remove_track_from_playlist(pool, playlist_id, track_id)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id,
                    track_id=track_id)


async def _move(pool, user, op: Op, playlist_id: str, refs) -> OpResult:
    track_id = refs.get(op.track, op.track) if isinstance(op.track, str) else None
    after = refs.get(op.after, op.after) if op.after else None
    before = refs.get(op.before, op.before) if op.before else None
    order = [str(r["track_id"]) for r in await pool.fetch(
        "SELECT track_id FROM playlist_tracks WHERE playlist_id = $1 ORDER BY position, added_at",
        playlist_id)]
    if track_id not in order:
        # Saiu da playlist em outro lugar: nada a mover.
        return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id,
                        track_id=track_id, message="Faixa não está mais na playlist")
    original = order.index(track_id)
    order.remove(track_id)
    if op.after is None:
        index = 0                               # para o topo
    elif after in order:
        index = order.index(after) + 1
    elif before in order:
        index = order.index(before)
    else:
        index = original                        # vizinhas sumiram: fica onde está
    order.insert(index, track_id)
    await service.reorder(pool, playlist_id, order)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id,
                    track_id=track_id)


async def _delete(pool, user, op: Op, playlist_id: str, refs) -> OpResult:
    if not op.force and op.base_updated_at:
        updated_at = await pool.fetchval("SELECT updated_at FROM playlists WHERE id = $1", playlist_id)
        try:
            base = datetime.fromisoformat(op.base_updated_at)
        except ValueError:
            raise _Fail("invalid", "Data inválida")
        if updated_at > base:
            summary = await service.summary(pool, playlist_id, user.id)
            raise _Fail("conflict", "A playlist mudou em outro lugar",
                        {"name": summary.name, "track_count": summary.track_count,
                         "updated_at": summary.updated_at})
    cover = await pool.fetchval("SELECT cover_path FROM playlists WHERE id = $1", playlist_id)
    for track_id in await service.delete(pool, playlist_id):
        await repo.release_if_orphan(pool, track_id)
    if cover:
        Path(cover).unlink(missing_ok=True)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id)


async def _cover(pool, user, op: Op, playlist_id: str, refs) -> OpResult:
    """Capa a partir da imagem da playlist original (importação de link).
    Só hosts de capas conhecidos, como o proxy de imagens."""
    try:
        data, ext = await images.fetch_allowed_image(op.url or "")
    except images.ImageError as exc:
        if exc.transient:
            return OpResult(op_id=str(op.op_id), status="retry", playlist_id=playlist_id,
                            message=str(exc))
        raise _Fail("invalid", str(exc))
    await service.save_cover(pool, playlist_id, data, ext)
    return OpResult(op_id=str(op.op_id), status="applied", playlist_id=playlist_id)


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError):
        return False
