"""Pool de conexões PostgreSQL (asyncpg), usado pela API e pelo worker."""

from __future__ import annotations

import json

import asyncpg

from app.config import settings

pool: asyncpg.Pool | None = None


async def _init(connection: asyncpg.Connection) -> None:
    await connection.set_type_codec("jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


async def create_pool(min_size: int = 1, max_size: int = 10) -> asyncpg.Pool:
    global pool
    pool = await asyncpg.create_pool(settings.database_url, min_size=min_size, max_size=max_size, init=_init)
    return pool


async def close_pool() -> None:
    global pool
    if pool is not None:
        await pool.close()
        pool = None


def get_pool() -> asyncpg.Pool:
    if pool is None:
        raise RuntimeError("Pool de conexão não inicializado")
    return pool
