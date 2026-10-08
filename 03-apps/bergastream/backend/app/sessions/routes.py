"""Sessões compartilhadas ("ouvir junto"): /api/sessions/*.

REST para criar, convidar, entrar, sair e configurar; WebSocket
(/api/sessions/{id}/ws; primeira mensagem {"type": "auth",
"token": <access token>}) para o tempo real: o servidor
manda o estado e cada mudança; o app manda ações e "ping" (sincronia de
relógio). Detalhes do estado em app/sessions/playback.py.
"""
from __future__ import annotations

import asyncio
import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.auth.security import TokenError, decode_token
from app.core.db import get_pool
from app.sessions import hub
from app.sessions import service as svc
from app.sessions.playback import Playback

logger = logging.getLogger("bergastream.sessions")
router = APIRouter(prefix="/api/sessions", tags=["sessions"])


class NewSession(BaseModel):
    name: str = Field("", max_length=60)
    pause_mode: str = "all"


class SessionPatch(BaseModel):
    name: str | None = Field(None, max_length=60)
    pause_mode: str | None = None


class InviteBody(BaseModel):
    user_ids: list[str] = Field(min_length=1, max_length=50)


def _http(exc: svc.SessionError) -> HTTPException:
    return HTTPException(exc.status, detail=exc.message)


async def _close(ws: WebSocket, code: int) -> None:
    try:
        await ws.close(code=code)
    except RuntimeError:
        pass  # já fechada pelo outro lado


async def _username(user_id: str) -> str:
    return await get_pool().fetchval("SELECT username FROM users WHERE id = $1", user_id) or "?"


@router.get("/me", response_model=svc.MySessions)
async def my_sessions(user: CurrentUser = Depends(current_user)):
    """Sessão em que a pessoa está e convites pendentes (o app consulta de
    tempos em tempos para mostrar os convites)."""
    return await svc.mine(get_pool(), user.id)


@router.post("", status_code=201, response_model=svc.SessionInfo)
async def create(body: NewSession, user: CurrentUser = Depends(current_user)):
    try:
        session_id = await svc.create(get_pool(), user.id, body.name, body.pause_mode)
        return await svc.info(get_pool(), session_id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.get("/{session_id}", response_model=svc.SessionInfo)
async def get(session_id: str, user: CurrentUser = Depends(current_user)):
    try:
        await svc.require_member(get_pool(), session_id, user.id)
        return await svc.info(get_pool(), session_id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.patch("/{session_id}", response_model=svc.SessionInfo)
async def update(session_id: str, body: SessionPatch, user: CurrentUser = Depends(current_user)):
    try:
        return await svc.update(get_pool(), session_id, user.id, body.name, body.pause_mode)
    except svc.SessionError as exc:
        raise _http(exc)


@router.delete("/{session_id}", status_code=204)
async def end(session_id: str, user: CurrentUser = Depends(current_user)):
    try:
        await svc.end(get_pool(), session_id, user.id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.post("/{session_id}/invite", status_code=204)
async def invite(session_id: str, body: InviteBody, user: CurrentUser = Depends(current_user)):
    try:
        await svc.invite(get_pool(), session_id, user.id, body.user_ids)
    except svc.SessionError as exc:
        raise _http(exc)


@router.post("/{session_id}/join", response_model=svc.SessionInfo)
async def join(session_id: str, user: CurrentUser = Depends(current_user)):
    try:
        return await svc.join(get_pool(), session_id, user.id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.post("/{session_id}/leave", status_code=204)
async def leave(session_id: str, user: CurrentUser = Depends(current_user)):
    try:
        await svc.respond_leave(get_pool(), session_id, user.id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.post("/{session_id}/decline", status_code=204)
async def decline(session_id: str, user: CurrentUser = Depends(current_user)):
    try:
        await svc.respond_leave(get_pool(), session_id, user.id, declined=True)
    except svc.SessionError as exc:
        raise _http(exc)


@router.delete("/{session_id}/members/{member_id}", status_code=204)
async def kick(session_id: str, member_id: str, user: CurrentUser = Depends(current_user)):
    try:
        await svc.kick(get_pool(), session_id, user.id, member_id)
    except svc.SessionError as exc:
        raise _http(exc)


@router.post("/{session_id}/actions", response_model=Playback)
async def action(session_id: str, body: dict, user: CurrentUser = Depends(current_user)):
    """Mesma ação do WebSocket, por HTTP (reserva)."""
    try:
        return await svc.act(get_pool(), session_id, user.id, await _username(user.id), body)
    except svc.SessionError as exc:
        raise _http(exc)


AUTH_TIMEOUT_S = 10


@router.websocket("/{session_id}/ws")
async def socket(ws: WebSocket, session_id: str, token: str = Query("")):
    # Aceita antes de conferir: assim o app (inclusive no navegador) recebe
    # o código 4401/4403 e sabe o que fazer. O token vem na primeira
    # mensagem ({"type": "auth", "token": ...}) para não ficar em logs de
    # proxy; ?token= continua aceito.
    await ws.accept()
    try:
        if not token:
            first = json.loads(await asyncio.wait_for(ws.receive_text(), AUTH_TIMEOUT_S))
            token = first.get("token", "") if first.get("type") == "auth" else ""
        user_id = decode_token(token, "access")["sub"]
    except (TokenError, ValueError, AttributeError, asyncio.TimeoutError, WebSocketDisconnect):
        await _close(ws, 4401)  # o app renova o login e reconecta
        return
    pool = get_pool()
    try:
        await svc.require_member(pool, session_id, user_id)
    except svc.SessionError:
        await _close(ws, 4403)
        return
    conn = hub.Connection(ws=ws, user_id=user_id)
    hub.add(session_id, conn)
    username = await _username(user_id)
    try:
        await ws.send_text(json.dumps({"type": "hello",
                                       "session": (await svc.info(pool, session_id)).model_dump()}))
        await svc.after_members_change(pool, session_id)  # avisa que ficou online
        while True:
            message = json.loads(await ws.receive_text())
            kind = message.get("type")
            if kind == "ping":
                await ws.send_text(json.dumps({"type": "pong", "t0": message.get("t0"),
                                               "server_now": svc.now_ms()}))
            elif kind == "action":
                try:
                    await svc.act(pool, session_id, user_id, username, message)
                except svc.SessionError as exc:
                    await ws.send_text(json.dumps({"type": "error", "message": exc.message,
                                                   "id": message.get("id")}))
    except (WebSocketDisconnect, RuntimeError):
        pass
    except Exception as exc:
        logger.info("[sessões] conexão encerrada: %s", exc)
    finally:
        hub.remove(session_id, conn)
        try:
            await svc.after_members_change(pool, session_id)  # ficou offline
        except Exception:
            pass
