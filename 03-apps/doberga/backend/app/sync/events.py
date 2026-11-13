"""Avisos em tempo real: "algo mudou, faça pull".

Cada pessoa tem um canal no Redis (doberga:user:<id>). Quem grava publica no
canal de cada membro dos espaços afetados; o SSE de cada aparelho assina só o
canal da própria pessoa. O aviso não leva dados: o aparelho busca pelo pull,
que confere o acesso de novo.
"""
from __future__ import annotations

import json
import logging
from collections.abc import Iterable

logger = logging.getLogger("doberga.sync.events")

CHANNEL = "doberga:user:"


def channel(user_id) -> str:
    return f"{CHANNEL}{user_id}"


async def _publish(redis, user_ids: Iterable, message: dict) -> None:
    payload = json.dumps(message)
    for user_id in set(str(u) for u in user_ids):
        try:
            await redis.publish(channel(user_id), payload)
        except Exception as exc:  # sem Redis, o aparelho sincroniza no próximo ciclo
            logger.warning("[events] falha ao publicar para %s: %s", user_id, exc)


async def members_of(conn, space_ids: Iterable) -> list:
    ids = list(set(space_ids))
    if not ids:
        return []
    rows = await conn.fetch(
        "SELECT DISTINCT user_id FROM space_members WHERE space_id = ANY($1::uuid[])", ids)
    return [r["user_id"] for r in rows]


async def data_changed(redis, conn, space_ids: Iterable, origin: str | None = None) -> None:
    """Linhas mudaram nestes espaços. `origin` é o aparelho que mandou (ele
    ignora o próprio aviso)."""
    ids = [str(s) for s in set(space_ids)]
    if ids:
        await _publish(redis, await members_of(conn, ids),
                       {"type": "changed", "spaces": ids, "origin": origin})


async def spaces_changed(redis, user_ids: Iterable) -> None:
    """Lista de espaços, membros ou nomes mudou para estas pessoas."""
    await _publish(redis, user_ids, {"type": "spaces"})
