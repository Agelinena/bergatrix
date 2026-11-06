"""Rotas da interface (/api). Toda mudança na configuração publica uma revisão
nova do plano (plan.publish) e fica no registro de auditoria.

Segredos: a web nunca recebe nem devolve um segredo em texto. O navegador
cifra o valor com a chave pública do agente e manda só o texto cifrado. As
respostas dizem apenas se o segredo está definido (has_secret)."""

from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta, timezone
from posixpath import normpath
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator

from bergakup import plan
from bergakup.auth import User, current_user, token_hash

router = APIRouter(prefix="/api")

CRON = re.compile(r"^(@(hourly|daily|weekly|monthly)|(\S+\s+){4}\S+)$")
SEALED = re.compile(r"^[A-Za-z0-9+/=]{60,8000}$")
COMMAND_KINDS = {"backup", "forget", "prune", "check", "snapshots", "ls", "restore", "import_dumps",
                 "discover", "test", "unlock"}


def pool(request: Request):
    return request.app.state.pool


def iso(value):
    return value.isoformat() if value else None


async def audit(conn, user: User, action: str, detail: dict | None = None):
    await conn.execute("INSERT INTO audit_log (user_id, action, detail) VALUES ($1, $2, $3)",
                       user.id, action, detail or {})


def check_sealed(value: str | None) -> str | None:
    if value is not None and value != "" and not SEALED.match(value):
        raise HTTPException(422, "Segredo precisa vir cifrado pelo navegador.")
    return value


def check_path(value: str) -> str:
    value = value.strip()
    if not value.startswith("/") or "\0" in value:
        raise HTTPException(422, f"Caminho precisa ser absoluto: {value!r}")
    return normpath(value) if "*" not in value else value


async def agent_of(conn, table: str, row_id) -> UUID:
    queries = {
        "storages": "SELECT agent_id FROM storages WHERE id = $1",
        "datasets": "SELECT agent_id FROM datasets WHERE id = $1",
        "repositories": "SELECT d.agent_id FROM repositories r JOIN datasets d ON d.id = r.dataset_id WHERE r.id = $1",
        "jobs": """SELECT d.agent_id FROM jobs j JOIN repositories r ON r.id = j.repository_id
                   JOIN datasets d ON d.id = r.dataset_id WHERE j.id = $1""",
    }
    agent_id = await conn.fetchval(queries[table], row_id)
    if agent_id is None:
        raise HTTPException(404, "Não encontrado.")
    return agent_id


async def require_agent(conn, agent_id) -> None:
    if not await conn.fetchval("SELECT 1 FROM agents WHERE id = $1", agent_id):
        raise HTTPException(404, "Agente não encontrado.")


# ── Conta e visão geral ───────────────────────────────────────────────

@router.get("/me")
async def me(user: User = Depends(current_user)):
    return {"username": user.username, "name": user.name, "email": user.email}


def agent_public(row, latest: int | None, stale_minutes: int) -> dict:
    seen = row["last_seen_at"]
    online = bool(seen and seen > datetime.now(timezone.utc) - timedelta(minutes=stale_minutes))
    return {
        "id": str(row["id"]), "name": row["name"], "hostname": row["hostname"], "version": row["version"],
        "public_key": row["public_key"], "applied_revision": row["applied_revision"],
        "latest_revision": latest or 0, "apply_error": row["apply_error"], "last_seen_at": iso(seen),
        "online": online, "created_at": iso(row["created_at"]),
    }


@router.get("/agents")
async def list_agents(request: Request, user: User = Depends(current_user)):
    rows = await pool(request).fetch(
        """SELECT a.*, (SELECT max(revision) FROM config_revisions c WHERE c.agent_id = a.id) AS latest
           FROM agents a ORDER BY a.name""")
    stale = request.app.state.settings.agent_stale_minutes
    return [agent_public(r, r["latest"], stale) for r in rows]


@router.get("/overview")
async def overview(request: Request, user: User = Depends(current_user)):
    db = pool(request)
    jobs = await db.fetch(
        """SELECT j.id, j.name, j.enabled, j.schedule, j.stale_hours, d.id AS dataset_id, d.name AS dataset,
                  d.kind AS dataset_kind, s.name AS storage, s.kind AS storage_kind, d.agent_id,
                  (SELECT row_to_json(x)::jsonb FROM (SELECT id, status, started_at, finished_at, summary, error
                     FROM runs WHERE job_id = j.id AND kind = 'backup' ORDER BY started_at DESC LIMIT 1) x) AS last_run,
                  (SELECT max(finished_at) FROM runs WHERE job_id = j.id AND kind = 'backup'
                     AND status IN ('success', 'warning')) AS last_success,
                  (SELECT count(*) FROM snapshots WHERE repository_id = r.id) AS snapshots
           FROM jobs j JOIN repositories r ON r.id = j.repository_id JOIN datasets d ON d.id = r.dataset_id
           JOIN storages s ON s.id = r.storage_id ORDER BY d.slug, s.name""")
    recent = await db.fetch(
        """SELECT r.id, r.kind, r.status, r.started_at, r.finished_at, r.trigger, j.name AS job
           FROM runs r LEFT JOIN jobs j ON j.id = r.job_id
           WHERE r.kind IN ('backup', 'forget', 'prune', 'check', 'restore', 'import_dumps', 'init')
           ORDER BY r.started_at DESC LIMIT 15""")
    unread = await db.fetchval("SELECT count(*) FROM notifications WHERE read_at IS NULL")
    now = datetime.now(timezone.utc)
    return {
        "jobs": [{
            "id": str(j["id"]), "name": j["name"], "enabled": j["enabled"], "schedule": j["schedule"],
            "dataset_id": str(j["dataset_id"]), "dataset": j["dataset"], "dataset_kind": j["dataset_kind"],
            "storage": j["storage"], "storage_kind": j["storage_kind"], "agent_id": str(j["agent_id"]),
            "last_run": j["last_run"], "last_success": iso(j["last_success"]), "snapshots": j["snapshots"],
            "late": bool(j["enabled"] and (j["last_success"] is None or
                                           j["last_success"] < now - timedelta(hours=j["stale_hours"]))),
        } for j in jobs],
        "recent_runs": [{**dict(r), "id": str(r["id"]), "started_at": iso(r["started_at"]),
                         "finished_at": iso(r["finished_at"])} for r in recent],
        "unread_notifications": unread,
    }


# ── Agentes ───────────────────────────────────────────────────────────

@router.post("/agents/enrollment-code")
async def enrollment_code(request: Request, user: User = Depends(current_user)):
    code = "bkc_" + secrets.token_urlsafe(18)
    async with pool(request).acquire() as conn, conn.transaction():
        await conn.execute(
            """INSERT INTO enrollment_codes (code_hash, created_by, expires_at)
               VALUES ($1, $2, now() + interval '1 hour')""", token_hash(code), user.id)
        await audit(conn, user, "agent.enrollment_code")
    return {"code": code, "expires_in_minutes": 60}


@router.delete("/agents/{agent_id}")
async def delete_agent(agent_id: UUID, request: Request, user: User = Depends(current_user)):
    async with pool(request).acquire() as conn, conn.transaction():
        name = await conn.fetchval("DELETE FROM agents WHERE id = $1 RETURNING name", agent_id)
        if name is None:
            raise HTTPException(404, "Agente não encontrado.")
        await audit(conn, user, "agent.delete", {"agent": name})
    return {"status": "ok"}


@router.get("/agents/{agent_id}/discovery")
async def discovery(agent_id: UUID, request: Request, user: User = Depends(current_user)):
    db = pool(request)
    info = await db.fetchval("SELECT info FROM agents WHERE id = $1", agent_id)
    if info is None:
        raise HTTPException(404, "Agente não encontrado.")
    policies = await db.fetch("SELECT stack, mode FROM stack_policies WHERE agent_id = $1", agent_id)
    return {"info": info, "policies": {p["stack"]: p["mode"] for p in policies}}


class Policies(BaseModel):
    policies: dict[str, Literal["hot", "stop", "pause", "skip"]]


@router.put("/agents/{agent_id}/policies")
async def put_policies(agent_id: UUID, body: Policies, request: Request, user: User = Depends(current_user)):
    for stack in body.policies:
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$", stack):
            raise HTTPException(422, f"Nome de stack inválido: {stack}")
    async with pool(request).acquire() as conn, conn.transaction():
        await require_agent(conn, agent_id)
        await conn.execute("DELETE FROM stack_policies WHERE agent_id = $1", agent_id)
        await conn.executemany(
            "INSERT INTO stack_policies (agent_id, stack, mode) VALUES ($1, $2, $3)",
            [(agent_id, stack, mode) for stack, mode in body.policies.items() if mode != "hot"])
        await audit(conn, user, "policies.update", {"policies": body.policies})
        revision = await plan.publish(conn, agent_id, user.id)
    return {"revision": revision}


class Smtp(BaseModel):
    host: str = Field(default="", max_length=200)
    port: int = Field(default=587, ge=1, le=65535)
    username: str = Field(default="", max_length=200)
    sender: str = Field(default="", max_length=200)
    to: list[str] = Field(default_factory=list, max_length=10)
    security: Literal["starttls", "tls", "none"] = "starttls"


class AgentSettings(BaseModel):
    timezone: str = Field(max_length=60)
    repo_root: str = Field(max_length=500)
    stacks_file: str = Field(max_length=500)
    dumps_dir: str = Field(max_length=500)
    smtp: Smtp
    # Cifrado pelo navegador. None = manter; "" = apagar.
    smtp_password: str | None = None


@router.get("/agents/{agent_id}/settings")
async def get_settings(agent_id: UUID, request: Request, user: User = Depends(current_user)):
    row = await pool(request).fetchrow("SELECT * FROM agent_settings WHERE agent_id = $1", agent_id)
    if row is None:
        raise HTTPException(404, "Agente não encontrado.")
    return {"timezone": row["timezone"], "repo_root": row["repo_root"], "stacks_file": row["stacks_file"],
            "dumps_dir": row["dumps_dir"], "smtp": Smtp(**(row["smtp"] or {})).model_dump(),
            "has_smtp_password": bool(row["smtp_password_sealed"])}


@router.put("/agents/{agent_id}/settings")
async def put_settings(agent_id: UUID, body: AgentSettings, request: Request, user: User = Depends(current_user)):
    for path in (body.repo_root, body.stacks_file, body.dumps_dir):
        if path:
            check_path(path)
    check_sealed(body.smtp_password)
    async with pool(request).acquire() as conn, conn.transaction():
        await require_agent(conn, agent_id)
        await conn.execute(
            """UPDATE agent_settings SET timezone = $2, repo_root = $3, stacks_file = $4, dumps_dir = $5,
                   smtp = $6, updated_at = now(),
                   smtp_password_sealed = CASE WHEN $7::text IS NULL THEN smtp_password_sealed
                                               ELSE nullif($7::text, '') END
               WHERE agent_id = $1""",
            agent_id, body.timezone, body.repo_root.rstrip("/"), body.stacks_file, body.dumps_dir,
            body.smtp.model_dump(), body.smtp_password)
        await audit(conn, user, "settings.update", {"smtp_password_changed": body.smtp_password is not None})
        revision = await plan.publish(conn, agent_id, user.id)
    return {"revision": revision}


# ── Destinos ──────────────────────────────────────────────────────────

class StorageIn(BaseModel):
    agent_id: UUID
    name: str = Field(min_length=1, max_length=60)
    kind: Literal["b2", "local", "rest", "sftp"]
    endpoint: str = Field(default="", max_length=300)
    region: str = Field(default="", max_length=60)
    bucket: str = Field(default="", max_length=63)
    path: str = Field(default="", max_length=500)
    username: str = Field(default="", max_length=200)
    lock_days: int = Field(default=0, ge=0, le=3650)
    secret: str | None = None   # cifrado; None = manter; "" = apagar

    def validate_kind(self) -> None:
        if self.kind == "b2" and not (self.endpoint and self.bucket and self.username):
            raise HTTPException(422, "B2 precisa de endpoint S3, bucket e Key ID.")
        if self.kind == "b2" and not re.match(r"^[a-z0-9][a-z0-9-]{5,62}$", self.bucket):
            raise HTTPException(422, "Nome de bucket inválido.")
        if self.kind == "local":
            check_path(self.path)
        if self.kind in ("rest", "sftp") and not self.endpoint:
            raise HTTPException(422, "Informe o endereço do servidor.")


def storage_public(row) -> dict:
    return {"id": str(row["id"]), "agent_id": str(row["agent_id"]), "name": row["name"], "kind": row["kind"],
            "endpoint": row["endpoint"], "region": row["region"], "bucket": row["bucket"], "path": row["path"],
            "username": row["username"], "lock_days": row["lock_days"], "has_secret": bool(row["secret_sealed"])}


@router.get("/storages")
async def list_storages(request: Request, agent_id: UUID, user: User = Depends(current_user)):
    rows = await pool(request).fetch("SELECT * FROM storages WHERE agent_id = $1 ORDER BY name", agent_id)
    return [storage_public(r) for r in rows]


@router.post("/storages")
async def create_storage(body: StorageIn, request: Request, user: User = Depends(current_user)):
    body.validate_kind()
    check_sealed(body.secret)
    async with pool(request).acquire() as conn, conn.transaction():
        await require_agent(conn, body.agent_id)
        row = await conn.fetchrow(
            """INSERT INTO storages (agent_id, name, kind, endpoint, region, bucket, path, username, lock_days,
                                     secret_sealed)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, nullif($10, '')) RETURNING *""",
            body.agent_id, body.name, body.kind, body.endpoint, body.region, body.bucket, body.path,
            body.username, body.lock_days, body.secret or "")
        await audit(conn, user, "storage.create", {"name": body.name, "kind": body.kind})
        await plan.publish(conn, body.agent_id, user.id)
    return storage_public(row)


@router.put("/storages/{storage_id}")
async def update_storage(storage_id: UUID, body: StorageIn, request: Request, user: User = Depends(current_user)):
    body.validate_kind()
    check_sealed(body.secret)
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "storages", storage_id)
        row = await conn.fetchrow(
            """UPDATE storages SET name = $2, kind = $3, endpoint = $4, region = $5, bucket = $6, path = $7,
                   username = $8, lock_days = $9, updated_at = now(),
                   secret_sealed = CASE WHEN $10::text IS NULL THEN secret_sealed ELSE nullif($10::text, '') END
               WHERE id = $1 RETURNING *""",
            storage_id, body.name, body.kind, body.endpoint, body.region, body.bucket, body.path,
            body.username, body.lock_days, body.secret)
        await audit(conn, user, "storage.update", {"name": body.name, "secret_changed": body.secret is not None})
        await plan.publish(conn, agent_id, user.id)
    return storage_public(row)


@router.delete("/storages/{storage_id}")
async def delete_storage(storage_id: UUID, request: Request, user: User = Depends(current_user)):
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "storages", storage_id)
        if await conn.fetchval("SELECT 1 FROM repositories WHERE storage_id = $1 LIMIT 1", storage_id):
            raise HTTPException(409, "Há repositórios neste destino. Remova-os antes.")
        name = await conn.fetchval("DELETE FROM storages WHERE id = $1 RETURNING name", storage_id)
        await audit(conn, user, "storage.delete", {"name": name})
        await plan.publish(conn, agent_id, user.id)
    return {"status": "ok"}


# ── Conjuntos ─────────────────────────────────────────────────────────

class DatasetIn(BaseModel):
    agent_id: UUID
    slug: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{0,39}$")
    name: str = Field(min_length=1, max_length=100)
    kind: Literal["userdata", "docker", "servidor", "custom"] = "custom"
    paths: list[str] = Field(min_length=1, max_length=50)
    excludes: list[str] = Field(default_factory=list, max_length=200)
    consistency: Literal["none", "policies", "cold"] = "none"

    @field_validator("excludes")
    @classmethod
    def clean_excludes(cls, value: list[str]) -> list[str]:
        return [v.strip() for v in value if v.strip()]


def dataset_public(row) -> dict:
    return {"id": str(row["id"]), "agent_id": str(row["agent_id"]), "slug": row["slug"], "name": row["name"],
            "kind": row["kind"], "paths": list(row["paths"]), "excludes": list(row["excludes"]),
            "consistency": row["consistency"]}


@router.get("/datasets")
async def list_datasets(request: Request, agent_id: UUID, user: User = Depends(current_user)):
    rows = await pool(request).fetch("SELECT * FROM datasets WHERE agent_id = $1 ORDER BY slug", agent_id)
    return [dataset_public(r) for r in rows]


@router.post("/datasets")
async def create_dataset(body: DatasetIn, request: Request, user: User = Depends(current_user)):
    paths = [check_path(p) for p in body.paths]
    async with pool(request).acquire() as conn, conn.transaction():
        await require_agent(conn, body.agent_id)
        row = await conn.fetchrow(
            """INSERT INTO datasets (agent_id, slug, name, kind, paths, excludes, consistency)
               VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *""",
            body.agent_id, body.slug, body.name, body.kind, paths, body.excludes, body.consistency)
        await audit(conn, user, "dataset.create", {"slug": body.slug})
        await plan.publish(conn, body.agent_id, user.id)
    return dataset_public(row)


@router.put("/datasets/{dataset_id}")
async def update_dataset(dataset_id: UUID, body: DatasetIn, request: Request, user: User = Depends(current_user)):
    paths = [check_path(p) for p in body.paths]
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "datasets", dataset_id)
        # O slug faz parte do caminho do repositório e das tags dos snapshots: não muda.
        row = await conn.fetchrow(
            """UPDATE datasets SET name = $2, paths = $3, excludes = $4, consistency = $5, updated_at = now()
               WHERE id = $1 RETURNING *""", dataset_id, body.name, paths, body.excludes, body.consistency)
        await audit(conn, user, "dataset.update", {"slug": row["slug"], "paths": paths, "excludes": body.excludes,
                                                   "consistency": body.consistency})
        await plan.publish(conn, agent_id, user.id)
    return dataset_public(row)


@router.delete("/datasets/{dataset_id}")
async def delete_dataset(dataset_id: UUID, request: Request, user: User = Depends(current_user)):
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "datasets", dataset_id)
        slug = await conn.fetchval("DELETE FROM datasets WHERE id = $1 RETURNING slug", dataset_id)
        await audit(conn, user, "dataset.delete", {"slug": slug})
        await plan.publish(conn, agent_id, user.id)
    return {"status": "ok"}


# ── Repositórios ──────────────────────────────────────────────────────

class RepositoryIn(BaseModel):
    dataset_id: UUID
    storage_id: UUID
    subpath: str = Field(default="", max_length=200)
    password: str | None = None


class RepositoryPassword(BaseModel):
    password: str


class RepositoryInit(BaseModel):
    # Senha de recuperação gerada no navegador, cifrada para o agente. Vira uma
    # segunda chave do repositório (restic key add) e só existe no kit impresso.
    recovery: str


async def repository_rows(conn, agent_id):
    return await conn.fetch(
        """SELECT r.*, d.slug, d.name AS dataset_name, s.name AS storage_name, s.kind AS storage_kind,
                  s.endpoint, s.region, s.bucket, s.path, s.username, s.lock_days,
                  (SELECT count(*) FROM snapshots x WHERE x.repository_id = r.id) AS snapshot_count,
                  (SELECT max(time) FROM snapshots x WHERE x.repository_id = r.id) AS last_snapshot
           FROM repositories r JOIN datasets d ON d.id = r.dataset_id JOIN storages s ON s.id = r.storage_id
           WHERE d.agent_id = $1 ORDER BY d.slug, s.name""", agent_id)


def repository_public(row) -> dict:
    storage = {k: row[k] for k in ("endpoint", "region", "bucket", "path", "username")} | {"kind": row["storage_kind"]}
    return {"id": str(row["id"]), "dataset_id": str(row["dataset_id"]), "storage_id": str(row["storage_id"]),
            "dataset_slug": row["slug"], "dataset_name": row["dataset_name"], "storage_name": row["storage_name"],
            "storage_kind": row["storage_kind"], "lock_days": row["lock_days"], "subpath": row["subpath"],
            "url": plan.repository_url(storage, row["subpath"]), "has_password": bool(row["password_sealed"]),
            "initialized_at": iso(row["initialized_at"]), "recovery_key_at": iso(row["recovery_key_at"]),
            "snapshot_count": row["snapshot_count"], "last_snapshot": iso(row["last_snapshot"])}


@router.get("/repositories")
async def list_repositories(request: Request, agent_id: UUID, user: User = Depends(current_user)):
    async with pool(request).acquire() as conn:
        return [repository_public(r) for r in await repository_rows(conn, agent_id)]


@router.post("/repositories")
async def create_repository(body: RepositoryIn, request: Request, user: User = Depends(current_user)):
    check_sealed(body.password)
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "datasets", body.dataset_id)
        if await agent_of(conn, "storages", body.storage_id) != agent_id:
            raise HTTPException(422, "Destino e conjunto são de agentes diferentes.")
        slug = await conn.fetchval("SELECT slug FROM datasets WHERE id = $1", body.dataset_id)
        subpath = body.subpath.strip("/") or slug
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,199}$", subpath) or ".." in subpath:
            raise HTTPException(422, "Subcaminho inválido.")
        repo_id = await conn.fetchval(
            """INSERT INTO repositories (dataset_id, storage_id, subpath, password_sealed)
               VALUES ($1, $2, $3, nullif($4, '')) RETURNING id""",
            body.dataset_id, body.storage_id, subpath, body.password or "")
        await audit(conn, user, "repository.create", {"subpath": subpath})
        await plan.publish(conn, agent_id, user.id)
        rows = await repository_rows(conn, agent_id)
    return next(repository_public(r) for r in rows if r["id"] == repo_id)


@router.put("/repositories/{repo_id}/password")
async def set_repository_password(repo_id: UUID, body: RepositoryPassword, request: Request,
                                  user: User = Depends(current_user)):
    check_sealed(body.password)
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "repositories", repo_id)
        await conn.execute("UPDATE repositories SET password_sealed = nullif($2, '') WHERE id = $1",
                           repo_id, body.password)
        await audit(conn, user, "repository.password", {"repository": str(repo_id)})
        revision = await plan.publish(conn, agent_id, user.id)
    return {"revision": revision}


@router.post("/repositories/{repo_id}/init")
async def init_repository(repo_id: UUID, body: RepositoryInit, request: Request, user: User = Depends(current_user)):
    check_sealed(body.recovery)
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "repositories", repo_id)
        if not await conn.fetchval("SELECT password_sealed IS NOT NULL FROM repositories WHERE id = $1", repo_id):
            raise HTTPException(409, "Defina a senha do repositório antes.")
        command_id = await conn.fetchval(
            "INSERT INTO commands (agent_id, kind, params, created_by) VALUES ($1, 'init', $2, $3) RETURNING id",
            agent_id, {"repository_id": str(repo_id), "recovery": body.recovery}, user.id)
        await audit(conn, user, "repository.init", {"repository": str(repo_id)})
    return {"id": str(command_id)}


@router.delete("/repositories/{repo_id}")
async def delete_repository(repo_id: UUID, request: Request, user: User = Depends(current_user)):
    """Só tira da configuração. Os dados no destino continuam lá."""
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "repositories", repo_id)
        subpath = await conn.fetchval("DELETE FROM repositories WHERE id = $1 RETURNING subpath", repo_id)
        await audit(conn, user, "repository.delete", {"subpath": subpath})
        await plan.publish(conn, agent_id, user.id)
    return {"status": "ok"}


@router.get("/repositories/{repo_id}/snapshots")
async def list_snapshots(repo_id: UUID, request: Request, user: User = Depends(current_user)):
    rows = await pool(request).fetch(
        "SELECT * FROM snapshots WHERE repository_id = $1 ORDER BY time DESC", repo_id)
    return [{"id": r["snapshot_id"], "short_id": r["short_id"], "time": iso(r["time"]), "hostname": r["hostname"],
             "paths": list(r["paths"]), "tags": list(r["tags"]), "summary": r["summary"]} for r in rows]


# ── Tarefas ───────────────────────────────────────────────────────────

class Retention(BaseModel):
    last: int = Field(default=0, ge=0, le=1000)
    daily: int = Field(default=0, ge=0, le=1000)
    weekly: int = Field(default=0, ge=0, le=1000)
    monthly: int = Field(default=0, ge=0, le=1000)


class JobIn(BaseModel):
    repository_id: UUID
    name: str = Field(min_length=1, max_length=100)
    enabled: bool = True
    schedule: str = "0 3 * * *"
    retention: Retention
    prune_schedule: str = ""
    check_schedule: str = ""
    check_subset: str = Field(default="5%", pattern=r"^(\d{1,3}(\.\d+)?%|\d+/\d+|\d+[KMGT]?)$")
    anomaly_pct: float = Field(default=30, ge=0, le=100)
    stale_hours: int = Field(default=26, ge=1, le=24 * 60)
    ping_url: str = Field(default="", max_length=500)

    def validate_job(self) -> None:
        for field in ("schedule", "prune_schedule", "check_schedule"):
            value = getattr(self, field).strip()
            if value and not CRON.match(value):
                raise HTTPException(422, f"Agenda inválida em {field}: use o formato do cron (5 campos).")
        if not self.schedule.strip():
            raise HTTPException(422, "A tarefa precisa de uma agenda.")
        if not any(self.retention.model_dump().values()):
            raise HTTPException(422, "Defina ao menos uma regra de retenção.")
        if self.ping_url and not self.ping_url.startswith("https://"):
            raise HTTPException(422, "O endereço de ping precisa ser https://.")


def job_public(row) -> dict:
    return {"id": str(row["id"]), "repository_id": str(row["repository_id"]), "name": row["name"],
            "enabled": row["enabled"], "schedule": row["schedule"], "retention": row["retention"],
            "prune_schedule": row["prune_schedule"], "check_schedule": row["check_schedule"],
            "check_subset": row["check_subset"], "anomaly_pct": row["anomaly_pct"],
            "stale_hours": row["stale_hours"], "ping_url": row["ping_url"]}


@router.get("/jobs")
async def list_jobs(request: Request, agent_id: UUID, user: User = Depends(current_user)):
    rows = await pool(request).fetch(
        """SELECT j.* FROM jobs j JOIN repositories r ON r.id = j.repository_id
           JOIN datasets d ON d.id = r.dataset_id WHERE d.agent_id = $1 ORDER BY j.name""", agent_id)
    return [job_public(r) for r in rows]


JOB_COLUMNS = ("name", "enabled", "schedule", "retention", "prune_schedule", "check_schedule", "check_subset",
               "anomaly_pct", "stale_hours", "ping_url")


def job_values(body: JobIn) -> list:
    data = body.model_dump()
    data["retention"] = {k: v for k, v in body.retention.model_dump().items() if v}
    return [data[c].strip() if isinstance(data[c], str) else data[c] for c in JOB_COLUMNS]


@router.post("/jobs")
async def create_job(body: JobIn, request: Request, user: User = Depends(current_user)):
    body.validate_job()
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "repositories", body.repository_id)
        row = await conn.fetchrow(
            f"""INSERT INTO jobs (repository_id, {', '.join(JOB_COLUMNS)})
                VALUES ($1, {', '.join(f'${i + 2}' for i in range(len(JOB_COLUMNS)))}) RETURNING *""",
            body.repository_id, *job_values(body))
        await audit(conn, user, "job.create", {"name": body.name})
        await plan.publish(conn, agent_id, user.id)
    return job_public(row)


@router.put("/jobs/{job_id}")
async def update_job(job_id: UUID, body: JobIn, request: Request, user: User = Depends(current_user)):
    body.validate_job()
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "jobs", job_id)
        sets = ", ".join(f"{c} = ${i + 2}" for i, c in enumerate(JOB_COLUMNS))
        row = await conn.fetchrow(f"UPDATE jobs SET {sets}, updated_at = now() WHERE id = $1 RETURNING *",
                                  job_id, *job_values(body))
        await audit(conn, user, "job.update", {"name": body.name, "retention": row["retention"],
                                               "schedule": body.schedule, "enabled": body.enabled})
        await plan.publish(conn, agent_id, user.id)
    return job_public(row)


@router.delete("/jobs/{job_id}")
async def delete_job(job_id: UUID, request: Request, user: User = Depends(current_user)):
    async with pool(request).acquire() as conn, conn.transaction():
        agent_id = await agent_of(conn, "jobs", job_id)
        name = await conn.fetchval("DELETE FROM jobs WHERE id = $1 RETURNING name", job_id)
        await audit(conn, user, "job.delete", {"name": name})
        await plan.publish(conn, agent_id, user.id)
    return {"status": "ok"}


# ── Comandos (rodar agora, restaurar, navegar...) ─────────────────────

class CommandIn(BaseModel):
    agent_id: UUID
    kind: str
    params: dict = Field(default_factory=dict)


@router.post("/commands")
async def create_command(body: CommandIn, request: Request, user: User = Depends(current_user)):
    if body.kind not in COMMAND_KINDS:
        raise HTTPException(422, "Comando desconhecido.")
    params = body.params
    async with pool(request).acquire() as conn, conn.transaction():
        await require_agent(conn, body.agent_id)
        for key, table in (("job_id", "jobs"), ("repository_id", "repositories")):
            if key not in params:
                continue
            try:
                ref = UUID(str(params[key]))
            except ValueError:
                raise HTTPException(422, f"{key} inválido.")
            if await agent_of(conn, table, ref) != body.agent_id:
                raise HTTPException(422, "Referência de outro agente.")
        if body.kind == "restore":
            target = str(params.get("target") or "")
            if target and not target.startswith("/"):
                raise HTTPException(422, "Destino da restauração precisa ser absoluto.")
            if not re.match(r"^[0-9a-f]{8,64}$|^latest$", str(params.get("snapshot_id", ""))):
                raise HTTPException(422, "Snapshot inválido.")
        command_id = await conn.fetchval(
            "INSERT INTO commands (agent_id, kind, params, created_by) VALUES ($1, $2, $3, $4) RETURNING id",
            body.agent_id, body.kind, params, user.id)
        if body.kind not in ("ls", "snapshots", "discover", "test"):
            await audit(conn, user, f"command.{body.kind}", params)
    return {"id": str(command_id)}


@router.get("/commands/{command_id}")
async def get_command(command_id: UUID, request: Request, user: User = Depends(current_user)):
    row = await pool(request).fetchrow(
        """SELECT c.id, c.kind, c.status, c.run_id, c.created_at, r.status AS run_status, r.summary, r.error
           FROM commands c LEFT JOIN runs r ON r.id = c.run_id WHERE c.id = $1""", command_id)
    if row is None:
        raise HTTPException(404, "Comando não encontrado.")
    return {"id": str(row["id"]), "kind": row["kind"], "status": row["status"],
            "run_id": str(row["run_id"]) if row["run_id"] else None, "run_status": row["run_status"],
            "summary": row["summary"], "error": row["error"], "created_at": iso(row["created_at"])}


# ── Execuções ─────────────────────────────────────────────────────────

def run_public(row) -> dict:
    return {"id": str(row["id"]), "kind": row["kind"], "status": row["status"], "trigger": row["trigger"],
            "job_id": str(row["job_id"]) if row["job_id"] else None, "job": row["job"],
            "repository_id": str(row["repository_id"]) if row["repository_id"] else None,
            "started_at": iso(row["started_at"]), "finished_at": iso(row["finished_at"]),
            "summary": row["summary"], "error": row["error"]}


@router.get("/runs")
async def list_runs(request: Request, user: User = Depends(current_user), job_id: UUID | None = None,
                    status: str | None = None, include_light: bool = False,
                    limit: int = Query(default=50, ge=1, le=500)):
    rows = await pool(request).fetch(
        """SELECT r.*, j.name AS job FROM runs r LEFT JOIN jobs j ON j.id = r.job_id
           WHERE ($1::uuid IS NULL OR r.job_id = $1) AND ($2::text IS NULL OR r.status = $2)
             AND ($3 OR r.kind NOT IN ('ls', 'snapshots', 'discover', 'test'))
           ORDER BY r.started_at DESC LIMIT $4""", job_id, status, include_light, limit)
    return [run_public(r) for r in rows]


@router.get("/runs/{run_id}")
async def get_run(run_id: UUID, request: Request, user: User = Depends(current_user)):
    row = await pool(request).fetchrow(
        "SELECT r.*, j.name AS job FROM runs r LEFT JOIN jobs j ON j.id = r.job_id WHERE r.id = $1", run_id)
    if row is None:
        raise HTTPException(404, "Execução não encontrada.")
    return run_public(row)


@router.get("/runs/{run_id}/logs")
async def get_run_logs(run_id: UUID, request: Request, after: int = -1, user: User = Depends(current_user)):
    rows = await pool(request).fetch(
        "SELECT seq, ts, level, line FROM run_logs WHERE run_id = $1 AND seq > $2 ORDER BY seq LIMIT 2000",
        run_id, after)
    return [{"seq": r["seq"], "ts": iso(r["ts"]), "level": r["level"], "line": r["line"]} for r in rows]


# ── Alertas, auditoria e kit ──────────────────────────────────────────

@router.get("/notifications")
async def list_notifications(request: Request, user: User = Depends(current_user)):
    rows = await pool(request).fetch("SELECT * FROM notifications ORDER BY created_at DESC LIMIT 200")
    return [{"id": str(r["id"]), "level": r["level"], "title": r["title"], "body": r["body"],
             "run_id": str(r["run_id"]) if r["run_id"] else None, "created_at": iso(r["created_at"]),
             "read": r["read_at"] is not None} for r in rows]


@router.post("/notifications/read")
async def read_notifications(request: Request, user: User = Depends(current_user)):
    await pool(request).execute("UPDATE notifications SET read_at = now() WHERE read_at IS NULL")
    return {"status": "ok"}


@router.get("/audit")
async def list_audit(request: Request, user: User = Depends(current_user)):
    rows = await pool(request).fetch(
        """SELECT a.ts, a.action, a.detail, u.username FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
           ORDER BY a.id DESC LIMIT 300""")
    return [{"ts": iso(r["ts"]), "action": r["action"], "detail": r["detail"], "username": r["username"]}
            for r in rows]


@router.get("/kit")
async def recovery_kit(request: Request, agent_id: UUID, user: User = Depends(current_user)):
    """Tudo o que o kit de recuperação impresso precisa, sem nenhum segredo."""
    async with pool(request).acquire() as conn:
        agent = await conn.fetchrow("SELECT name, hostname FROM agents WHERE id = $1", agent_id)
        if agent is None:
            raise HTTPException(404, "Agente não encontrado.")
        settings_row = await conn.fetchrow("SELECT repo_root, dumps_dir FROM agent_settings WHERE agent_id = $1",
                                           agent_id)
        repos = await repository_rows(conn, agent_id)
        datasets = await conn.fetch("SELECT slug, name, paths FROM datasets WHERE agent_id = $1 ORDER BY slug",
                                    agent_id)
        await audit(conn, user, "kit.view")
    return {
        "agent": dict(agent), "repo_root": settings_row["repo_root"], "dumps_dir": settings_row["dumps_dir"],
        "datasets": [{"slug": d["slug"], "name": d["name"], "paths": list(d["paths"])} for d in datasets],
        "repositories": [repository_public(r) | {"region": r["region"], "endpoint": r["endpoint"],
                                                 "bucket": r["bucket"], "username": r["username"]} for r in repos],
    }
