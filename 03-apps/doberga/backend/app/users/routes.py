"""Página "Usuários" do admin: /api/admin/users.

As contas nascem no Authentik (grupo doberga_users) e são criadas aqui no
primeiro login. Daqui o admin só desativa, reativa e desconecta aparelhos;
nome, e-mail e admin vêm do Authentik. Desativar não apaga nada: espaços,
listas, notas e histórico ficam.
"""
from __future__ import annotations

import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import repository as repo
from app.auth.dependencies import CurrentUser, admin_user
from app.core.db import get_pool

logger = logging.getLogger("doberga.admin")
router = APIRouter(prefix="/api/admin/users", tags=["admin"])


class AdminUser(BaseModel):
    id: str
    username: str
    name: str
    email: str | None
    is_admin: bool
    disabled: bool
    last_login_at: str | None
    created_at: str
    spaces: int
    sessions: int


class UserPatch(BaseModel):
    disabled: bool


def _iso(value) -> str | None:
    return value.isoformat() if value else None


@router.get("", response_model=list[AdminUser])
async def list_users(_: CurrentUser = Depends(admin_user)):
    rows = await get_pool().fetch(
        """SELECT u.*,
                  (SELECT count(*) FROM space_members m WHERE m.user_id = u.id) AS spc,
                  (SELECT count(*) FROM refresh_tokens t WHERE t.user_id = u.id
                     AND t.revoked_at IS NULL AND t.expires_at > now()) AS sess
           FROM users u ORDER BY lower(u.name)""")
    return [AdminUser(id=str(r["id"]), username=r["username"], name=r["name"], email=r["email"],
                      is_admin=r["is_admin"], disabled=r["disabled_at"] is not None,
                      last_login_at=_iso(r["last_login_at"]), created_at=_iso(r["created_at"]),
                      spaces=r["spc"], sessions=r["sess"]) for r in rows]


@router.patch("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def patch_user(user_id: UUID, body: UserPatch, admin: CurrentUser = Depends(admin_user)):
    if str(user_id) == admin.id and body.disabled:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Você não pode desativar a própria conta")
    pool = get_pool()
    row = await repo.get_user_by_id(pool, user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Usuário não encontrado")
    await pool.execute(
        "UPDATE users SET disabled_at = CASE WHEN $2 THEN coalesce(disabled_at, now()) END WHERE id = $1",
        row["id"], body.disabled)
    if body.disabled:
        await repo.revoke_all_for_user(pool, row["id"])
    logger.info("[admin] %s %s a conta %s", admin.id, "desativou" if body.disabled else "reativou",
                user_id)


@router.post("/{user_id}/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout_user(user_id: UUID, admin: CurrentUser = Depends(admin_user)):
    """Desconecta os aparelhos (pedem login de novo em até 15 min)."""
    pool = get_pool()
    row = await repo.get_user_by_id(pool, user_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Usuário não encontrado")
    await repo.revoke_all_for_user(pool, row["id"])
    logger.info("[admin] %s desconectou os aparelhos da conta %s", admin.id, user_id)
