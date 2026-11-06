"""Fila de tradução (API → worker de IA), no Redis.

Uma tradução por artigo e idioma fica no banco e serve todo mundo. Enquanto
o worker trabalha, o progresso (blocos prontos / total) fica no Redis, e o
app mostra a barra.
"""
from __future__ import annotations

import json

QUEUE_KEY = "berganews:translate:queue"
_STATUS = "berganews:translate:status:{article}:{lang}"
STATUS_TTL = 3600


def status_key(article_id: int, lang: str) -> str:
    return _STATUS.format(article=article_id, lang=lang)


async def enqueue(redis, article_id: int, lang: str) -> dict:
    """Põe na fila se ainda não estiver; devolve o estado atual."""
    key = status_key(article_id, lang)
    queued = await redis.set(key, json.dumps({"state": "queued", "done": 0, "total": 0}),
                             ex=STATUS_TTL, nx=True)
    if queued:
        await redis.rpush(QUEUE_KEY, f"{article_id}:{lang}")
    return await get_status(redis, article_id, lang) or {"state": "queued", "done": 0, "total": 0}


async def get_status(redis, article_id: int, lang: str) -> dict | None:
    raw = await redis.get(status_key(article_id, lang))
    return json.loads(raw) if raw else None


async def set_status(redis, article_id: int, lang: str, state: str, done: int = 0,
                     total: int = 0, error: str | None = None) -> None:
    value = {"state": state, "done": done, "total": total}
    if error:
        value["error"] = error
    await redis.set(status_key(article_id, lang), json.dumps(value), ex=STATUS_TTL)


async def clear_status(redis, article_id: int, lang: str) -> None:
    await redis.delete(status_key(article_id, lang))
