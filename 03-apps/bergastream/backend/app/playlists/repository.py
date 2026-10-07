"""Repositório de playlist_tracks + lógica de permanência."""
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg


async def add_track_to_playlist(
    pool: "asyncpg.Pool", playlist_id: str, track_id: str, added_by: str | None = None
) -> bool:
    """Adiciona faixa no fim da playlist (quem adicionou e posição) e aplica
    a transição para permanent. Faixa repetida não entra de novo."""
    await pool.execute(
        """INSERT INTO playlist_tracks (playlist_id, track_id, added_by, position)
           VALUES ($1, $2, $3,
                   COALESCE((SELECT max(position) FROM playlist_tracks WHERE playlist_id = $1), 0) + 1)
           ON CONFLICT DO NOTHING""",
        playlist_id, track_id, added_by,
    )
    await pool.execute("UPDATE playlists SET updated_at = now() WHERE id = $1", playlist_id)
    # Atualiza kind para permanent
    await pool.execute(
        "UPDATE files SET kind = 'permanent' WHERE track_id = $1 AND kind != 'permanent'",
        track_id,
    )
    return True


async def remove_track_from_playlist(pool: "asyncpg.Pool", playlist_id: str, track_id: str) -> bool:
    """Remove faixa da playlist. Se for a última, vira cache."""
    await pool.execute(
        "DELETE FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2",
        playlist_id, track_id,
    )
    await pool.execute("UPDATE playlists SET updated_at = now() WHERE id = $1", playlist_id)
    await release_if_orphan(pool, track_id)
    return True


async def release_if_orphan(pool: "asyncpg.Pool", track_id: str) -> None:
    """Faixa que não está em nenhuma playlist vira cache (com o timer
    zerado), para a limpeza apagar depois do TTL."""
    remaining = await pool.fetchval(
        "SELECT count(*) FROM playlist_tracks WHERE track_id = $1", track_id,
    )
    if remaining == 0:
        await pool.execute(
            "UPDATE files SET kind = 'cache', last_played_at = now() WHERE track_id = $1",
            track_id,
        )


async def get_track_playlist_count(pool: "asyncpg.Pool", track_id: str) -> int:
    return await pool.fetchval(
        "SELECT count(*) FROM playlist_tracks WHERE track_id = $1", track_id,
    ) or 0
