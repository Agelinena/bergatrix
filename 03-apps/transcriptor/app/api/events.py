"""Eventos em tempo real: o Postgres avisa (LISTEN transcriptor_jobs, disparado
pelo trigger da tabela jobs) e a API repassa por SSE para as abas abertas
de cada pessoa."""

from __future__ import annotations

import asyncio
import json
import logging
from collections import defaultdict

import asyncpg

from app.config import settings

logger = logging.getLogger("transcriptor.events")

QUEUE_SIZE = 200


class Hub:
    def __init__(self):
        self.subscribers: dict[str, set[asyncio.Queue]] = defaultdict(set)
        self.task: asyncio.Task | None = None

    def start(self) -> None:
        self.task = asyncio.create_task(self.run())

    async def stop(self) -> None:
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass

    async def run(self) -> None:
        while True:
            connection = None
            try:
                connection = await asyncpg.connect(settings.database_url)
                await connection.add_listener("transcriptor_jobs", self._notify)
                while True:
                    await asyncio.sleep(15)
                    await connection.execute("SELECT 1")
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning("[events] conexão de avisos caiu (%s); reconectando", error)
                # Quem estava ouvindo pode ter perdido avisos: recarrega a lista.
                self.broadcast({"type": "resync"})
                await asyncio.sleep(3)
            finally:
                if connection is not None and not connection.is_closed():
                    await connection.close()

    def _notify(self, connection, pid, channel, payload: str) -> None:
        try:
            data = json.loads(payload)
        except ValueError:
            return
        data["type"] = "job"
        for queue in list(self.subscribers.get(str(data.get("user")), ())):
            self._put(queue, data)

    def broadcast(self, data: dict) -> None:
        for queues in self.subscribers.values():
            for queue in list(queues):
                self._put(queue, data)

    @staticmethod
    def _put(queue: asyncio.Queue, data: dict) -> None:
        try:
            queue.put_nowait(data)
        except asyncio.QueueFull:
            # Aba lenta: em vez de acumular, pede para ela recarregar tudo.
            while not queue.empty():
                queue.get_nowait()
            queue.put_nowait({"type": "resync"})

    def subscribe(self, user_id: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(QUEUE_SIZE)
        self.subscribers[user_id].add(queue)
        return queue

    def unsubscribe(self, user_id: str, queue: asyncio.Queue) -> None:
        self.subscribers[user_id].discard(queue)
        if not self.subscribers[user_id]:
            del self.subscribers[user_id]


hub = Hub()
