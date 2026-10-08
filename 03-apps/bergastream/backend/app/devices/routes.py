"""Aparelhos conectados ("Tocar em…", como o Spotify Connect).

Cada app aberto e logado mantém um WebSocket em /api/devices/ws. O servidor
sabe quais aparelhos da pessoa estão online e qual é o **ativo** (o único que
toca). Os outros são controles remotos: recebem o estado do ativo e mandam
comandos para ele. Trocar de aparelho passa a fila e o ponto da música do
ativo para o escolhido.

Tudo fica em memória (uvicorn roda com um worker só): ao reiniciar a API os
apps reconectam e o primeiro que tocar vira o ativo.

Mensagens (JSON):
  app → servidor
    auth      {token, device: {id, name, platform}}   (primeira mensagem)
    ping      {t0}
    activate  {}                     este aparelho vai tocar
    state     {state}                estado do ativo (só o ativo manda)
    command   {command: {...}}       para o ativo executar
    transfer  {to, state?}           tocar em outro aparelho
    handoff_state {state}            resposta do ativo a "handoff"
  servidor → app
    hello     {device_id, devices, active, state, server_now}
    devices   {devices, active}
    state     {state, from}
    command   {command, from}
    handoff   {to}                   pare e mande o estado completo
    play_here {state}                agora é aqui que toca
    pong / error
Fecha com 4401 (login inválido) e 4409 (mesmo aparelho conectou de novo).
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.auth.security import TokenError, decode_token

logger = logging.getLogger("bergastream.devices")
router = APIRouter(prefix="/api/devices", tags=["devices"])

PLATFORMS = ("web", "android", "windows", "linux", "ios", "macos")
AUTH_TIMEOUT_S = 10
HANDOFF_TIMEOUT_S = 5


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass(eq=False)
class Device:
    id: str
    name: str
    platform: str
    ws: WebSocket

    def public(self, active: str | None) -> dict:
        return {"id": self.id, "name": self.name, "platform": self.platform,
                "active": self.id == active}


@dataclass
class UserDevices:
    devices: dict[str, Device] = field(default_factory=dict)
    active: str | None = None
    state: dict | None = None
    handoffs: dict[str, asyncio.Future] = field(default_factory=dict)


_users: dict[str, UserDevices] = {}


def _ud(user_id: str) -> UserDevices:
    return _users.setdefault(user_id, UserDevices())


async def _send(device: Device, message: dict) -> None:
    try:
        await device.ws.send_text(json.dumps(message))
    except Exception:
        pass  # caiu; o finally da conexão limpa


def _listing(ud: UserDevices) -> dict:
    return {"type": "devices", "active": ud.active,
            "devices": [d.public(ud.active) for d in ud.devices.values()]}


async def _broadcast(ud: UserDevices, message: dict, skip: str | None = None) -> None:
    for d in list(ud.devices.values()):
        if d.id != skip:
            await _send(d, message)


async def _set_active(ud: UserDevices, device_id: str | None) -> None:
    if ud.active != device_id:
        ud.active = device_id
        ud.state = None
    await _broadcast(ud, _listing(ud))


async def _transfer(ud: UserDevices, requester: Device, to: str, state: dict | None) -> None:
    target = ud.devices.get(to)
    if target is None:
        await _send(requester, {"type": "error", "message": "Aparelho não está mais online"})
        return
    old = ud.devices.get(ud.active) if ud.active else None
    if old is not None and old.id == to:
        return
    if old is not None and old.id != requester.id:
        # O ativo é outro aparelho: ele para e manda a fila e o ponto.
        future = asyncio.get_running_loop().create_future()
        ud.handoffs[old.id] = future
        await _send(old, {"type": "handoff", "to": to})
        try:
            state = await asyncio.wait_for(future, HANDOFF_TIMEOUT_S)
        except asyncio.TimeoutError:
            state = None
        finally:
            ud.handoffs.pop(old.id, None)
    ud.active = to
    ud.state = None
    await _send(target, {"type": "play_here", "state": state})
    await _broadcast(ud, _listing(ud))


def _device_info(raw) -> tuple[str, str, str] | None:
    if not isinstance(raw, dict):
        return None
    device_id = str(raw.get("id") or "")[:64]
    name = str(raw.get("name") or "Aparelho")[:60]
    platform = str(raw.get("platform") or "")
    if not device_id or platform not in PLATFORMS:
        return None
    return device_id, name, platform


async def _close(ws: WebSocket, code: int) -> None:
    try:
        await ws.close(code=code)
    except RuntimeError:
        pass


@router.websocket("/ws")
async def socket(ws: WebSocket):
    await ws.accept()
    try:
        first = json.loads(await asyncio.wait_for(ws.receive_text(), AUTH_TIMEOUT_S))
        user_id = decode_token(first.get("token", ""), "access")["sub"]
        info = _device_info(first.get("device"))
    except (TokenError, ValueError, AttributeError, asyncio.TimeoutError, WebSocketDisconnect):
        await _close(ws, 4401)
        return
    if info is None:
        await _close(ws, 4400)
        return
    ud = _ud(user_id)
    me = Device(id=info[0], name=info[1], platform=info[2], ws=ws)
    previous = ud.devices.get(me.id)
    ud.devices[me.id] = me
    if previous is not None:
        # Mesmo aparelho (ex.: outra aba do navegador): a conexão nova vale.
        await _send(previous, {"type": "error", "message": "Aberto em outra janela"})
        await _close(previous.ws, 4409)
    try:
        await ws.send_text(json.dumps({**_listing(ud), "type": "hello", "device_id": me.id,
                                       "state": ud.state, "server_now": now_ms()}))
        await _broadcast(ud, _listing(ud), skip=me.id)
        while True:
            message = json.loads(await ws.receive_text())
            kind = message.get("type")
            if kind == "ping":
                await _send(me, {"type": "pong", "t0": message.get("t0"), "server_now": now_ms()})
            elif kind == "activate":
                if ud.active != me.id:
                    await _set_active(ud, me.id)
            elif kind == "state":
                if ud.active == me.id and isinstance(message.get("state"), dict):
                    ud.state = {**message["state"], "at": now_ms()}
                    await _broadcast(ud, {"type": "state", "state": ud.state, "from": me.id},
                                     skip=me.id)
            elif kind == "command":
                active = ud.devices.get(ud.active) if ud.active else None
                if active is None or active.id == me.id:
                    await _send(me, {"type": "error", "message": "Nenhum outro aparelho tocando"})
                else:
                    await _send(active, {"type": "command", "command": message.get("command"),
                                         "from": me.name})
            elif kind == "transfer":
                state = message.get("state") if isinstance(message.get("state"), dict) else None
                # Em tarefa própria: a resposta do ativo chega por outra conexão.
                asyncio.create_task(_transfer(ud, me, str(message.get("to") or ""), state))
            elif kind == "handoff_state":
                future = ud.handoffs.get(me.id)
                if future is not None and not future.done():
                    state = message.get("state")
                    future.set_result(state if isinstance(state, dict) else None)
    except (WebSocketDisconnect, RuntimeError):
        pass
    except Exception as exc:
        logger.info("[aparelhos] conexão encerrada: %s", exc)
    finally:
        if ud.devices.get(me.id) is me:
            del ud.devices[me.id]
            if ud.active == me.id:
                ud.active = None
                ud.state = None
            await _broadcast(ud, _listing(ud))
