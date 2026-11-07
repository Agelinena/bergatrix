"""Músicas que não deu para baixar, para o admin resolver.

O worker grava aqui quando todas as fontes falham (Deemix, YouTube) e apaga
quando a música é baixada. Na aba de admin dá para tentar de novo, escolher
a fonte à mão (busca no YouTube Music e no Deezer) ou ignorar.

Rotas (só admin):
  GET  /api/admin/failures?ignored=      lista
  POST /api/admin/failures/{id}/retry    tenta de novo (fila alta)
  GET  /api/admin/failures/{id}/candidates?q=   versões para escolher
  POST /api/admin/failures/{id}/source   {provider, external_id}: baixa esta
  POST /api/admin/failures/{id}/ignore   {ignored}: some da lista (ou volta)
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, admin_user
from app.core.db import get_pool
from app.core.redis import get_redis
from app.downloads import queue as q
from app.search.models import SearchResult

logger = logging.getLogger("bergastream.downloads.failures")
router = APIRouter(prefix="/api/admin/failures", tags=["admin"])

# Fontes que o worker baixa com um id direto.
SOURCES = ("ytmusic", "youtube", "deezer")


# ── Registro (worker) ────────────────────────────────────────────

async def record(pool, track_id: str, provider: str, external_id: str, error: str) -> None:
    """Mais uma falha da faixa (conta as tentativas; não tira o "ignorar")."""
    await pool.execute(
        """INSERT INTO download_failures (track_id, provider, external_id, error)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (track_id) DO UPDATE
           SET provider = $2, external_id = $3, error = $4,
               attempts = download_failures.attempts + 1, last_failed_at = now()""",
        track_id, provider, external_id or None, (error or "Falhou")[:500])


async def resolve(pool, track_id: str) -> None:
    await pool.execute("DELETE FROM download_failures WHERE track_id = $1", track_id)


# ── Admin ────────────────────────────────────────────────────────

class Failure(BaseModel):
    track_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    cover_url: str | None = None
    provider: str | None = None
    error: str | None = None
    attempts: int = 1
    first_failed_at: datetime
    last_failed_at: datetime
    ignored: bool = False
    # Em quantas playlists a música está (o que mais importa resolver).
    playlists: int = 0
    # Já está na fila de novo (tentativa em andamento).
    queued: bool = False


class Source(BaseModel):
    provider: str = Field(pattern="^(ytmusic|youtube|deezer)$")
    external_id: str = Field(min_length=1, max_length=64)


class IgnoreBody(BaseModel):
    ignored: bool = True


async def _row(pool, track_id: str):
    try:
        uuid.UUID(track_id)
    except ValueError:
        raise HTTPException(404, detail="Falha não encontrada")
    row = await pool.fetchrow(
        """SELECT f.*, t.title, t.artist, coalesce(t.album, '') AS album,
                  t.duration_seconds, t.cover_url
           FROM download_failures f JOIN tracks t ON t.id = f.track_id
           WHERE f.track_id = $1""", track_id)
    if row is None:
        raise HTTPException(404, detail="Falha não encontrada")
    return row


@router.get("", response_model=list[Failure])
async def list_failures(ignored: bool = False, _: CurrentUser = Depends(admin_user)):
    pool = get_pool()
    rows = await pool.fetch(
        """SELECT f.*, t.title, t.artist, coalesce(t.album, '') AS album,
                  t.duration_seconds, t.cover_url,
                  (SELECT count(*) FROM playlist_tracks pt WHERE pt.track_id = f.track_id)
                    AS playlists
           FROM download_failures f JOIN tracks t ON t.id = f.track_id
           WHERE (f.ignored_at IS NOT NULL) = $1
             AND NOT EXISTS (SELECT 1 FROM files WHERE files.track_id = f.track_id)
           ORDER BY playlists DESC, f.last_failed_at DESC
           LIMIT 500""", ignored)
    redis = await get_redis()
    out = []
    for r in rows:
        job = await q.pending_job(redis, str(r["track_id"]))
        out.append(Failure(
            track_id=str(r["track_id"]), title=r["title"], artist=r["artist"], album=r["album"],
            duration_seconds=r["duration_seconds"] or 0, cover_url=r["cover_url"],
            provider=r["provider"], error=r["error"], attempts=r["attempts"],
            first_failed_at=r["first_failed_at"], last_failed_at=r["last_failed_at"],
            ignored=r["ignored_at"] is not None, playlists=r["playlists"],
            queued=bool(job and job.get("status") in ("queued", "downloading"))))
    return out


async def _enqueue(track_id: str, provider: str, external_id: str) -> None:
    redis = await get_redis()
    # Um pedido antigo terminado ainda pode estar ligado à faixa: o novo vale.
    job = await q.pending_job(redis, track_id)
    if job and job.get("status") not in ("queued", "downloading"):
        await redis.delete(q.track_job_key(track_id))
    await q.enqueue(redis, track_id, provider, priority=1, external_id=external_id)


@router.post("/{track_id}/retry")
async def retry(track_id: str, admin: CurrentUser = Depends(admin_user)):
    row = await _row(get_pool(), track_id)
    await _enqueue(track_id, row["provider"] or "spotify", row["external_id"] or "")
    logger.info("[falhas] %s pediu de novo %s", admin.id, track_id)
    return {"queued": True}


@router.get("/{track_id}/candidates", response_model=list[SearchResult])
async def candidates(track_id: str, q_: str = Query("", alias="q", max_length=200),
                     _: CurrentUser = Depends(admin_user)):
    """Versões no YouTube Music e no Deezer, a de duração mais parecida
    primeiro. [q] troca o texto da busca (padrão: artista e título)."""
    from app.search import deezer, ytmusic
    row = await _row(get_pool(), track_id)
    query = q_.strip() or f"{row['artist'].split(',')[0]} {row['title']}"

    def search_all() -> list[SearchResult]:
        found: list[SearchResult] = []
        for search in (lambda: ytmusic.search(query, limit=8),
                       lambda: deezer.search_full(query, limit=8).tracks):
            try:
                found.extend(search())
            except Exception as exc:  # uma fonte fora não impede a outra
                logger.info("[falhas] busca de candidatos falhou: %s", exc)
        return found

    found = await asyncio.to_thread(search_all)
    duration = row["duration_seconds"] or 0
    found.sort(key=lambda r: abs((r.duration_seconds or 0) - duration) if duration else 0)
    return [r for r in found if r.provider in SOURCES][:16]


@router.post("/{track_id}/source")
async def choose_source(track_id: str, body: Source, admin: CurrentUser = Depends(admin_user)):
    """Baixa a música desta fonte (escolhida pelo admin)."""
    await _row(get_pool(), track_id)
    await _enqueue(track_id, body.provider, body.external_id)
    logger.info("[falhas] %s escolheu %s:%s para %s", admin.id, body.provider,
                body.external_id, track_id)
    return {"queued": True}


@router.post("/{track_id}/ignore")
async def ignore(track_id: str, body: IgnoreBody, admin: CurrentUser = Depends(admin_user)):
    pool = get_pool()
    await _row(pool, track_id)
    await pool.execute(
        """UPDATE download_failures
           SET ignored_at = CASE WHEN $2 THEN now() END,
               ignored_by = CASE WHEN $2 THEN $3::uuid END
           WHERE track_id = $1""", track_id, body.ignored, admin.id)
    return {"ignored": body.ignored}
