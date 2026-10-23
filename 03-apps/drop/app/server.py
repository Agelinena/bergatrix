"""Drop: relay cego entre dois navegadores.

O servidor nunca vê o código, a chave nem o conteúdo. Cada sala é
identificada por um ID derivado do código no navegador (HKDF) e tem dois
lugares: o receptor, que cria a sala, e o emissor. Tudo o que chega como
frame binário de um lado é repassado, igual, para o outro. Frames de texto
são só controle (entrar na sala e ping).

Nada vai para o disco: as salas ficam em memória e expiram em 10 minutos.
O backpressure do uvicorn (websockets-sansio) limita a memória por conexão a
um frame e aos buffers do socket, mesmo com arquivos grandes.

O container fica numa rede interna que só o Traefik alcança, então o
X-Real-Ip que chega aqui é o que o Traefik gravou.
"""
from __future__ import annotations

import asyncio
import json
import logging
import mimetypes
import re
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from starlette.applications import Starlette
from starlette.responses import FileResponse, JSONResponse, PlainTextResponse
from starlette.routing import Mount, Route, WebSocketRoute
from starlette.staticfiles import StaticFiles
from starlette.websockets import WebSocket, WebSocketDisconnect

logger = logging.getLogger("drop")

PROTOCOL_VERSION = 2
ROOM_TTL_SECONDS = 600
JOIN_TIMEOUT_SECONDS = 10
MAX_ROOMS = 256
MAX_ROOMS_PER_CLIENT = 4
# Um pedaço de arquivo cifrado (64 KiB + cabeçalhos) cabe com folga.
MAX_FRAME_BYTES = 66 * 1024
# Por sala, somando os dois sentidos: um envio de 25 MiB e respostas.
MAX_ROOM_BYTES = 40 * 1024 * 1024
MAX_ROOM_FRAMES = 4000
MAX_CONTROL_BYTES = 256
ROOM_ID = re.compile(r"[a-f0-9]{64}")
ROLES = ("receiver", "sender")

# Códigos de fechamento (4000-4999 são da aplicação).
CLOSE_BAD_REQUEST = 4000
CLOSE_FORBIDDEN = 4003
CLOSE_NOT_FOUND = 4004
CLOSE_EXPIRED = 4008
CLOSE_BUSY = 4009
CLOSE_FULL = 4013
CLOSE_LIMIT = 4029


@dataclass
class Peer:
    websocket: WebSocket
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send_bytes(self, data: bytes) -> None:
        async with self.lock:
            await self.websocket.send_bytes(data)

    async def send_json(self, data: dict) -> None:
        async with self.lock:
            await self.websocket.send_text(json.dumps(data, separators=(",", ":")))

    async def close(self, code: int, reason: str = "") -> None:
        try:
            async with self.lock:
                await self.websocket.close(code=code, reason=reason)
        except Exception:
            pass


@dataclass
class Room:
    created_at: float
    client: str
    peers: dict[str, Peer | None] = field(default_factory=lambda: dict.fromkeys(ROLES))
    bytes_relayed: int = 0
    frames: int = 0

    def expires_in(self, now: float | None = None) -> float:
        return self.created_at + ROOM_TTL_SECONDS - (time.monotonic() if now is None else now)


class Rooms:
    def __init__(self):
        self.rooms: dict[str, Room] = {}

    def cleanup(self) -> None:
        now = time.monotonic()
        for room_id in [rid for rid, room in self.rooms.items() if room.expires_in(now) <= 0]:
            room = self.rooms.pop(room_id)
            for peer in room.peers.values():
                if peer is not None:
                    asyncio.create_task(peer.close(CLOSE_EXPIRED, "expired"))

    def join(self, room_id: str, role: str, client: str, peer: Peer) -> tuple[Room | None, int]:
        """Lugar na sala, ou o código de fechamento que explica a recusa."""
        self.cleanup()
        room = self.rooms.get(room_id)
        if room is None:
            if role != "receiver":
                return None, CLOSE_NOT_FOUND
            if len(self.rooms) >= MAX_ROOMS:
                return None, CLOSE_FULL
            if sum(r.client == client for r in self.rooms.values()) >= MAX_ROOMS_PER_CLIENT:
                return None, CLOSE_LIMIT
            room = self.rooms[room_id] = Room(created_at=time.monotonic(), client=client)
        elif room.peers[role] is not None:
            return None, CLOSE_BUSY
        room.peers[role] = peer
        return room, 0

    def leave(self, room_id: str, role: str, peer: Peer) -> Room | None:
        room = self.rooms.get(room_id)
        if room is not None and room.peers[role] is peer:
            room.peers[role] = None
            return room
        return None


rooms = Rooms()


def other(role: str) -> str:
    return "sender" if role == "receiver" else "receiver"


def client_address(websocket: WebSocket) -> str:
    return websocket.headers.get("x-real-ip") or (websocket.client.host if websocket.client else "")


def same_origin(websocket: WebSocket) -> bool:
    """Só a página do próprio Drop abre o WebSocket: impede outros sites de
    usarem o relay."""
    origin = websocket.headers.get("origin", "")
    host = websocket.headers.get("host", "")
    return bool(origin and host) and urlsplit(origin).netloc == host


async def read_join(websocket: WebSocket) -> tuple[str, str] | None:
    try:
        message = await asyncio.wait_for(websocket.receive(), JOIN_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        return None
    text = message.get("text")
    if message.get("type") != "websocket.receive" or not text or len(text) > MAX_CONTROL_BYTES:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("type") != "join" or data.get("v") != PROTOCOL_VERSION:
        return None
    room_id, role = data.get("room"), data.get("role")
    if not isinstance(room_id, str) or not ROOM_ID.fullmatch(room_id) or role not in ROLES:
        return None
    return room_id, role


async def relay(room: Room, role: str, peer: Peer, data: bytes) -> bool:
    """Repassa um frame ao outro lado. False encerra a conexão de origem."""
    if not data or len(data) > MAX_FRAME_BYTES:
        await peer.close(CLOSE_LIMIT, "frame")
        return False
    room.bytes_relayed += len(data)
    room.frames += 1
    if room.bytes_relayed > MAX_ROOM_BYTES or room.frames > MAX_ROOM_FRAMES:
        await peer.close(CLOSE_LIMIT, "room")
        return False
    target = room.peers[other(role)]
    if target is None:
        await peer.send_json({"type": "error", "code": "peer-missing"})
        return True
    try:
        await target.send_bytes(data)
    except Exception:
        await peer.send_json({"type": "error", "code": "peer-missing"})
    return True


async def websocket_endpoint(websocket: WebSocket) -> None:
    if not same_origin(websocket):
        await websocket.close(code=CLOSE_FORBIDDEN)
        return
    await websocket.accept()
    peer = Peer(websocket)
    joined = await read_join(websocket)
    if joined is None:
        await peer.close(CLOSE_BAD_REQUEST, "join")
        return
    room_id, role = joined
    room, refusal = rooms.join(room_id, role, client_address(websocket), peer)
    if room is None:
        await peer.close(refusal)
        return

    partner = room.peers[other(role)]
    try:
        await peer.send_json({"type": "ready", "role": role, "peer": partner is not None,
                              "expiresIn": int(room.expires_in())})
        if partner is not None:
            await partner.send_json({"type": "peer", "present": True})
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break
            if room.expires_in() <= 0 or rooms.rooms.get(room_id) is not room:
                await peer.close(CLOSE_EXPIRED, "expired")
                break
            if message.get("bytes") is not None:
                if not await relay(room, role, peer, message["bytes"]):
                    break
            elif message.get("text") != "ping":
                await peer.close(CLOSE_BAD_REQUEST, "control")
                break
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        left = rooms.leave(room_id, role, peer)
        partner = left.peers[other(role)] if left is not None else None
        if partner is not None:
            try:
                await partner.send_json({"type": "peer", "present": False})
            except Exception:
                pass


# ── HTTP ─────────────────────────────────────────────────────────────

STATIC = Path(__file__).resolve().parent / "static"
# A imagem slim não tem /etc/mime.types: sem isto, o nosniff bloqueia os módulos.
mimetypes.add_type("text/javascript", ".mjs")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("font/woff2", ".woff2")

CONTENT_SECURITY_POLICY = "; ".join((
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "font-src 'self'",
    "img-src 'self' blob:",
    "media-src 'self' blob:",
    "connect-src 'self'",
    "manifest-src 'self'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
))

SECURITY_HEADERS = [
    (b"content-security-policy", CONTENT_SECURITY_POLICY.encode()),
    (b"cross-origin-opener-policy", b"same-origin"),
    (b"cross-origin-embedder-policy", b"require-corp"),
    (b"cross-origin-resource-policy", b"same-origin"),
    (b"permissions-policy",
     b"camera=(self), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()"),
    (b"referrer-policy", b"no-referrer"),
    (b"strict-transport-security", b"max-age=31536000"),
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
]


class SecurityHeaders:
    """Cabeçalhos em toda resposta HTTP. A página nunca vai para cache; os
    arquivos estáticos são revalidados a cada visita."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        cache = b"no-store" if scope["path"] == "/" else b"no-cache"

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = [(k, v) for k, v in message.get("headers", [])
                           if k.lower() != b"cache-control"]
                message["headers"] = headers + SECURITY_HEADERS + [(b"cache-control", cache)]
            await send(message)

        await self.app(scope, receive, send_with_headers)


async def index(request):
    return FileResponse(STATIC / "index.html", media_type="text/html; charset=utf-8")


async def icon(request):
    return FileResponse(STATIC / "assets" / "icon.svg", media_type="image/svg+xml")


async def robots(request):
    return PlainTextResponse("User-agent: *\nDisallow: /\n")


async def healthz(request):
    return JSONResponse({"status": "ok"})


async def expire_rooms():
    while True:
        await asyncio.sleep(15)
        rooms.cleanup()


@asynccontextmanager
async def lifespan(app):
    task = asyncio.create_task(expire_rooms())
    try:
        yield
    finally:
        task.cancel()


app = SecurityHeaders(Starlette(
    routes=[
        Route("/", index),
        # Sem 404 para o que todo navegador e robô pede: o CrowdSec bane IPs
        # que acumulam 404 (http-probing).
        Route("/favicon.ico", icon),
        Route("/robots.txt", robots),
        Route("/healthz", healthz),
        WebSocketRoute("/ws", websocket_endpoint),
        Mount("/assets", StaticFiles(directory=STATIC / "assets")),
    ],
    lifespan=lifespan,
))
