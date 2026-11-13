"""Espaços, membros e convites: /api/spaces, /api/invites.

Qualquer pessoa cria um grupo e vira dona dele. O dono renomeia, convida,
muda papéis, remove membros e apaga o grupo; o membro usa e pode sair. O
último dono só sai passando o grupo para outra pessoa (ou apagando-o, se for
o único membro). Tudo aqui exige conexão; o conteúdo dos espaços vai pelo sync.
"""
from __future__ import annotations

import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core.db import get_pool
from app.core.redis import get_redis
from app.spaces import repository as repo
from app.sync import events

logger = logging.getLogger("doberga.spaces")
router = APIRouter(tags=["spaces"])

_COLOR = r"^#[0-9a-fA-F]{6}$"
_ICON = r"^[a-z0-9_]{1,40}$"


class SpaceIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    color: str | None = Field(None, pattern=_COLOR)
    icon: str | None = Field(None, pattern=_ICON)


class SpacePatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=60)
    color: str | None = Field(None, pattern=_COLOR)
    icon: str | None = Field(None, pattern=_ICON)


class InviteIn(BaseModel):
    days: int = Field(settings.invite_days, ge=1, le=30)
    uses: int = Field(settings.invite_max_uses, ge=1, le=50)


class MemberPatch(BaseModel):
    role: str = Field(pattern="^(owner|member)$")


def _not_found() -> HTTPException:
    return HTTPException(status.HTTP_404_NOT_FOUND, detail="Espaço não encontrado")


async def _require(conn, space_id: UUID, user: CurrentUser, owner: bool = False):
    found = await repo.membership(conn, space_id, user.id)
    if found is None:
        raise _not_found()
    if owner and found["role"] != "owner":
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Só o dono do grupo pode fazer isso")
    return found


async def _space_out(conn, space_id, user_id) -> dict:
    for space in await repo.list_for_user(conn, user_id):
        if space["id"] == str(space_id):
            return space
    raise _not_found()


@router.get("/api/spaces")
async def list_spaces(user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        return await repo.list_for_user(conn, user.id)


@router.post("/api/spaces", status_code=status.HTTP_201_CREATED)
async def create_space(body: SpaceIn, user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        space_id = await repo.create_group(conn, user.id, body.name.strip(), body.color, body.icon)
        logger.info("[spaces] %s criou o grupo %s", user.id, space_id)
        await events.spaces_changed(await get_redis(), [user.id])
        return await _space_out(conn, space_id, user.id)


@router.patch("/api/spaces/{space_id}")
async def patch_space(space_id: UUID, body: SpacePatch, user: CurrentUser = Depends(current_user)):
    changes = body.model_dump(exclude_unset=True)
    async with get_pool().acquire() as conn:
        found = await _require(conn, space_id, user)
        # O espaço pessoal é só da pessoa: ela muda nome, cor e ícone.
        if found["kind"] == "group" and found["role"] != "owner":
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Só o dono do grupo pode fazer isso")
        if "name" in changes and changes["name"] is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="O nome não pode ficar vazio")
        if changes:
            sets = ", ".join(f"{k} = ${i}" for i, k in enumerate(changes, start=2))
            values = [v.strip() if isinstance(v, str) and k == "name" else v for k, v in changes.items()]
            await conn.execute(f"UPDATE spaces SET {sets}, updated_at = now() WHERE id = $1",
                               space_id, *values)
            await events.spaces_changed(await get_redis(), await repo.member_ids(conn, space_id))
        return await _space_out(conn, space_id, user.id)


@router.delete("/api/spaces/{space_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_space(space_id: UUID, user: CurrentUser = Depends(current_user)):
    """Apaga o grupo e tudo dele, para todos os membros."""
    async with get_pool().acquire() as conn:
        found = await _require(conn, space_id, user, owner=True)
        if found["kind"] == "personal":
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="O espaço pessoal não pode ser apagado")
        members = await repo.member_ids(conn, space_id)
        await conn.execute("DELETE FROM spaces WHERE id = $1", space_id)
    logger.info("[spaces] %s apagou o grupo %s", user.id, space_id)
    await events.spaces_changed(await get_redis(), members)


# ── Membros ─────────────────────────────────────────────────────────

@router.patch("/api/spaces/{space_id}/members/{member_id}")
async def patch_member(space_id: UUID, member_id: UUID, body: MemberPatch,
                       user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        found = await _require(conn, space_id, user, owner=True)
        if found["kind"] == "personal":
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="O espaço pessoal não tem membros")
        async with conn.transaction():
            await conn.execute("SELECT 1 FROM spaces WHERE id = $1 FOR UPDATE", space_id)
            done = await conn.execute(
                "UPDATE space_members SET role = $3 WHERE space_id = $1 AND user_id = $2",
                space_id, member_id, body.role)
            if done.endswith(" 0"):
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Essa pessoa não está no grupo")
            owners = await conn.fetchval(
                "SELECT count(*) FROM space_members WHERE space_id = $1 AND role = 'owner'", space_id)
            if owners == 0:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    detail="O grupo precisa de pelo menos um dono")
        await events.spaces_changed(await get_redis(), await repo.member_ids(conn, space_id))
        return await _space_out(conn, space_id, user.id)


@router.delete("/api/spaces/{space_id}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_member(space_id: UUID, member_id: UUID, user: CurrentUser = Depends(current_user)):
    """O dono remove alguém; qualquer membro remove a si mesmo (sair)."""
    leaving = str(member_id) == user.id
    async with get_pool().acquire() as conn:
        found = await _require(conn, space_id, user, owner=not leaving)
        if found["kind"] == "personal":
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="O espaço pessoal não tem membros")
        async with conn.transaction():
            await conn.execute("SELECT 1 FROM spaces WHERE id = $1 FOR UPDATE", space_id)
            members = await conn.fetch(
                "SELECT user_id, role FROM space_members WHERE space_id = $1", space_id)
            target = next((m for m in members if str(m["user_id"]) == str(member_id)), None)
            if target is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Essa pessoa não está no grupo")
            if len(members) == 1:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    detail="Você é a única pessoa do grupo: apague o grupo em vez de sair")
            owners = [m for m in members if m["role"] == "owner"]
            if target["role"] == "owner" and len(owners) == 1:
                raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                    detail="Passe o grupo para outra pessoa (torne-a dona) antes de sair")
            await conn.execute("DELETE FROM space_members WHERE space_id = $1 AND user_id = $2",
                               space_id, member_id)
        all_ids = [m["user_id"] for m in members]
    logger.info("[spaces] %s tirou %s do grupo %s", user.id, member_id, space_id)
    await events.spaces_changed(await get_redis(), all_ids)


# ── Convites ────────────────────────────────────────────────────────

@router.post("/api/spaces/{space_id}/invites", status_code=status.HTTP_201_CREATED)
async def create_invite(space_id: UUID, body: InviteIn, user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        found = await _require(conn, space_id, user, owner=True)
        if found["kind"] == "personal":
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                detail="O espaço pessoal não aceita convites: crie um grupo")
        token, expires = await repo.create_invite(conn, space_id, user.id, body.days, body.uses)
    base = settings.public_url or ""
    return {"token": token, "url": f"{base}/convite/{token}", "expires_at": expires.isoformat(),
            "uses": body.uses}


@router.get("/api/spaces/{space_id}/invites")
async def list_invites(space_id: UUID, user: CurrentUser = Depends(current_user)):
    """Convites ativos (o link não aparece de novo: só o hash fica guardado)."""
    async with get_pool().acquire() as conn:
        await _require(conn, space_id, user, owner=True)
        rows = await conn.fetch(
            """SELECT i.id, i.created_at, i.expires_at, i.uses_left, u.name AS created_by
               FROM space_invites i LEFT JOIN users u ON u.id = i.created_by
               WHERE i.space_id = $1 AND i.revoked_at IS NULL AND i.expires_at > now()
                 AND i.uses_left > 0
               ORDER BY i.created_at DESC""", space_id)
    return [{"id": str(r["id"]), "created_at": r["created_at"].isoformat(),
             "expires_at": r["expires_at"].isoformat(), "uses_left": r["uses_left"],
             "created_by": r["created_by"]} for r in rows]


@router.delete("/api/spaces/{space_id}/invites/{invite_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_invite(space_id: UUID, invite_id: UUID, user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        await _require(conn, space_id, user, owner=True)
        await conn.execute(
            "UPDATE space_invites SET revoked_at = now() WHERE id = $1 AND space_id = $2",
            invite_id, space_id)


@router.get("/api/invites/{token}")
async def preview_invite(token: str, user: CurrentUser = Depends(current_user)):
    """O que a pessoa vê antes de aceitar."""
    async with get_pool().acquire() as conn:
        invite = await repo.find_invite(conn, token[:100])
        if invite is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Convite inválido ou vencido")
        already = await repo.membership(conn, invite["space_id"], user.id) is not None
    return {"space_id": str(invite["space_id"]), "space_name": invite["space_name"],
            "color": invite["color"], "icon": invite["icon"], "inviter": invite["inviter"],
            "members": invite["members"], "already_member": already}


@router.post("/api/invites/{token}/accept")
async def accept_invite(token: str, response: Response, user: CurrentUser = Depends(current_user)):
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            invite = await repo.find_invite(conn, token[:100], for_update=True)
            if invite is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Convite inválido ou vencido")
            added = await conn.fetchval(
                """INSERT INTO space_members (space_id, user_id, role) VALUES ($1, $2, 'member')
                   ON CONFLICT DO NOTHING RETURNING true""", invite["space_id"], user.id)
            if added:
                await conn.execute("UPDATE space_invites SET uses_left = uses_left - 1 WHERE id = $1",
                                   invite["id"])
        if added:
            logger.info("[spaces] %s entrou no grupo %s por convite", user.id, invite["space_id"])
            await events.spaces_changed(await get_redis(), await repo.member_ids(conn, invite["space_id"]))
        else:
            response.status_code = status.HTTP_200_OK
        return await _space_out(conn, invite["space_id"], user.id)
