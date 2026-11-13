"""Rotas do sync: /api/sync/push, /pull e /events."""
from __future__ import annotations

import asyncio
import json
import logging
from time import monotonic

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core.db import get_pool
from app.core.redis import get_redis
from app.sync import engine, events

logger = logging.getLogger("doberga.sync")
router = APIRouter(prefix="/api/sync", tags=["sync"])


async def protocol(x_doberga_sync: int | None = Header(None)) -> int:
    """O app diz qual versão do protocolo fala. Abaixo da mínima: 426, e o
    app pede a atualização."""
    if x_doberga_sync is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Falta o cabeçalho X-Doberga-Sync")
    if x_doberga_sync < settings.sync_min_protocol:
        raise HTTPException(status.HTTP_426_UPGRADE_REQUIRED,
                            detail="Atualize o Doberga para continuar sincronizando")
    return x_doberga_sync


class PushIn(BaseModel):
    device_id: str = Field("", max_length=64)
    ops: list[engine.Op] = Field(max_length=500)


class PullIn(BaseModel):
    cursors: dict[str, int] = Field(default_factory=dict)
    limit: int | None = Field(None, ge=1, le=2000)


@router.post("/push")
async def push(body: PushIn, user: CurrentUser = Depends(current_user), _: int = Depends(protocol)):
    if len(body.ops) > settings.sync_push_max_ops:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                            detail=f"Mande até {settings.sync_push_max_ops} operações por vez")
    async with get_pool().acquire() as conn:
        results, changed = await engine.push(conn, user.id, body.ops)
        if changed:
            await events.data_changed(await get_redis(), conn, changed, body.device_id or None)
    return {"results": results}


@router.post("/pull")
async def pull(body: PullIn, user: CurrentUser = Depends(current_user), _: int = Depends(protocol)):
    limit = min(body.limit or settings.sync_pull_limit, settings.sync_pull_limit)
    async with get_pool().acquire() as conn:
        result = await engine.pull(conn, user.id, body.cursors, limit)
    result["protocol"] = settings.sync_protocol
    return result


@router.get("/events")
async def stream(request: Request, user: CurrentUser = Depends(current_user)):
    """SSE: avisa que algo mudou. A conexão dura no máximo o tempo do access
    token; o app reconecta com o token novo."""
    redis = await get_redis()
    pubsub = redis.pubsub()
    await pubsub.subscribe(events.channel(user.id))
    lifetime = settings.access_token_minutes * 60

    async def gen():
        started = monotonic()
        try:
            yield "retry: 5000\nevent: hello\ndata: {}\n\n"
            while monotonic() - started < lifetime:
                if await request.is_disconnected():
                    break
                message = await pubsub.get_message(ignore_subscribe_messages=True, timeout=20)
                if message and message.get("type") == "message":
                    data = message["data"]
                    try:
                        kind = json.loads(data).get("type", "changed")
                    except ValueError:
                        continue
                    yield f"event: {kind}\ndata: {data}\n\n"
                elif message is None:
                    yield ": ping\n\n"
        except asyncio.CancelledError:
            pass
        finally:
            try:
                await pubsub.unsubscribe()
                await pubsub.aclose()
            except Exception:
                pass

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})
