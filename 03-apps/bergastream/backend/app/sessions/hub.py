"""Conexões em tempo real (WebSocket) de cada sessão, no processo da API
(uvicorn roda com um worker só). Guarda também a última reprodução de cada
sessão aberta, para a rede de segurança do fim da faixa."""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field

from fastapi import WebSocket

from app.sessions.playback import Playback

logger = logging.getLogger("bergastream.sessions.hub")


@dataclass(eq=False)
class Connection:
    ws: WebSocket
    user_id: str


@dataclass
class Room:
    connections: set[Connection] = field(default_factory=set)
    playback: Playback | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


_rooms: dict[str, Room] = {}


def room(session_id: str) -> Room:
    return _rooms.setdefault(session_id, Room())


def online_users(session_id: str) -> set[str]:
    r = _rooms.get(session_id)
    return {c.user_id for c in r.connections} if r else set()


def open_rooms() -> list[tuple[str, Room]]:
    return [(sid, r) for sid, r in _rooms.items() if r.connections]


def add(session_id: str, conn: Connection) -> None:
    room(session_id).connections.add(conn)


def remove(session_id: str, conn: Connection) -> None:
    r = _rooms.get(session_id)
    if r:
        r.connections.discard(conn)


async def broadcast(session_id: str, message: dict, only_user: str | None = None) -> None:
    r = _rooms.get(session_id)
    if not r:
        return
    text = json.dumps(message)
    for conn in list(r.connections):
        if only_user and conn.user_id != only_user:
            continue
        try:
            await conn.ws.send_text(text)
        except Exception:  # conexão caiu: sai da sala
            r.connections.discard(conn)


async def close_user(session_id: str, user_id: str, message: dict) -> None:
    """Avisa e fecha as conexões de uma pessoa (removida ou sessão encerrada)."""
    r = _rooms.get(session_id)
    if not r:
        return
    for conn in [c for c in r.connections if c.user_id == user_id]:
        try:
            await conn.ws.send_text(json.dumps(message))
            await conn.ws.close(code=4000)
        except Exception:
            pass
        r.connections.discard(conn)


def forget(session_id: str) -> None:
    _rooms.pop(session_id, None)
