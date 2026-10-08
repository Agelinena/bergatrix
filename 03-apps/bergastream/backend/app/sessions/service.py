"""Sessões compartilhadas: membros, convites e ações sobre a reprodução.

Uma pessoa está em no máximo uma sessão por vez (entrar em outra sai da
anterior). Qualquer participante pode convidar e mexer na reprodução; só o
dono muda as configurações, remove pessoas e encerra.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from typing import TYPE_CHECKING

from pydantic import BaseModel

from app.sessions import hub
from app.sessions.playback import ActionError, Playback, apply

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.sessions")

PAUSE_MODES = ("all", "individual")
# Rede de segurança: se ninguém avisar o fim da faixa, avança depois disto
# além da duração (folga para versões um pouco mais longas).
ENDED_GRACE_MS = 20_000


class Person(BaseModel):
    id: str
    username: str
    name: str


class Member(BaseModel):
    user: Person
    status: str          # invited | joined
    online: bool = False


class SessionInfo(BaseModel):
    id: str
    name: str
    owner: Person
    pause_mode: str
    members: list[Member]
    playback: Playback
    server_now: int


class Invite(BaseModel):
    session_id: str
    name: str
    owner: Person
    invited_by: Person | None = None


class MySessions(BaseModel):
    current: SessionInfo | None = None
    invites: list[Invite] = []


class SessionError(Exception):
    def __init__(self, status: int, message: str):
        self.status, self.message = status, message


def now_ms() -> int:
    return int(time.time() * 1000)


def _person(row, prefix: str) -> Person | None:
    if row[f"{prefix}_id"] is None:
        return None
    return Person(id=str(row[f"{prefix}_id"]), username=row[f"{prefix}_username"], name=row[f"{prefix}_name"])


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError):
        return False


async def _session_row(pool, session_id: str):
    if not _is_uuid(session_id):
        raise SessionError(404, "Sessão não encontrada")
    row = await pool.fetchrow(
        """SELECT s.*, o.id AS owner_id, o.username AS owner_username, o.name AS owner_name
           FROM listen_sessions s JOIN users o ON o.id = s.owner_id
           WHERE s.id = $1 AND s.ended_at IS NULL""", session_id)
    if row is None:
        raise SessionError(404, "Sessão não encontrada")
    return row


async def _status(pool, session_id: str, user_id: str) -> str | None:
    return await pool.fetchval(
        "SELECT status FROM listen_session_members WHERE session_id = $1 AND user_id = $2",
        session_id, user_id)


async def require_member(pool, session_id: str, user_id: str):
    row = await _session_row(pool, session_id)
    if await _status(pool, session_id, user_id) != "joined":
        raise SessionError(403, "Você não está nesta sessão")
    return row


async def _playback(pool, session_id: str, row=None) -> Playback:
    r = hub.room(session_id)
    if r.playback is None:
        raw = (row or await _session_row(pool, session_id))["playback"]
        data = json.loads(raw) if isinstance(raw, str) else (raw or {})
        r.playback = Playback.model_validate(data)
    return r.playback


async def info(pool, session_id: str) -> SessionInfo:
    row = await _session_row(pool, session_id)
    members = await pool.fetch(
        """SELECT m.status, u.id AS u_id, u.username AS u_username, u.name AS u_name
           FROM listen_session_members m JOIN users u ON u.id = m.user_id
           WHERE m.session_id = $1 AND m.status IN ('invited', 'joined')
           ORDER BY m.status DESC, u.name""", session_id)
    online = hub.online_users(session_id)
    return SessionInfo(
        id=str(row["id"]), name=row["name"], owner=_person(row, "owner"),
        pause_mode=row["pause_mode"],
        members=[Member(user=_person(m, "u"), status=m["status"], online=str(m["u_id"]) in online)
                 for m in members],
        playback=await _playback(pool, session_id, row), server_now=now_ms())


async def _leave_others(conn, user_id: str, keep: str | None) -> list[str]:
    rows = await conn.fetch(
        """UPDATE listen_session_members SET status = 'left', updated_at = now()
           WHERE user_id = $1 AND status = 'joined' AND ($2::uuid IS NULL OR session_id <> $2)
           RETURNING session_id""", user_id, keep)
    return [str(r["session_id"]) for r in rows]


async def create(pool, user_id: str, name: str, pause_mode: str) -> str:
    if pause_mode not in PAUSE_MODES:
        raise SessionError(422, "Modo de pausa inválido")
    async with pool.acquire() as conn:
        async with conn.transaction():
            left = await _leave_others(conn, user_id, None)
            session_id = str(await conn.fetchval(
                "INSERT INTO listen_sessions (owner_id, name, pause_mode) VALUES ($1, $2, $3) RETURNING id",
                user_id, name.strip()[:60], pause_mode))
            await conn.execute(
                "INSERT INTO listen_session_members (session_id, user_id, status) VALUES ($1, $2, 'joined')",
                session_id, user_id)
    for sid in left:
        await _after_leaving(pool, sid, user_id)
    return session_id


async def mine(pool, user_id: str) -> MySessions:
    current_id = await pool.fetchval(
        """SELECT m.session_id FROM listen_session_members m
           JOIN listen_sessions s ON s.id = m.session_id
           WHERE m.user_id = $1 AND m.status = 'joined' AND s.ended_at IS NULL
           ORDER BY m.updated_at DESC LIMIT 1""", user_id)
    invites = await pool.fetch(
        """SELECT s.id, s.name, o.id AS owner_id, o.username AS owner_username, o.name AS owner_name,
                  i.id AS by_id, i.username AS by_username, i.name AS by_name
           FROM listen_session_members m
           JOIN listen_sessions s ON s.id = m.session_id AND s.ended_at IS NULL
           JOIN users o ON o.id = s.owner_id
           LEFT JOIN users i ON i.id = m.invited_by
           WHERE m.user_id = $1 AND m.status = 'invited'
           ORDER BY m.updated_at DESC""", user_id)
    return MySessions(
        current=await info(pool, str(current_id)) if current_id else None,
        invites=[Invite(session_id=str(r["id"]), name=r["name"], owner=_person(r, "owner"),
                        invited_by=_person(r, "by")) for r in invites])


async def invite(pool, session_id: str, by: str, user_ids: list[str]) -> None:
    await require_member(pool, session_id, by)
    for uid in user_ids:
        if not _is_uuid(uid) or uid == by:
            continue
        if not await pool.fetchval("SELECT 1 FROM users WHERE id = $1", uid):
            continue
        await pool.execute(
            """INSERT INTO listen_session_members (session_id, user_id, status, invited_by)
               VALUES ($1, $2, 'invited', $3)
               ON CONFLICT (session_id, user_id) DO UPDATE
               SET status = CASE WHEN listen_session_members.status = 'joined'
                                 THEN 'joined' ELSE 'invited' END,
                   invited_by = $3, updated_at = now()""", session_id, uid, by)
    await after_members_change(pool, session_id)


async def join(pool, session_id: str, user_id: str) -> SessionInfo:
    await _session_row(pool, session_id)
    status = await _status(pool, session_id, user_id)
    if status is None:
        raise SessionError(403, "Você não foi convidado para esta sessão")
    async with pool.acquire() as conn:
        async with conn.transaction():
            left = await _leave_others(conn, user_id, session_id)
            await conn.execute(
                """UPDATE listen_session_members SET status = 'joined', updated_at = now()
                   WHERE session_id = $1 AND user_id = $2""", session_id, user_id)
    for sid in left:
        await _after_leaving(pool, sid, user_id)
    await after_members_change(pool, session_id)
    return await info(pool, session_id)


async def respond_leave(pool, session_id: str, user_id: str, declined: bool = False) -> None:
    """Sair (ou recusar o convite). Sem ninguém dentro, a sessão acaba."""
    await _session_row(pool, session_id)
    await pool.execute(
        """UPDATE listen_session_members SET status = $3, updated_at = now()
           WHERE session_id = $1 AND user_id = $2""",
        session_id, user_id, "declined" if declined else "left")
    await _after_leaving(pool, session_id, user_id)


async def _after_leaving(pool, session_id: str, user_id: str) -> None:
    """Alguém saiu: sem ninguém dentro, a sessão acaba; senão, avisa os outros."""
    joined = await pool.fetchval(
        "SELECT count(*) FROM listen_session_members WHERE session_id = $1 AND status = 'joined'",
        session_id)
    if joined == 0:
        await end(pool, session_id, by=None)
        return
    await after_members_change(pool, session_id, user_left=user_id)


async def update(pool, session_id: str, by: str, name: str | None, pause_mode: str | None) -> SessionInfo:
    row = await require_member(pool, session_id, by)
    if str(row["owner_id"]) != by:
        raise SessionError(403, "Só quem criou a sessão muda as configurações")
    if pause_mode is not None and pause_mode not in PAUSE_MODES:
        raise SessionError(422, "Modo de pausa inválido")
    await pool.execute(
        """UPDATE listen_sessions SET name = coalesce($2, name), pause_mode = coalesce($3, pause_mode),
                  updated_at = now() WHERE id = $1""",
        session_id, name.strip()[:60] if name is not None else None, pause_mode)
    await after_members_change(pool, session_id)
    return await info(pool, session_id)


async def kick(pool, session_id: str, by: str, user_id: str) -> None:
    row = await require_member(pool, session_id, by)
    if str(row["owner_id"]) != by:
        raise SessionError(403, "Só quem criou a sessão remove pessoas")
    if user_id == by:
        raise SessionError(400, "Para sair, encerre ou saia da sessão")
    await pool.execute(
        """UPDATE listen_session_members SET status = 'left', updated_at = now()
           WHERE session_id = $1 AND user_id = $2""", session_id, user_id)
    await hub.close_user(session_id, user_id, {"type": "removed"})
    await after_members_change(pool, session_id)


async def end(pool, session_id: str, by: str | None) -> None:
    if by is not None:
        row = await _session_row(pool, session_id)
        if str(row["owner_id"]) != by:
            raise SessionError(403, "Só quem criou a sessão encerra")
    await pool.execute("UPDATE listen_sessions SET ended_at = now() WHERE id = $1", session_id)
    await hub.broadcast(session_id, {"type": "ended"})
    for uid in hub.online_users(session_id):
        await hub.close_user(session_id, uid, {"type": "ended"})
    hub.forget(session_id)


async def after_members_change(pool, session_id: str, user_left: str | None = None) -> None:
    if user_left:
        await hub.close_user(session_id, user_left, {"type": "left"})
    try:
        await hub.broadcast(session_id, {"type": "session", "session": (await info(pool, session_id)).model_dump()})
    except SessionError:
        pass


async def act(pool, session_id: str, user_id: str, username: str, action: dict) -> Playback:
    row = await require_member(pool, session_id, user_id)
    return await _act(pool, session_id, row, username, action)


async def _act(pool, session_id: str, row, username: str, action: dict) -> Playback:
    r = hub.room(session_id)
    async with r.lock:
        pb = await _playback(pool, session_id, row)
        try:
            changed = apply(pb, action, now_ms(), username, row["pause_mode"])
        except ActionError as exc:
            raise SessionError(400, str(exc))
        except Exception as exc:  # faixa com campos inválidos, etc.
            raise SessionError(400, f"Ação inválida: {exc}")
        if changed:
            await pool.execute(
                "UPDATE listen_sessions SET playback = $2, updated_at = now() WHERE id = $1",
                session_id, pb.model_dump_json())
    if changed:
        await hub.broadcast(session_id, {"type": "playback", "playback": pb.model_dump(),
                                         "server_now": now_ms(), "by": username})
        asyncio.create_task(_prefetch(pool, pb))
    return pb


async def _prefetch(pool, pb: Playback) -> None:
    """Prepara no servidor a faixa atual e a próxima, uma vez para todos."""
    from app.core.redis import get_redis
    from app.downloads import queue as q
    from app.tracks import service as tracks_service
    from app.tracks.models import PlayRequest
    for priority, i in ((1, pb.index), (3, pb.index + 1)):
        if not 0 <= i < len(pb.queue):
            continue
        track = pb.queue[i].track
        try:
            req = PlayRequest.model_validate(track.model_dump())
            result = await tracks_service.resolve_and_register(pool, req)
            if result.status != "ready":
                await q.enqueue(await get_redis(), result.track_id, req.provider, priority=priority,
                                external_id=req.external_id, title=req.title, artist=req.artist)
        except Exception as exc:
            logger.info("[sessões] não preparou %s: %s", track.title, exc)


async def watchdog(pool) -> None:
    """Rede de segurança: avança se a faixa passou da duração e nenhum
    aparelho avisou o fim (todos com a tela bloqueada, por exemplo)."""
    while True:
        await asyncio.sleep(2)
        for session_id, r in hub.open_rooms():
            pb = r.playback
            current = pb.current() if pb else None
            if not pb or not pb.playing or current is None or current.track.duration_seconds <= 0:
                continue
            if pb.position_at(now_ms()) > current.track.duration_seconds * 1000 + ENDED_GRACE_MS:
                try:
                    row = await _session_row(pool, session_id)
                    await _act(pool, session_id, row, "servidor", {"action": "ended", "uid": current.uid})
                except Exception as exc:
                    logger.info("[sessões] rede de segurança falhou: %s", exc)
