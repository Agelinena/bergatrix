"""Push e pull: o sync de todos os módulos (protocolo em docs/ARQUITETURA.md).

Push: cada operação numa transação própria (uma recusada não desfaz as
outras), idempotente pelo op_id, com o lock do sync (a mesma chave do trigger
sync_touch) pego antes de ler a linha. Pull: as linhas com rev acima do
cursor de cada espaço, em ordem de rev.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Literal
from uuid import UUID

import asyncpg
from pydantic import BaseModel, Field

from app.spaces import repository as spaces_repo
from app.sync.registry import STANDARD, TABLES, Invalid, Table, coerce

logger = logging.getLogger("doberga.sync")

SYNC_LOCK = 7461001


class Op(BaseModel):
    op_id: UUID
    table: str = Field(max_length=63)
    row_id: UUID
    kind: Literal["upsert", "delete"]
    fields: dict = Field(default_factory=dict)
    # rev da linha quando foi editada no aparelho (cópia de conflito, futuro).
    base_rev: int | None = None


@dataclass
class Reject(Exception):
    reason: str      # forbidden | invalid | deleted
    message: str


def _ok(op: Op, rev: int | None = None) -> dict:
    return {"op_id": str(op.op_id), "status": "ok", "rev": rev}


def _rejected(op: Op, reject: Reject) -> dict:
    return {"op_id": str(op.op_id), "status": "rejected", "reason": reject.reason,
            "message": reject.message}


async def push(conn, user_id: str, ops: list[Op]) -> tuple[list[dict], set[str]]:
    """Aplica as operações em ordem. Devolve o resultado de cada uma e os
    espaços que mudaram."""
    spaces = {s["id"] for s in await spaces_repo.list_for_user(conn, user_id)}
    results, changed = [], set()
    for op in ops:
        try:
            async with conn.transaction():
                previous = await conn.fetchrow(
                    "SELECT user_id, result FROM applied_ops WHERE op_id = $1", op.op_id)
                if previous is not None:
                    if str(previous["user_id"]) != str(user_id):
                        raise Reject("invalid", "Operação repetida")
                    results.append(previous["result"])
                    continue
                await conn.execute("SELECT pg_advisory_xact_lock($1)", SYNC_LOCK)
                try:
                    rev, space_id = await _apply(conn, user_id, spaces, op)
                    result = _ok(op, rev)
                    if space_id is not None:
                        changed.add(space_id)
                except Reject as reject:
                    result = _rejected(op, reject)
                await conn.execute(
                    "INSERT INTO applied_ops (op_id, user_id, result) VALUES ($1, $2, $3)",
                    op.op_id, user_id, result)
        except Reject as reject:
            result = _rejected(op, reject)
        except (asyncpg.IntegrityConstraintViolationError, asyncpg.DataError) as exc:
            # Regra do banco (CHECK, FK) que o registro não cobriu: recusa e
            # guarda, para o reenvio dar o mesmo resultado.
            logger.info("[sync] operação %s recusada pelo banco: %s", op.op_id, exc)
            result = _rejected(op, Reject("invalid", "Valor não aceito pelo servidor"))
            async with conn.transaction():
                await conn.execute(
                    """INSERT INTO applied_ops (op_id, user_id, result) VALUES ($1, $2, $3)
                       ON CONFLICT (op_id) DO NOTHING""", op.op_id, user_id, result)
        results.append(result)
    return results, changed


async def _apply(conn, user_id: str, spaces: set[str], op: Op) -> tuple[int | None, str | None]:
    table = TABLES.get(op.table)
    if table is None:
        raise Reject("invalid", "Tabela desconhecida (atualize o app)")
    row = await conn.fetchrow(
        f"SELECT space_id, deleted_at FROM {table.name} WHERE id = $1 FOR UPDATE", op.row_id)
    current_space = str(row["space_id"]) if row else None

    if row is not None and current_space not in spaces:
        raise Reject("forbidden", "Você não tem acesso a isso")

    if op.kind == "delete":
        if row is None or row["deleted_at"] is not None:
            return None, None
        rev = await conn.fetchval(
            f"""UPDATE {table.name} SET deleted_at = now(), updated_by = $2
                WHERE id = $1 RETURNING rev""", op.row_id, user_id)
        return rev, current_space

    values = _values(table, op.fields)
    sent_space = op.fields.get("space_id")

    if row is None:
        if not isinstance(sent_space, str) or sent_space not in spaces:
            raise Reject("forbidden", "Você não tem acesso a esse espaço")
        missing = [n for n in table.required if values.get(n) is None]
        if missing:
            raise Reject("invalid", f"Falta: {', '.join(missing)}")
        await _check_refs(conn, table, values, sent_space)
        names = ["id", "space_id", "created_by", "updated_by", *values]
        params = [op.row_id, UUID(sent_space), user_id, user_id, *values.values()]
        marks = ", ".join(f"${i}" for i in range(1, len(params) + 1))
        rev = await conn.fetchval(
            f"INSERT INTO {table.name} ({', '.join(names)}) VALUES ({marks}) RETURNING rev",
            *params)
        return rev, sent_space

    if sent_space is not None and sent_space != current_space:
        raise Reject("invalid", "Para mudar de espaço, crie uma cópia no outro espaço")
    if row["deleted_at"] is not None:
        raise Reject("deleted", "Foi apagado por outra pessoa")
    if table.append_only:
        raise Reject("invalid", "Esse registro não pode ser alterado")
    if not values:
        return None, None
    await _check_refs(conn, table, values, current_space)
    sets = ", ".join(f"{name} = ${i}" for i, name in enumerate(values, start=3))
    rev = await conn.fetchval(
        f"UPDATE {table.name} SET updated_by = $2, {sets} WHERE id = $1 RETURNING rev",
        op.row_id, user_id, *values.values())
    return rev, current_space


def _values(table: Table, fields: dict) -> dict:
    values = {}
    for name, value in fields.items():
        if name == "space_id":
            continue
        col = table.columns.get(name)
        if col is None:
            if name in STANDARD:
                continue     # o servidor cuida
            raise Reject("invalid", f"Campo desconhecido: {name} (atualize o app)")
        try:
            values[name] = coerce(name, col, value)
        except Invalid as exc:
            raise Reject("invalid", str(exc)) from None
    return values


async def _check_refs(conn, table: Table, values: dict, space_id: str) -> None:
    """Uma referência precisa apontar para uma linha do mesmo espaço."""
    for name, value in values.items():
        col = table.columns[name]
        if col.kind != "ref" or value is None:
            continue
        target = await conn.fetchval(f"SELECT space_id FROM {col.ref} WHERE id = $1", value)
        if target is None or str(target) != space_id:
            raise Reject("invalid", f"{name} aponta para algo que não existe neste espaço")


# ── Pull ────────────────────────────────────────────────────────────

async def pull(conn, user_id: str, cursors: dict[str, int], limit: int) -> dict:
    spaces = await spaces_repo.list_for_user(conn, user_id)
    purged = await conn.fetchval("SELECT value FROM sync_meta WHERE key = 'purged_rev'") or 0
    since, reset = {}, []
    for space in spaces:
        cursor = max(0, int(cursors.get(space["id"], 0) or 0))
        if 0 < cursor < purged:
            # Uma exclusão que este aparelho ainda não viu já foi apagada de vez.
            reset.append(space["id"])
            cursor = 0
        since[space["id"]] = cursor

    changes: list[dict] = []
    has_more = False
    if since and TABLES:
        parts = [
            f"""SELECT '{name}' AS tbl, t.rev, to_jsonb(t) AS row FROM {name} t
                JOIN unnest($1::uuid[], $2::bigint[]) AS c(space_id, since)
                  ON t.space_id = c.space_id
                WHERE t.rev > c.since AND (c.since > 0 OR t.deleted_at IS NULL)"""
            for name in TABLES]
        query = " UNION ALL ".join(parts) + " ORDER BY rev LIMIT $3"
        rows = await conn.fetch(query, list(since), list(since.values()), limit + 1)
        has_more = len(rows) > limit
        rows = rows[:limit]
        changes = [{"table": r["tbl"], "row": r["row"]} for r in rows]
        if rows:
            # Toda linha com rev até o último devolvido já veio (ordem de rev,
            # e o lock garante que nenhuma com rev menor ainda vai aparecer).
            cutoff = rows[-1]["rev"]
            since = {sid: max(c, cutoff) for sid, c in since.items()}

    return {"spaces": spaces, "changes": changes, "cursors": since, "reset": reset,
            "has_more": has_more}


# ── Limpeza ─────────────────────────────────────────────────────────

async def cleanup(pool, retention_days: int) -> dict:
    """Apaga de vez as lápides e as operações aplicadas antigas."""
    purged_rows, purged_rev = 0, 0
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1)", SYNC_LOCK)
            for name in TABLES:
                row = await conn.fetchrow(
                    f"""WITH d AS (DELETE FROM {name}
                                   WHERE deleted_at < now() - make_interval(days => $1)
                                   RETURNING rev)
                        SELECT count(*) AS n, max(rev) AS rev FROM d""", retention_days)
                purged_rows += row["n"]
                purged_rev = max(purged_rev, row["rev"] or 0)
            if purged_rev:
                await conn.execute(
                    "UPDATE sync_meta SET value = greatest(value, $1) WHERE key = 'purged_rev'",
                    purged_rev)
        ops = await conn.execute(
            "DELETE FROM applied_ops WHERE applied_at < now() - make_interval(days => $1)",
            retention_days)
        invites = await conn.execute(
            "DELETE FROM space_invites WHERE expires_at < now() - interval '7 days' OR uses_left = 0")
    return {"rows": purged_rows, "ops": int(ops.split()[-1]), "invites": int(invites.split()[-1])}
