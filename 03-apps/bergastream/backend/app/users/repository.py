"""Repositório de users/playlists — SQL puro."""
from __future__ import annotations
from typing import TYPE_CHECKING
from app.users.models import User, Playlist

if TYPE_CHECKING:
    import asyncpg


async def get_users(pool: "asyncpg.Pool") -> list[User]:
    rows = await pool.fetch("SELECT * FROM users ORDER BY name")
    return [User.model_validate(dict(r)) for r in rows]


async def get_user(pool: "asyncpg.Pool", user_id: str) -> User | None:
    row = await pool.fetchrow("SELECT * FROM users WHERE id=$1", user_id)
    return User.model_validate(dict(row)) if row else None


async def get_user_playlists(pool: "asyncpg.Pool", user_id: str) -> list[Playlist]:
    rows = await pool.fetch("SELECT * FROM playlists WHERE user_id=$1 ORDER BY name", user_id)
    return [Playlist.model_validate(dict(r)) for r in rows]


async def get_playlist(pool: "asyncpg.Pool", playlist_id: str) -> Playlist | None:
    row = await pool.fetchrow("SELECT * FROM playlists WHERE id=$1", playlist_id)
    return Playlist.model_validate(dict(row)) if row else None