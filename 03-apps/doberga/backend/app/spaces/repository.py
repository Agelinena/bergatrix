"""SQL de espaços, membros e convites."""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

PERSONAL_NAME = "Pessoal"


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def ensure_personal(pool, user_id) -> None:
    """Cria o espaço pessoal (uma vez por pessoa)."""
    async with pool.acquire() as conn:
        async with conn.transaction():
            space_id = await conn.fetchval(
                """INSERT INTO spaces (kind, name, personal_user_id, created_by)
                   VALUES ('personal', $2, $1, $1)
                   ON CONFLICT (personal_user_id) DO NOTHING RETURNING id""",
                user_id, PERSONAL_NAME)
            if space_id is not None:
                await conn.execute(
                    "INSERT INTO space_members (space_id, user_id, role) VALUES ($1, $2, 'owner')",
                    space_id, user_id)


async def list_for_user(conn, user_id) -> list[dict]:
    """Espaços da pessoa, com o papel dela e os membros."""
    rows = await conn.fetch(
        """SELECT s.id, s.kind, s.name, s.color, s.icon, s.created_at, m.role
           FROM spaces s JOIN space_members m ON m.space_id = s.id AND m.user_id = $1
           ORDER BY (s.kind = 'personal') DESC, lower(s.name)""", user_id)
    if not rows:
        return []
    members = await conn.fetch(
        """SELECT m.space_id, m.user_id, m.role, m.joined_at, u.name, u.username
           FROM space_members m JOIN users u ON u.id = m.user_id
           WHERE m.space_id = ANY($1::uuid[])
           ORDER BY (m.role = 'owner') DESC, lower(u.name)""", [r["id"] for r in rows])
    by_space: dict = {}
    for m in members:
        by_space.setdefault(m["space_id"], []).append({
            "user_id": str(m["user_id"]), "name": m["name"], "username": m["username"],
            "role": m["role"], "joined_at": m["joined_at"].isoformat()})
    return [{"id": str(r["id"]), "kind": r["kind"], "name": r["name"], "color": r["color"],
             "icon": r["icon"], "role": r["role"], "created_at": r["created_at"].isoformat(),
             "members": by_space.get(r["id"], [])} for r in rows]


async def membership(conn, space_id, user_id):
    """(kind, role) da pessoa no espaço, ou None se não é membro."""
    return await conn.fetchrow(
        """SELECT s.kind, m.role FROM spaces s
           JOIN space_members m ON m.space_id = s.id AND m.user_id = $2
           WHERE s.id = $1""", space_id, user_id)


async def member_ids(conn, space_id) -> list:
    return [r["user_id"] for r in await conn.fetch(
        "SELECT user_id FROM space_members WHERE space_id = $1", space_id)]


async def create_group(conn, user_id, name: str, color: str | None, icon: str | None):
    async with conn.transaction():
        space_id = await conn.fetchval(
            """INSERT INTO spaces (kind, name, color, icon, created_by)
               VALUES ('group', $1, $2, $3, $4) RETURNING id""", name, color, icon, user_id)
        await conn.execute(
            "INSERT INTO space_members (space_id, user_id, role) VALUES ($1, $2, 'owner')",
            space_id, user_id)
    return space_id


async def create_invite(conn, space_id, user_id, days: int, uses: int) -> tuple[str, datetime]:
    token = secrets.token_urlsafe(24)
    expires = datetime.now(timezone.utc) + timedelta(days=days)
    await conn.execute(
        """INSERT INTO space_invites (space_id, token_hash, created_by, expires_at, uses_left)
           VALUES ($1, $2, $3, $4, $5)""", space_id, hash_token(token), user_id, expires, uses)
    return token, expires


async def find_invite(conn, token: str, for_update: bool = False):
    """Convite válido (não revogado, no prazo, com uso), com o espaço."""
    lock = " FOR UPDATE OF i" if for_update else ""
    return await conn.fetchrow(
        f"""SELECT i.id, i.space_id, i.uses_left, i.expires_at, s.name AS space_name,
                   s.color, s.icon, u.name AS inviter,
                   (SELECT count(*) FROM space_members m WHERE m.space_id = s.id) AS members
            FROM space_invites i
            JOIN spaces s ON s.id = i.space_id
            LEFT JOIN users u ON u.id = i.created_by
            WHERE i.token_hash = $1 AND i.revoked_at IS NULL AND i.expires_at > now()
              AND i.uses_left > 0{lock}""", hash_token(token))
