"""
Multi-device sync — Spotify-Connect-style remote control.

Each authenticated user has a session-wide state plus a registry of
connected devices.  Any device can publish state changes (play / pause /
seek / track change / queue change) over its WebSocket; the server
fans those out to every OTHER device of the same user.

A device is "active" if it currently owns playback.  Other devices show
"Tocando em <name>" and can either:
  - transfer playback to themselves (becomes active, takes the state)
  - send remote commands (play / pause / next / seek) that the active
    device acts on

Wire protocol
-------------
Client → server JSON envelopes:
  {"type": "hello", "device": {...}}
  {"type": "state", "state": {...}}    // active device announces new state
  {"type": "command", "command": "...", "args": {...}}  // remote control
  {"type": "transfer", "to_device_id": "..."}

Server → client:
  {"type": "snapshot", "state": {...}, "devices": [...], "active_device_id": "..."}
  {"type": "state",    "state": {...}, "from_device_id": "..."}
  {"type": "command",  "command": "...", "args": {...}, "from_device_id": "..."}
  {"type": "devices",  "devices": [...], "active_device_id": "..."}
  {"type": "transferred", "to_device_id": "..."}
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from app.services import auth_service
from app.database import AsyncSessionLocal

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/sync", tags=["sync"])


@dataclass
class _Device:
    id: str
    name: str
    platform: str  # "web" | "android" | "windows" | "linux" | "macos"
    last_seen: float
    socket: WebSocket


@dataclass
class _Session:
    """One user's collection of devices + their shared player state."""
    user_id: str
    devices: dict[str, _Device] = field(default_factory=dict)
    active_device_id: str | None = None
    state: dict[str, Any] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


# user_id (str) → _Session
_sessions: dict[str, _Session] = {}


def _device_public(d: _Device) -> dict[str, Any]:
    return {
        "id": d.id,
        "name": d.name,
        "platform": d.platform,
        "last_seen": d.last_seen,
    }


async def _broadcast(session: _Session, payload: dict[str, Any], *, exclude_id: str | None = None) -> None:
    """Send a payload to every device of this user except `exclude_id`."""
    serialized = json.dumps(payload)
    dead: list[str] = []
    for did, device in session.devices.items():
        if did == exclude_id:
            continue
        try:
            await device.socket.send_text(serialized)
        except Exception as e:
            logger.debug(f"[sync] broadcast to {did} failed: {e}")
            dead.append(did)
    for did in dead:
        session.devices.pop(did, None)


async def _send(socket: WebSocket, payload: dict[str, Any]) -> None:
    try:
        await socket.send_text(json.dumps(payload))
    except Exception as e:
        logger.debug(f"[sync] send failed: {e}")


@router.websocket("")
async def sync_socket(
    websocket: WebSocket,
    token: str = Query(...),
):
    """Authenticated WebSocket endpoint at `/api/sync?token=<jwt>`."""
    await websocket.accept()

    # Authenticate via the same JWT used by the REST endpoints.
    async with AsyncSessionLocal() as db:
        user = await auth_service.get_current_user_from_token(db, token)
        if user is None or not user.is_active:
            await _send(websocket, {"type": "error", "detail": "Auth failed"})
            await websocket.close(code=4001)
            return

    user_id = str(user.id)
    session = _sessions.setdefault(user_id, _Session(user_id=user_id))
    device_id: str | None = None

    try:
        # First message MUST be `hello` with device info.
        try:
            first = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
        except asyncio.TimeoutError:
            await _send(websocket, {"type": "error", "detail": "Hello timeout"})
            await websocket.close(code=4002)
            return

        try:
            hello = json.loads(first)
        except Exception:
            await _send(websocket, {"type": "error", "detail": "Invalid JSON"})
            await websocket.close(code=4003)
            return

        if hello.get("type") != "hello":
            await _send(websocket, {"type": "error", "detail": "Expected hello"})
            await websocket.close(code=4003)
            return

        info = hello.get("device") or {}
        device_id = (info.get("id") or "").strip() or str(uuid.uuid4())
        device = _Device(
            id=device_id,
            name=(info.get("name") or "Dispositivo").strip()[:64],
            platform=(info.get("platform") or "unknown").strip()[:32],
            last_seen=time.time(),
            socket=websocket,
        )

        async with session.lock:
            session.devices[device_id] = device
            # Make this device the active one when it's the first to
            # join AND we have no current player state.  Other cases
            # keep whatever device was already active.
            if session.active_device_id is None:
                session.active_device_id = device_id

            # Send snapshot to the new device + notify everyone else.
            await _send(websocket, {
                "type": "snapshot",
                "state": session.state,
                "devices": [_device_public(d) for d in session.devices.values()],
                "active_device_id": session.active_device_id,
            })
            await _broadcast(session, {
                "type": "devices",
                "devices": [_device_public(d) for d in session.devices.values()],
                "active_device_id": session.active_device_id,
            }, exclude_id=device_id)

        logger.info(
            f"[sync] {user.username} device={device.name} ({device.platform}) "
            f"joined; total={len(session.devices)} "
            f"active={session.active_device_id}"
        )

        # Main receive loop.
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            kind = msg.get("type")
            device.last_seen = time.time()

            if kind == "ping":
                await _send(websocket, {"type": "pong"})

            elif kind == "state":
                # Only the active device can publish state.
                if device_id != session.active_device_id:
                    continue
                new_state = msg.get("state")
                if isinstance(new_state, dict):
                    async with session.lock:
                        session.state = new_state
                    await _broadcast(session, {
                        "type": "state",
                        "state": new_state,
                        "from_device_id": device_id,
                    }, exclude_id=device_id)

            elif kind == "command":
                # Forward remote commands to the active device.
                active = session.active_device_id
                if active and active in session.devices and active != device_id:
                    await _send(session.devices[active].socket, {
                        "type": "command",
                        "command": msg.get("command"),
                        "args": msg.get("args") or {},
                        "from_device_id": device_id,
                    })

            elif kind == "transfer":
                # Take over playback.
                target = msg.get("to_device_id") or device_id
                if target not in session.devices:
                    continue
                async with session.lock:
                    session.active_device_id = target
                # Notify everyone — the now-active device should resume
                # playback from session.state.
                await _broadcast(session, {
                    "type": "transferred",
                    "to_device_id": target,
                })
                await _send(websocket, {
                    "type": "transferred",
                    "to_device_id": target,
                })
                logger.info(
                    f"[sync] {user.username} transferred → device={target}"
                )

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.warning(f"[sync] {user_id} loop error: {e}")
    finally:
        if device_id and user_id in _sessions:
            sess = _sessions[user_id]
            async with sess.lock:
                sess.devices.pop(device_id, None)
                if sess.active_device_id == device_id:
                    # Pick another device, or clear if none left.
                    sess.active_device_id = next(iter(sess.devices), None)
                if sess.devices:
                    await _broadcast(sess, {
                        "type": "devices",
                        "devices": [_device_public(d) for d in sess.devices.values()],
                        "active_device_id": sess.active_device_id,
                    })
                else:
                    # Last device left; drop the session entirely so a
                    # restart of the app re-bootstraps state fresh.
                    _sessions.pop(user_id, None)
            logger.info(f"[sync] device {device_id} disconnected")
