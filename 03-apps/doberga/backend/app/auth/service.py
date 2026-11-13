"""Sessões: emitir, renovar (com rotação) e encerrar."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

from app.auth import repository as repo
from app.auth.models import TokenPair, UserOut
from app.auth.security import create_access_token, hash_refresh_token, new_refresh_token
from app.config import settings

if TYPE_CHECKING:
    import asyncpg


class InvalidRefreshToken(Exception):
    pass


def user_out(row) -> UserOut:
    return UserOut(id=row["id"], username=row["username"], name=row["name"],
                   email=row["email"], is_admin=row["is_admin"])


async def _issue(pool: "asyncpg.Pool", row, family_id: uuid.UUID, user_agent: str | None) -> TokenPair:
    refresh = new_refresh_token()
    await repo.insert_refresh_token(
        pool, row["id"], family_id, hash_refresh_token(refresh),
        datetime.now(timezone.utc) + timedelta(days=settings.refresh_token_days), user_agent)
    return TokenPair(
        access_token=create_access_token(str(row["id"]), row["is_admin"]),
        refresh_token=refresh,
        expires_in=settings.access_token_minutes * 60,
        user=user_out(row),
    )


async def issue_for(pool: "asyncpg.Pool", row, user_agent: str | None) -> TokenPair:
    """Sessão nova para quem acabou de entrar pelo Authentik."""
    return await _issue(pool, row, uuid.uuid4(), user_agent)


async def refresh(pool: "asyncpg.Pool", token: str, user_agent: str | None) -> TokenPair:
    """Troca o refresh token por um par novo. Um token já trocado que
    reaparece revoga a família inteira, exceto logo depois da troca
    (`refresh_grace_seconds`): aí é o app repetindo um pedido cuja resposta
    se perdeu na rede, e ele recebe outro par da mesma família."""
    token_hash = hash_refresh_token(token)
    now = datetime.now(timezone.utc)
    grace = timedelta(seconds=settings.refresh_grace_seconds)
    # A exceção só sai depois do commit: lançar dentro da transação desfaria
    # a revogação da família.
    valid = False
    async with pool.acquire() as conn:
        async with conn.transaction():
            current = await repo.get_refresh_token(conn, token_hash, for_update=True)
            if current is None or current["expires_at"] <= now:
                pass
            elif current["revoked_at"] is None:
                await repo.revoke_refresh_token(conn, current["id"])
                valid = True
            elif current["revoke_reason"] == "rotated" and now - current["revoked_at"] <= grace:
                valid = True
            elif current["revoke_reason"] == "rotated":
                await repo.revoke_family(conn, current["family_id"], "reuse")
    if not valid:
        raise InvalidRefreshToken()
    row = await repo.get_user_by_id(pool, current["user_id"])
    if row is None or row["disabled_at"] is not None:
        raise InvalidRefreshToken()
    return await _issue(pool, row, current["family_id"], user_agent)


async def logout(pool: "asyncpg.Pool", token: str) -> None:
    async with pool.acquire() as conn:
        current = await repo.get_refresh_token(conn, hash_refresh_token(token))
        if current is not None:
            await repo.revoke_family(conn, current["family_id"], "logout")
