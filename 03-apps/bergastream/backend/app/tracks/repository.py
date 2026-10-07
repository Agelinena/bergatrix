"""Repositório de tracks/external_ids — SQL puro com asyncpg.

Cada função recebe o pool como primeiro argumento e retorna modelos Pydantic.
"""

from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

from app.tracks.models import Track

if TYPE_CHECKING:
    import asyncpg


async def get_track_by_external_id(
    pool: "asyncpg.Pool",
    provider: str,
    external_id: str,
) -> Track | None:
    """Procura uma faixa por (provider, external_id)."""
    row = await pool.fetchrow(
        """SELECT t.* FROM tracks t
           JOIN external_ids e ON e.track_id = t.id
           WHERE e.provider = $1 AND e.external_id = $2""",
        provider, external_id,
    )
    return Track.model_validate(dict(row)) if row else None


async def get_track_by_isrc(
    pool: "asyncpg.Pool",
    isrc: str,
) -> Track | None:
    """Procura uma faixa pelo ISRC (único na tabela tracks)."""
    row = await pool.fetchrow(
        "SELECT * FROM tracks WHERE isrc = $1",
        isrc,
    )
    return Track.model_validate(dict(row)) if row else None


async def get_track_by_id(
    pool: "asyncpg.Pool",
    track_id: str,
) -> Track | None:
    """Busca faixa pelo ID interno."""
    row = await pool.fetchrow(
        "SELECT * FROM tracks WHERE id = $1",
        track_id,
    )
    return Track.model_validate(dict(row)) if row else None


async def find_track_fuzzy(
    pool: "asyncpg.Pool",
    title: str,
    artist: str,
    duration_seconds: int,
    tolerance: int = 3,
) -> Track | None:
    """Busca heurística: artista contém, título contém, duração ±tolerance."""
    row = await pool.fetchrow(
        """SELECT * FROM tracks
           WHERE artist ILIKE $1
           AND title ILIKE $2
           AND ABS(duration_seconds - $3) <= $4
           LIMIT 1""",
        f"%{artist[:200]}%", f"%{title[:200]}%", duration_seconds, tolerance,
    )
    return Track.model_validate(dict(row)) if row else None


async def create_track(
    pool: "asyncpg.Pool",
    title: str,
    artist: str,
    album: str | None,
    duration_seconds: int,
    isrc: str | None,
    cover_url: str | None,
) -> Track:
    """Insere uma nova faixa e retorna o registro completo."""
    row = await pool.fetchrow(
        """INSERT INTO tracks (title, artist, album, duration_seconds, isrc, cover_url)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING *""",
        title, artist, album, duration_seconds, isrc, cover_url,
    )
    return Track.model_validate(dict(row))


async def link_external_id(
    pool: "asyncpg.Pool",
    track_id: uuid.UUID | str,
    provider: str,
    external_id: str,
) -> None:
    """Insere um vínculo (track_id, provider, external_id)."""
    await pool.execute(
        """INSERT INTO external_ids (track_id, provider, external_id)
           VALUES ($1, $2, $3)
           ON CONFLICT (provider, external_id) DO NOTHING""",
        track_id, provider, external_id,
    )


async def track_has_file(
    pool: "asyncpg.Pool",
    track_id: str,
) -> bool:
    """Verifica se a faixa tem arquivo registrado na tabela files."""
    row = await pool.fetchrow(
        "SELECT 1 FROM files WHERE track_id = $1 LIMIT 1",
        track_id,
    )
    return row is not None