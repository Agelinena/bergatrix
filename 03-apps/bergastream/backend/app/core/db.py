"""Pool de conexões PostgreSQL via asyncpg."""

from __future__ import annotations

import asyncpg
from app.config import settings


pool: asyncpg.Pool | None = None


async def create_pool() -> asyncpg.Pool:
    """Cria o pool de conexões (chamado no startup da API)."""
    global pool
    pool = await asyncpg.create_pool(
        settings.database_url,
        min_size=2,
        max_size=10,
    )
    return pool


async def close_pool() -> None:
    """Fecha o pool (chamado no shutdown da API)."""
    global pool
    if pool:
        await pool.close()
        pool = None


def get_pool() -> asyncpg.Pool:
    """Retorna o pool já criado (lança erro se não iniciado)."""
    if pool is None:
        raise RuntimeError("Pool de conexão não inicializado")
    return pool