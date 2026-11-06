"""Pool de conexões PostgreSQL (asyncpg)."""

from __future__ import annotations

import json

import asyncpg

from bergakup.config import settings


async def _init(connection: asyncpg.Connection) -> None:
    await connection.set_type_codec("jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


async def create_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(settings.database_url, min_size=1, max_size=10, init=_init)
