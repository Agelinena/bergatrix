"""Rotas do agente (/agent/api). Só o agente inicia a conexão: ele busca o
plano e os comandos e manda os resultados. Ele não abre porta nenhuma.

Essas rotas não passam pelo Traefik (a regra do roteador exclui /agent). O
agente fala com a porta publicada só em 127.0.0.1 do host. Pedido com
X-Forwarded-For veio por um proxy e é recusado.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import secrets
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from bergakup import plan
from bergakup.auth import token_hash

logger = logging.getLogger("bergakup.agent")
router = APIRouter(prefix="/agent/api")

TOKEN_PREFIX = "bka_"
HEAVY_KINDS = {"backup", "forget", "prune", "check", "restore", "import_dumps", "init"}
MAX_LOG_LINE = 4000


def pool(request: Request):
    return request.app.state.pool


async def current_agent(request: Request):
    if request.headers.get("x-forwarded-for"):
        raise HTTPException(403, "As rotas do agente não passam pelo proxy.")
    authorization = request.headers.get("authorization", "")
    token = authorization[7:].strip() if authorization.lower().startswith("bearer ") else ""
    row = await pool(request).fetchrow(
        "UPDATE agents SET last_seen_at = now() WHERE token_hash = $1 RETURNING id, name",
        token_hash(token)) if token.startswith(TOKEN_PREFIX) else None
    if row is None:
        raise HTTPException(401, "Agente não reconhecido.")
    return row


# ── Registro ──────────────────────────────────────────────────────────

class Enroll(BaseModel):
    code: str = Field(min_length=8, max_length=200)
    name: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{0,39}$")
    hostname: str = Field(default="", max_length=200)
    public_key: str = Field(min_length=40, max_length=100)
    version: str = Field(default="", max_length=60)
    repo_root: str = Field(default="", max_length=500)


@router.post("/enroll")
async def enroll(body: Enroll, request: Request):
    if request.headers.get("x-forwarded-for"):
        raise HTTPException(403, "As rotas do agente não passam pelo proxy.")
    try:
        if len(base64.b64decode(body.public_key, validate=True)) != 32:
            raise ValueError
    except ValueError:
        raise HTTPException(422, "Chave pública inválida.")
    if body.repo_root and not body.repo_root.startswith("/"):
        raise HTTPException(422, "repo_root precisa ser um caminho absoluto.")
    token = TOKEN_PREFIX + secrets.token_urlsafe(32)
    async with pool(request).acquire() as conn, conn.transaction():
        code = await conn.fetchrow(
            """UPDATE enrollment_codes SET used_at = now()
               WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING created_by""",
            token_hash(body.code.strip()))
        if code is None:
            raise HTTPException(403, "Código inválido, usado ou vencido. Gere outro na interface.")
        existing = await conn.fetchrow("SELECT id FROM agents WHERE name = $1", body.name)
        if existing:
            # Reinstalação (ex.: recuperação de desastre): mesma identidade, chave nova.
            # Os segredos cifrados para a chave antiga deixam de abrir e precisam ser digitados de novo.
            agent_id = existing["id"]
            await conn.execute(
                """UPDATE agents SET hostname = $2, public_key = $3, token_hash = $4, version = $5,
                       applied_revision = 0, last_seen_at = now() WHERE id = $1""",
                agent_id, body.hostname, body.public_key, token_hash(token), body.version)
            await conn.execute("UPDATE storages SET secret_sealed = NULL WHERE agent_id = $1", agent_id)
            await conn.execute(
                """UPDATE repositories SET password_sealed = NULL WHERE dataset_id IN
                   (SELECT id FROM datasets WHERE agent_id = $1)""", agent_id)
            await conn.execute("UPDATE agent_settings SET smtp_password_sealed = NULL WHERE agent_id = $1",
                               agent_id)
        else:
            agent_id = await conn.fetchval(
                """INSERT INTO agents (name, hostname, public_key, token_hash, version, last_seen_at)
                   VALUES ($1, $2, $3, $4, $5, now()) RETURNING id""",
                body.name, body.hostname, body.public_key, token_hash(token), body.version)
            await plan.create_defaults(conn, agent_id, body.repo_root.rstrip("/"))
        await conn.execute("UPDATE enrollment_codes SET agent_id = $2 WHERE code_hash = $1",
                           token_hash(body.code.strip()), agent_id)
        await conn.execute(
            "INSERT INTO audit_log (user_id, action, detail) VALUES ($1, 'agent.enroll', $2)",
            code["created_by"], {"agent": body.name, "hostname": body.hostname, "reinstall": bool(existing)})
        await plan.publish(conn, agent_id, code["created_by"])
    return {"agent_id": str(agent_id), "token": token}


# ── Sinal de vida e plano ─────────────────────────────────────────────

class Heartbeat(BaseModel):
    version: str = ""
    applied_revision: int = 0
    apply_error: str | None = None
    info: dict = Field(default_factory=dict)


@router.post("/heartbeat")
async def heartbeat(body: Heartbeat, request: Request, agent=Depends(current_agent)):
    db = pool(request)
    await db.execute(
        """UPDATE agents SET version = $2, applied_revision = $3, apply_error = $4,
               info = CASE WHEN $5::jsonb = '{}'::jsonb THEN info ELSE $5::jsonb END
           WHERE id = $1""",
        agent["id"], body.version[:60], body.applied_revision, (body.apply_error or None) and body.apply_error[:2000],
        body.info)
    revision = await db.fetchval("SELECT max(revision) FROM config_revisions WHERE agent_id = $1", agent["id"])
    return {"revision": revision or 0}


@router.get("/plan")
async def get_plan(request: Request, agent=Depends(current_agent)):
    row = await pool(request).fetchrow(
        "SELECT document FROM config_revisions WHERE agent_id = $1 ORDER BY revision DESC LIMIT 1", agent["id"])
    if row is None:
        raise HTTPException(404, "Sem plano.")
    return row["document"]


# ── Comandos ──────────────────────────────────────────────────────────

@router.get("/commands")
async def poll_commands(request: Request, wait: int = 25, agent=Depends(current_agent)):
    """Espera (long poll) até `wait` segundos por comandos pendentes."""
    db = pool(request)
    deadline = asyncio.get_running_loop().time() + max(0, min(wait, 50))
    while True:
        rows = await db.fetch(
            """UPDATE commands SET status = 'dispatched', dispatched_at = now()
               WHERE id IN (SELECT id FROM commands WHERE agent_id = $1 AND status = 'pending'
                            ORDER BY created_at LIMIT 20 FOR UPDATE SKIP LOCKED)
               RETURNING id, kind, params, created_at""", agent["id"])
        if rows or asyncio.get_running_loop().time() >= deadline or await request.is_disconnected():
            return [{"id": str(r["id"]), "kind": r["kind"], "params": r["params"]}
                    for r in sorted(rows, key=lambda r: r["created_at"])]
        await asyncio.sleep(1)


# ── Execuções ─────────────────────────────────────────────────────────

class RunStart(BaseModel):
    id: UUID
    kind: str = Field(max_length=40)
    job_id: UUID | None = None
    repository_id: UUID | None = None
    command_id: UUID | None = None
    trigger: str = Field(default="schedule", max_length=20)
    started_at: datetime


async def _existing(db, table: str, value):
    if value is None:
        return None
    return value if await db.fetchval(f"SELECT 1 FROM {table} WHERE id = $1", value) else None


@router.post("/runs")
async def run_start(body: RunStart, request: Request, agent=Depends(current_agent)):
    db = pool(request)
    # Uma tarefa ou repositório apagado na web enquanto o agente rodava não impede o registro.
    job_id = await _existing(db, "jobs", body.job_id)
    repository_id = await _existing(db, "repositories", body.repository_id)
    command_id = await _existing(db, "commands", body.command_id)
    await db.execute(
        """INSERT INTO runs (id, agent_id, kind, job_id, repository_id, command_id, trigger, started_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (id) DO NOTHING""",
        body.id, agent["id"], body.kind, job_id, repository_id, command_id, body.trigger, body.started_at)
    if command_id:
        await db.execute("UPDATE commands SET run_id = $2 WHERE id = $1", command_id, body.id)
    return {"status": "ok"}


class LogLine(BaseModel):
    seq: int
    ts: datetime
    level: str = Field(max_length=10)
    line: str


@router.post("/runs/{run_id}/logs")
async def run_logs(run_id: UUID, lines: list[LogLine], request: Request, agent=Depends(current_agent)):
    db = pool(request)
    if not await db.fetchval("SELECT 1 FROM runs WHERE id = $1 AND agent_id = $2", run_id, agent["id"]):
        raise HTTPException(404, "Execução desconhecida.")
    await db.executemany(
        """INSERT INTO run_logs (run_id, seq, ts, level, line) VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT DO NOTHING""",
        [(run_id, line.seq, line.ts, line.level, line.line[:MAX_LOG_LINE]) for line in lines[:2000]])
    return {"status": "ok"}


class RunFinish(BaseModel):
    status: str = Field(pattern=r"^(success|warning|failed)$")
    finished_at: datetime
    summary: dict = Field(default_factory=dict)
    error: str | None = None


@router.post("/runs/{run_id}/finish")
async def run_finish(run_id: UUID, body: RunFinish, request: Request, agent=Depends(current_agent)):
    db = pool(request)
    async with db.acquire() as conn, conn.transaction():
        run = await conn.fetchrow(
            """UPDATE runs SET status = $3, finished_at = $4, summary = $5, error = $6
               WHERE id = $1 AND agent_id = $2 RETURNING kind, job_id, repository_id, command_id""",
            run_id, agent["id"], body.status, body.finished_at, body.summary, body.error and body.error[:4000])
        if run is None:
            raise HTTPException(404, "Execução desconhecida.")
        if run["command_id"]:
            await conn.execute("UPDATE commands SET status = $2, finished_at = now() WHERE id = $1",
                               run["command_id"], "failed" if body.status == "failed" else "done")
        if run["kind"] == "init" and body.status != "failed" and run["repository_id"]:
            await conn.execute(
                """UPDATE repositories SET initialized_at = coalesce(initialized_at, now()),
                       recovery_key_at = CASE WHEN $2 THEN now() ELSE recovery_key_at END WHERE id = $1""",
                run["repository_id"], bool(body.summary.get("recovery_key_added")))
        if run["kind"] in HEAVY_KINDS and body.status in ("failed", "warning"):
            job = await conn.fetchval("SELECT name FROM jobs WHERE id = $1", run["job_id"]) if run["job_id"] else None
            what = job or run["kind"]
            await conn.execute(
                """INSERT INTO notifications (agent_id, level, title, body, run_id)
                   VALUES ($1, $2, $3, $4, $5)""",
                agent["id"], "error" if body.status == "failed" else "warning",
                f"{what}: {'falhou' if body.status == 'failed' else 'terminou com avisos'}",
                body.error or "; ".join(body.summary.get("warnings", []))[:2000], run_id)
    return {"status": "ok"}


# ── Snapshots e alertas ───────────────────────────────────────────────

class Snapshot(BaseModel):
    id: str = Field(max_length=100)
    short_id: str = Field(max_length=20)
    time: datetime
    hostname: str = ""
    paths: list[str] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)
    summary: dict = Field(default_factory=dict)


class SnapshotList(BaseModel):
    repository_id: UUID
    snapshots: list[Snapshot]


@router.post("/snapshots")
async def put_snapshots(body: SnapshotList, request: Request, agent=Depends(current_agent)):
    db = pool(request)
    owner = await db.fetchval(
        """SELECT d.agent_id FROM repositories r JOIN datasets d ON d.id = r.dataset_id WHERE r.id = $1""",
        body.repository_id)
    if owner != agent["id"]:
        raise HTTPException(404, "Repositório desconhecido.")
    async with db.acquire() as conn, conn.transaction():
        await conn.execute("DELETE FROM snapshots WHERE repository_id = $1", body.repository_id)
        await conn.executemany(
            """INSERT INTO snapshots (repository_id, snapshot_id, short_id, time, hostname, paths, tags, summary)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
            [(body.repository_id, s.id, s.short_id, s.time, s.hostname, s.paths, s.tags, s.summary)
             for s in body.snapshots])
        await conn.execute("UPDATE repositories SET initialized_at = coalesce(initialized_at, now()) WHERE id = $1",
                           body.repository_id)
    return {"status": "ok"}


class Notify(BaseModel):
    level: str = Field(pattern=r"^(info|warning|error)$")
    title: str = Field(max_length=200)
    body: str = Field(default="", max_length=4000)
    run_id: UUID | None = None


@router.post("/notify")
async def notify(body: Notify, request: Request, agent=Depends(current_agent)):
    db = pool(request)
    run_id = body.run_id if body.run_id and await db.fetchval("SELECT 1 FROM runs WHERE id = $1", body.run_id) else None
    await db.execute(
        "INSERT INTO notifications (agent_id, level, title, body, run_id) VALUES ($1, $2, $3, $4, $5)",
        agent["id"], body.level, body.title, body.body, run_id)
    return {"status": "ok"}
