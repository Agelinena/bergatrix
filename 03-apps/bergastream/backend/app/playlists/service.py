"""Playlists completas: listas, detalhe, permissões e colaboradores (SQL)."""
from __future__ import annotations

from typing import TYPE_CHECKING

from pydantic import BaseModel

from app.auth.dependencies import CurrentUser

if TYPE_CHECKING:
    import asyncpg

ROLES = ("viewer", "editor")


class Person(BaseModel):
    id: str
    username: str
    name: str


class PlaylistSummary(BaseModel):
    id: str
    name: str
    description: str = ""
    owner: Person
    role: str  # owner | editor | viewer
    track_count: int
    duration_seconds: int
    people_count: int
    cover_url: str | None = None
    updated_at: str


class PlaylistTrack(BaseModel):
    track_id: str
    provider: str
    external_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    isrc: str | None = None
    cover_url: str | None = None
    added_by: Person | None = None
    added_at: str
    position: int
    ready: bool  # arquivo pronto no servidor
    size_bytes: int | None = None


class Member(BaseModel):
    user: Person
    role: str


class PlaylistDetail(PlaylistSummary):
    members: list[Member] = []
    tracks: list[PlaylistTrack] = []


def _person(row, prefix: str) -> Person | None:
    if row[f"{prefix}_id"] is None:
        return None
    return Person(id=str(row[f"{prefix}_id"]), username=row[f"{prefix}_username"],
                  name=row[f"{prefix}_name"])


def cover_url(playlist_id, cover_path: str | None, updated_at) -> str | None:
    if not cover_path:
        return None
    return f"/api/playlists/{playlist_id}/cover?v={int(updated_at.timestamp())}"


async def access(pool: "asyncpg.Pool", playlist_id: str, user: CurrentUser) -> str | None:
    """Papel do usuário na playlist: owner, editor, viewer ou None."""
    row = await pool.fetchrow(
        """SELECT p.user_id, m.role FROM playlists p
           LEFT JOIN playlist_members m ON m.playlist_id = p.id AND m.user_id = $2
           WHERE p.id = $1""",
        playlist_id, user.id)
    if row is None:
        return None
    if str(row["user_id"]) == user.id or user.is_admin:
        return "owner"
    return row["role"]


_SUMMARY_SQL = """
SELECT p.id, p.name, p.description, p.cover_path, p.updated_at,
       o.id AS owner_id, o.username AS owner_username, o.name AS owner_name,
       CASE WHEN p.user_id = $1 THEN 'owner' ELSE m.role END AS role,
       (SELECT count(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id) AS track_count,
       (SELECT coalesce(sum(t.duration_seconds), 0) FROM playlist_tracks pt
          JOIN tracks t ON t.id = pt.track_id WHERE pt.playlist_id = p.id) AS duration_seconds,
       1 + (SELECT count(*) FROM playlist_members pm WHERE pm.playlist_id = p.id) AS people_count
FROM playlists p
JOIN users o ON o.id = p.user_id
LEFT JOIN playlist_members m ON m.playlist_id = p.id AND m.user_id = $1
"""


def _summary(row) -> PlaylistSummary:
    return PlaylistSummary(
        id=str(row["id"]), name=row["name"], description=row["description"],
        owner=_person(row, "owner"), role=row["role"] or "owner",
        track_count=row["track_count"], duration_seconds=row["duration_seconds"],
        people_count=row["people_count"],
        cover_url=cover_url(row["id"], row["cover_path"], row["updated_at"]),
        updated_at=row["updated_at"].isoformat())


async def list_for(pool: "asyncpg.Pool", user_id: str) -> list[PlaylistSummary]:
    """Playlists do usuário e as compartilhadas com ele."""
    rows = await pool.fetch(
        _SUMMARY_SQL + " WHERE p.user_id = $1 OR m.user_id IS NOT NULL ORDER BY p.updated_at DESC",
        user_id)
    return [_summary(r) for r in rows]


async def summary(pool: "asyncpg.Pool", playlist_id: str, user_id: str) -> PlaylistSummary | None:
    row = await pool.fetchrow(_SUMMARY_SQL + " WHERE p.id = $2", user_id, playlist_id)
    return _summary(row) if row else None


async def detail(pool: "asyncpg.Pool", playlist_id: str, user: CurrentUser, role: str) -> PlaylistDetail:
    base = await summary(pool, playlist_id, user.id)
    base.role = role
    tracks = await pool.fetch(
        """SELECT t.id AS track_id, t.title, t.artist, coalesce(t.album, '') AS album,
                  t.duration_seconds, t.isrc, t.cover_url, pt.added_at, pt.position,
                  u.id AS by_id, u.username AS by_username, u.name AS by_name,
                  f.track_id IS NOT NULL AS ready, f.size_bytes,
                  e.provider, e.external_id
           FROM playlist_tracks pt
           JOIN tracks t ON t.id = pt.track_id
           LEFT JOIN users u ON u.id = pt.added_by
           LEFT JOIN files f ON f.track_id = t.id
           LEFT JOIN LATERAL (
               SELECT provider, external_id FROM external_ids x WHERE x.track_id = t.id
               ORDER BY CASE provider WHEN 'spotify' THEN 0 WHEN 'deezer' THEN 1 ELSE 2 END
               LIMIT 1) e ON true
           WHERE pt.playlist_id = $1
           ORDER BY pt.position, pt.added_at""",
        playlist_id)
    members = await pool.fetch(
        """SELECT u.id AS m_id, u.username AS m_username, u.name AS m_name, pm.role
           FROM playlist_members pm JOIN users u ON u.id = pm.user_id
           WHERE pm.playlist_id = $1 ORDER BY u.name""",
        playlist_id)
    return PlaylistDetail(
        **base.model_dump(),
        members=[Member(user=_person(m, "m"), role=m["role"]) for m in members],
        tracks=[PlaylistTrack(
            track_id=str(t["track_id"]), provider=t["provider"] or "bergastream",
            external_id=t["external_id"] or str(t["track_id"]), title=t["title"],
            artist=t["artist"], album=t["album"], duration_seconds=t["duration_seconds"] or 0,
            isrc=t["isrc"], cover_url=t["cover_url"], added_by=_person(t, "by"),
            added_at=t["added_at"].isoformat(), position=t["position"], ready=t["ready"],
            size_bytes=t["size_bytes"]) for t in tracks],
    )


async def reorder(pool: "asyncpg.Pool", playlist_id: str, track_ids: list[str]) -> None:
    """Grava a nova ordem. Faixas que não vieram na lista ficam no fim, na
    ordem em que estavam."""
    async with pool.acquire() as conn:
        async with conn.transaction():
            current = [str(r["track_id"]) for r in await conn.fetch(
                "SELECT track_id FROM playlist_tracks WHERE playlist_id = $1 ORDER BY position, added_at",
                playlist_id)]
            wanted = [t for t in track_ids if t in set(current)]
            order = wanted + [t for t in current if t not in set(wanted)]
            for pos, track_id in enumerate(order, start=1):
                await conn.execute(
                    "UPDATE playlist_tracks SET position = $3 WHERE playlist_id = $1 AND track_id = $2",
                    playlist_id, track_id, pos)
            await conn.execute("UPDATE playlists SET updated_at = now() WHERE id = $1", playlist_id)


async def delete(pool: "asyncpg.Pool", playlist_id: str) -> list[str]:
    """Apaga a playlist; devolve as faixas para revisar a permanência."""
    track_ids = [str(r["track_id"]) for r in await pool.fetch(
        "SELECT track_id FROM playlist_tracks WHERE playlist_id = $1", playlist_id)]
    await pool.execute("DELETE FROM playlists WHERE id = $1", playlist_id)
    return track_ids
