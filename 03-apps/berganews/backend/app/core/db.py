"""Pool do Postgres (asyncpg), usado pela API e pelos workers."""
from __future__ import annotations

import asyncpg

from app.config import settings

pool: asyncpg.Pool | None = None


async def create_pool(min_size: int = 2, max_size: int = 10) -> asyncpg.Pool:
    global pool
    pool = await asyncpg.create_pool(settings.database_url, min_size=min_size, max_size=max_size)
    return pool


async def close_pool() -> None:
    global pool
    if pool:
        await pool.close()
        pool = None


def get_pool() -> asyncpg.Pool:
    if pool is None:
        raise RuntimeError("Pool de conexão não inicializado")
    return pool
