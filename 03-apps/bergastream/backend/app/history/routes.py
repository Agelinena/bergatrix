"""Histórico de reprodução e estatísticas: /api/history, /api/me/stats."""
from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.core.db import get_pool
from app.tracks import service as tracks_service
from app.tracks.models import PlayRequest

logger = logging.getLogger("bergastream.history")
router = APIRouter(prefix="/api", tags=["history"])

_MAX_BATCH = 500


class Play(BaseModel):
    """Uma reprodução contada no app (30 s ou metade da faixa)."""
    client_id: uuid.UUID
    played_at: datetime
    track: PlayRequest
    # Tocada a partir de uma playlist (ordem da Biblioteca).
    playlist_id: uuid.UUID | None = None


class PlayBatch(BaseModel):
    plays: list[Play] = Field(min_length=1, max_length=_MAX_BATCH)


class StatTrack(BaseModel):
    provider: str
    external_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    isrc: str | None = None
    cover_url: str | None = None
    plays: int


class StatArtist(BaseModel):
    name: str
    plays: int
    image_url: str | None = None


class StatAlbum(BaseModel):
    title: str
    artist: str
    cover_url: str | None = None
    plays: int


class Stats(BaseModel):
    month: str  # "2026-10"
    seconds_month: int
    distinct_tracks_month: int
    plays_month: int
    top_artists: list[StatArtist] = []
    top_tracks: list[StatTrack] = []
    top_albums: list[StatAlbum] = []


@router.post("/history")
async def record(body: PlayBatch, user: CurrentUser = Depends(current_user)):
    """Registra reproduções (uma ou várias, na ordem). Repetir um client_id
    é ignorado: reenviar a fila offline não duplica."""
    pool = get_pool()
    accepted = duplicates = 0
    for play in sorted(body.plays, key=lambda p: p.played_at):
        try:
            result = await tracks_service.resolve_and_register(pool, play.track)
        except Exception as exc:
            logger.warning("[history] faixa não registrada %s: %s", play.track.title, exc)
            continue
        status = await pool.execute(
            # Playlist apagada nesse meio-tempo: registra sem ela.
            """INSERT INTO play_history (user_id, track_id, client_id, played_at, playlist_id)
               VALUES ($1, $2, $3, $4, (SELECT id FROM playlists WHERE id = $5))
               ON CONFLICT (client_id) DO NOTHING""",
            user.id, result.track_id, play.client_id, play.played_at, play.playlist_id)
        if status.endswith(" 1"):
            accepted += 1
        else:
            duplicates += 1
    return {"accepted": accepted, "duplicates": duplicates}


@router.get("/me/stats", response_model=Stats)
async def stats(user: CurrentUser = Depends(current_user)):
    """Métricas do mês atual (UTC): horas ouvidas, músicas diferentes e os
    mais ouvidos (artistas, faixas, álbuns)."""
    pool = get_pool()
    now = datetime.now(timezone.utc)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    base = """FROM play_history h JOIN tracks t ON t.id = h.track_id
              WHERE h.user_id = $1 AND h.played_at >= $2"""
    totals = await pool.fetchrow(
        f"SELECT coalesce(sum(t.duration_seconds), 0) AS secs, count(DISTINCT h.track_id) AS distinct_tracks, count(*) AS plays {base}",
        user.id, start)
    artists = await pool.fetch(
        f"""SELECT t.artist AS name, count(*) AS plays, max(t.cover_url) AS image_url {base}
            GROUP BY t.artist ORDER BY plays DESC, name LIMIT 8""", user.id, start)
    tracks = await pool.fetch(
        f"""SELECT t.id, t.title, t.artist, coalesce(t.album, '') AS album, t.duration_seconds,
                   t.isrc, t.cover_url, count(*) AS plays,
                   (SELECT provider FROM external_ids x WHERE x.track_id = t.id
                    ORDER BY CASE provider WHEN 'spotify' THEN 0 WHEN 'deezer' THEN 1 ELSE 2 END LIMIT 1) AS provider,
                   (SELECT external_id FROM external_ids x WHERE x.track_id = t.id
                    ORDER BY CASE provider WHEN 'spotify' THEN 0 WHEN 'deezer' THEN 1 ELSE 2 END LIMIT 1) AS external_id
            {base} GROUP BY t.id ORDER BY plays DESC, t.title LIMIT 10""", user.id, start)
    albums = await pool.fetch(
        f"""SELECT t.album AS title, t.artist, max(t.cover_url) AS cover_url, count(*) AS plays {base}
              AND coalesce(t.album, '') <> ''
            GROUP BY t.album, t.artist ORDER BY plays DESC, title LIMIT 8""", user.id, start)
    return Stats(
        month=start.strftime("%Y-%m"),
        seconds_month=totals["secs"], distinct_tracks_month=totals["distinct_tracks"],
        plays_month=totals["plays"],
        top_artists=[StatArtist(**dict(a)) for a in artists],
        top_tracks=[StatTrack(provider=r["provider"] or "bergastream",
                              external_id=r["external_id"] or str(r["id"]),
                              title=r["title"], artist=r["artist"], album=r["album"],
                              duration_seconds=r["duration_seconds"] or 0, isrc=r["isrc"],
                              cover_url=r["cover_url"], plays=r["plays"]) for r in tracks],
        top_albums=[StatAlbum(**dict(a)) for a in albums],
    )
