"""Controle das chamadas da rádio.

- Cada fonte tem um limite de chamadas ao mesmo tempo, um intervalo mínimo
  entre chamadas (o Last.fm pede no máximo ~5 por segundo) e um disjuntor:
  depois de N falhas seguidas ela fica de fora por alguns minutos e a rádio
  segue com as outras.
- O mesmo pedido em paralelo (mesma fonte, mesma música) vira uma chamada só.
- Toda chamada tem prazo: fonte lenta não segura a rádio.

A API roda em um processo só (uvicorn sem --workers), então isto fica em
memória. O cache dos resultados fica no Redis.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

from app.config import settings
from app.core.redis import get_redis

logger = logging.getLogger("bergastream.radio")


class SourceDown(Exception):
    """A fonte está no intervalo do disjuntor (ou sem configuração)."""


class Source:
    def __init__(self, name: str, concurrency: int = 4, min_interval: float = 0.0,
                 failures_to_open: int = 3, open_seconds: float = 300):
        self.name = name
        self._concurrency = concurrency
        self._loop: asyncio.AbstractEventLoop | None = None
        self._sem = asyncio.Semaphore(concurrency)
        self._min_interval = min_interval
        self._next_slot = 0.0
        self._slot_lock = asyncio.Lock()
        self._failures = 0
        self._failures_to_open = failures_to_open
        self._open_seconds = open_seconds
        self.open_until = 0.0

    @property
    def is_open(self) -> bool:
        return time.monotonic() < self.open_until

    async def _wait_slot(self) -> None:
        if not self._min_interval:
            return
        async with self._slot_lock:
            now = time.monotonic()
            wait = self._next_slot - now
            self._next_slot = max(now, self._next_slot) + self._min_interval
        if wait > 0:
            await asyncio.sleep(wait)

    async def call(self, fn: Callable[[], Any], timeout: float | None = None) -> Any:
        """Roda [fn] (síncrona) numa thread, com os limites desta fonte."""
        if self.is_open:
            raise SourceDown(self.name)
        loop = asyncio.get_running_loop()
        if self._loop is not loop:  # semáforo e trava são do loop em que nasceram
            self._loop = loop
            self._sem = asyncio.Semaphore(self._concurrency)
            self._slot_lock = asyncio.Lock()
        async with self._sem:
            await self._wait_slot()
            try:
                result = await asyncio.wait_for(
                    asyncio.to_thread(fn), timeout or settings.radio_source_timeout)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self._failures += 1
                if self._failures >= self._failures_to_open:
                    self.open_until = time.monotonic() + self._open_seconds
                    logger.warning("[rádio] %s fora por %ds depois de %d falhas (%s)",
                                   self.name, self._open_seconds, self._failures, exc)
                    self._failures = 0
                raise
            self._failures = 0
            return result

    def reset(self) -> None:
        self._failures = 0
        self.open_until = 0.0


SOURCES = {
    "ytmusic": Source("ytmusic", concurrency=3),
    "lastfm": Source("lastfm", concurrency=3, min_interval=0.22),
    "deezer": Source("deezer", concurrency=4, min_interval=0.1),
    "listenbrainz": Source("listenbrainz", concurrency=2, min_interval=0.3),
}

_inflight: dict[str, asyncio.Future] = {}


async def cached(cache_key: str, ttl: int, produce: Callable[[], Awaitable[Any]]) -> Any:
    """Resultado do Redis; senão produz uma vez só, mesmo com pedidos em paralelo.

    Falhas não vão para o cache (a próxima rádio tenta de novo)."""
    redis = await get_redis()
    raw = await redis.get(cache_key)
    if raw is not None:
        return json.loads(raw)
    if cache_key in _inflight:
        return await asyncio.shield(_inflight[cache_key])
    future: asyncio.Future = asyncio.get_running_loop().create_future()
    _inflight[cache_key] = future
    try:
        value = await produce()
        await redis.set(cache_key, json.dumps(value), ex=ttl)
        future.set_result(value)
        return value
    except BaseException as exc:
        future.set_exception(exc)
        future.exception()  # já tratada: sem aviso de "exception never retrieved"
        raise
    finally:
        _inflight.pop(cache_key, None)


# ── Por usuário ──────────────────────────────────────────────────

_running: dict[str, asyncio.Task] = {}


class TooMany(Exception):
    pass


async def check_rate(user_id: str) -> None:
    """Limite de rádios por minuto para cada pessoa."""
    redis = await get_redis()
    bucket = f"radio:rate:{user_id}:{int(time.time() // 60)}"
    count = await redis.incr(bucket)
    if count == 1:
        await redis.expire(bucket, 120)
    if count > settings.radio_per_minute:
        raise TooMany()


async def run_latest(user_id: str, work: Awaitable[Any]) -> Any:
    """Roda [work] como o pedido de rádio atual desta pessoa: um pedido novo
    cancela o anterior (que ainda não terminou), e o anterior deixa de gastar
    chamadas."""
    old = _running.get(user_id)
    if old is not None and not old.done():
        old.cancel()
    task = asyncio.ensure_future(work)
    _running[user_id] = task
    try:
        return await task
    finally:
        if _running.get(user_id) is task:
            _running.pop(user_id, None)
