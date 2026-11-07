"""Conexão Redis via redis.asyncio (pool singleton)."""
from __future__ import annotations

import redis.asyncio as aioredis

from app.config import settings

# Os workers esperam na fila com BLPOP por até 60 s. O redis-py 8 passou o
# socket_timeout padrão para 5 s, e a espera virava TimeoutError (o worker
# caía e reiniciava). O limite de leitura precisa ser maior que a maior espera.
SOCKET_TIMEOUT = 90

_pool: aioredis.Redis | None = None


async def get_redis() -> aioredis.Redis:
    global _pool
    if _pool is None:
        _pool = aioredis.from_url(
            settings.redis_url,
            decode_responses=True,
            socket_timeout=SOCKET_TIMEOUT,
            socket_connect_timeout=5,
            health_check_interval=30,
        )
    return _pool


async def close_redis() -> None:
    global _pool
    if _pool:
        await _pool.aclose()
        _pool = None
