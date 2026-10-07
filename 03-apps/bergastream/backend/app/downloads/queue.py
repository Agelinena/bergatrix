"""Fila de downloads baseada em Redis com 3 prioridades.

A API enfileira jobs; o Worker consome.
Estado partilhado entre API e Worker via Redis Hashes.
"""
from __future__ import annotations
import json
import logging
import uuid
from typing import Any

logger = logging.getLogger("bergastream.downloads.queue")

PRIORITY_QUEUES = {
    1: "bergastream:q:high",    # clique direto
    2: "bergastream:q:medium",  # radio (reservado)
    3: "bergastream:q:low",     # playlists/background
}
_JOB_PREFIX = "bergastream:job:"
_ACTIVE_SET = "bergastream:dl:active"


async def enqueue(redis, track_id: str, provider: str, priority: int = 3,
                  **metadata) -> str:
    """Cria um job e insere na fila de prioridade."""
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id,
        "track_id": track_id,
        "provider": provider,
        "priority": str(priority),
        "status": "queued",
    }
    job.update(metadata)
    await redis.hset(f"{_JOB_PREFIX}{job_id}", mapping=job)
    await redis.lpush(PRIORITY_QUEUES[priority], job_id)
    logger.info("[queue] enfileirado %s (prio=%d)", track_id[:8], priority)
    return job_id


async def dequeue(redis, timeout: int = 1) -> str | None:
    """Pula da fila de maior prioridade (BRPOP). Retorna job_id ou None."""
    queues = [PRIORITY_QUEUES[1], PRIORITY_QUEUES[2], PRIORITY_QUEUES[3]]
    result = await redis.brpop(queues, timeout=timeout)
    if result:
        _queue, job_id = result
        return job_id
    return None


async def get_job(redis, job_id: str) -> dict[str, Any] | None:
    data = await redis.hgetall(f"{_JOB_PREFIX}{job_id}")
    return data if data else None


async def set_job_status(redis, job_id: str, status: str, **extra) -> None:
    key = f"{_JOB_PREFIX}{job_id}"
    await redis.hset(key, "status", status)
    for k, v in extra.items():
        await redis.hset(key, k, v)


async def active_count(redis) -> int:
    return await redis.scard(_ACTIVE_SET)


async def mark_active(redis, track_id: str) -> bool:
    """Marca track como ativa. Retorna False se já estava ativa."""
    return await redis.sadd(_ACTIVE_SET, track_id) == 1


async def mark_done(redis, track_id: str) -> None:
    await redis.srem(_ACTIVE_SET, track_id)