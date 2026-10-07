"""SQL de usuários e refresh tokens."""
from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

_USER_COLUMNS = "id, username, name, password_hash, is_admin"


async def get_user_by_username(pool: "asyncpg.Pool", username: str):
    return await pool.fetchrow(
        f"SELECT {_USER_COLUMNS} FROM users WHERE lower(username) = lower($1)",
        username,
    )


async def get_user_by_id(pool: "asyncpg.Pool", user_id: str):
    return await pool.fetchrow(
        f"SELECT {_USER_COLUMNS} FROM users WHERE id = $1", user_id
    )


async def create_user(
    pool: "asyncpg.Pool",
    username: str,
    password_hash: str,
    is_admin: bool = False,
    name: str | None = None,
):
    return await pool.fetchrow(
        f"""INSERT INTO users (username, name, password_hash, is_admin)
            VALUES ($1, $2, $3, $4)
            RETURNING {_USER_COLUMNS}""",
        username,
        name or username,
        password_hash,
        is_admin,
    )


async def set_password(pool: "asyncpg.Pool", user_id: UUID, password_hash: str):
    await pool.execute(
        "UPDATE users SET password_hash = $2 WHERE id = $1", user_id, password_hash
    )


async def insert_refresh_token(
    pool: "asyncpg.Pool",
    user_id: UUID,
    family_id: UUID,
    token_hash: str,
    expires_at: datetime,
    user_agent: str | None,
):
    await pool.execute(
        """INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at, user_agent)
           VALUES ($1, $2, $3, $4, $5)""",
        user_id,
        family_id,
        token_hash,
        expires_at,
        user_agent,
    )


async def get_refresh_token(conn, token_hash: str, for_update: bool = False):
    lock = " FOR UPDATE" if for_update else ""
    return await conn.fetchrow(
        f"""SELECT id, user_id, family_id, expires_at, revoked_at
            FROM refresh_tokens WHERE token_hash = $1{lock}""",
        token_hash,
    )


async def revoke_refresh_token(conn, token_id: UUID):
    await conn.execute(
        "UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL",
        token_id,
    )


async def revoke_family(conn, family_id: UUID):
    await conn.execute(
        "UPDATE refresh_tokens SET revoked_at = now() WHERE family_id = $1 AND revoked_at IS NULL",
        family_id,
    )


async def revoke_all_for_user(pool: "asyncpg.Pool", user_id: UUID):
    await pool.execute(
        "UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL",
        user_id,
    )


async def delete_expired_refresh_tokens(pool: "asyncpg.Pool") -> int:
    result = await pool.execute(
        "DELETE FROM refresh_tokens WHERE expires_at < now() - interval '7 days'"
    )
    return int(result.split()[-1])
