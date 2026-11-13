"""O plano: a configuração inteira de um agente num documento JSON.

A web edita tabelas; a cada mudança, `publish` monta o documento e, se ele
mudou, grava uma revisão nova. O agente baixa a revisão mais nova, valida,
aplica e guarda uma cópia local, então ele segue funcionando com a web fora.

Os segredos vão como estão no banco: cifrados para a chave pública do agente.
"""

from __future__ import annotations

import hashlib
import json
from posixpath import join as pjoin

# Conjuntos criados quando um agente se registra. Os três dados principais.
DEFAULT_DATASETS = (
    {
        "slug": "userdata", "kind": "userdata", "name": "NAS: dados das pessoas",
        "paths": ["/mnt/nas/userdata"],
        "excludes": [
            # Recriáveis: o Immich e o Nextcloud refazem sozinhos.
            "/mnt/nas/userdata/immich/thumbs",
            "/mnt/nas/userdata/immich/encoded-video",
            "/mnt/nas/userdata/nextcloud/data/appdata_*/preview",
        ],
        "consistency": "none",
    },
    {
        "slug": "docker", "kind": "docker", "name": "Docker: repositório, composes e .env",
        # /etc/bergakup: identidade do agente (as chaves que abrem os segredos da web).
        # /var/lib/bergakup: plano aplicado e estado das tarefas.
        "paths": ["{repo_root}", "/etc/bergakup", "/var/lib/bergakup"],
        "excludes": ["**/node_modules", "**/.venv", "**/__pycache__", "{repo_root}/graphify-out"],
        "consistency": "none",
    },
    {
        "slug": "servidor", "kind": "servidor", "name": "Servidor: appdata e bancos",
        "paths": ["/srv/appdata"],
        "excludes": [
            # Pastas vivas dos bancos: entram pelos dumps (dumps_dir), nunca copiadas rodando.
            "/srv/appdata/*/postgres",
            "/srv/appdata/*/redis",
        ],
        "consistency": "policies",
    },
)

# Stacks com SQLite em uso constante: param durante a cópia.
DEFAULT_POLICIES = {"jellyfin": "stop", "homeassistant": "stop"}


def repository_url(storage: dict, subpath: str) -> str:
    """Endereço do repositório no formato do restic."""
    sub = subpath.strip("/")
    kind = storage["kind"]
    if kind == "b2":
        endpoint = storage["endpoint"].rstrip("/")
        if not endpoint.startswith(("http://", "https://")):
            endpoint = "https://" + endpoint
        return f"s3:{endpoint}/{storage['bucket']}/{sub}"
    if kind == "local":
        return pjoin(storage["path"], sub)
    if kind == "rest":
        return f"rest:{storage['endpoint'].rstrip('/')}/{sub}"
    if kind == "sftp":
        return f"sftp:{storage['username']}@{storage['endpoint']}:{pjoin(storage['path'], sub)}"
    raise ValueError(f"tipo de destino desconhecido: {kind}")


async def build(conn, agent_id) -> dict:
    s = await conn.fetchrow("SELECT * FROM agent_settings WHERE agent_id = $1", agent_id)
    storages = await conn.fetch("SELECT * FROM storages WHERE agent_id = $1 ORDER BY name", agent_id)
    datasets = await conn.fetch("SELECT * FROM datasets WHERE agent_id = $1 ORDER BY slug", agent_id)
    repos = await conn.fetch(
        """SELECT r.* FROM repositories r JOIN datasets d ON d.id = r.dataset_id
           WHERE d.agent_id = $1 ORDER BY r.subpath""", agent_id)
    jobs = await conn.fetch(
        """SELECT j.* FROM jobs j JOIN repositories r ON r.id = j.repository_id
           JOIN datasets d ON d.id = r.dataset_id WHERE d.agent_id = $1 ORDER BY j.name""", agent_id)
    policies = await conn.fetch("SELECT stack, mode FROM stack_policies WHERE agent_id = $1 ORDER BY stack",
                                agent_id)
    storage_by_id = {row["id"]: dict(row) for row in storages}
    smtp = dict(s["smtp"] or {})
    return {
        "host": {
            "timezone": s["timezone"],
            "repo_root": s["repo_root"],
            "stacks_file": s["stacks_file"],
            "dumps_dir": s["dumps_dir"],
        },
        "smtp": {**smtp, "password": s["smtp_password_sealed"] or ""} if smtp.get("host") else None,
        "storages": [{
            "id": str(row["id"]), "name": row["name"], "kind": row["kind"], "endpoint": row["endpoint"],
            "region": row["region"], "bucket": row["bucket"], "path": row["path"],
            "username": row["username"], "secret": row["secret_sealed"] or "", "lock_days": row["lock_days"],
        } for row in storages],
        "datasets": [{
            "id": str(row["id"]), "slug": row["slug"], "name": row["name"], "kind": row["kind"],
            "paths": list(row["paths"]), "excludes": list(row["excludes"]), "consistency": row["consistency"],
        } for row in datasets],
        "repositories": [{
            "id": str(row["id"]), "dataset_id": str(row["dataset_id"]), "storage_id": str(row["storage_id"]),
            "url": repository_url(storage_by_id[row["storage_id"]], row["subpath"]),
            "password": row["password_sealed"] or "",
        } for row in repos],
        "jobs": [{
            "id": str(row["id"]), "name": row["name"], "repository_id": str(row["repository_id"]),
            "enabled": row["enabled"], "schedule": row["schedule"], "retention": row["retention"],
            "prune_schedule": row["prune_schedule"], "check_schedule": row["check_schedule"],
            "check_subset": row["check_subset"], "anomaly_pct": row["anomaly_pct"],
            "ping_url": row["ping_url"],
        } for row in jobs],
        "stack_policies": {row["stack"]: row["mode"] for row in policies},
    }


async def publish(conn, agent_id, user_id=None) -> int:
    """Grava uma revisão nova se o plano mudou. Devolve o número da revisão atual."""
    document = await build(conn, agent_id)
    checksum = hashlib.sha256(json.dumps(document, sort_keys=True).encode()).hexdigest()
    last = await conn.fetchrow(
        "SELECT revision, checksum FROM config_revisions WHERE agent_id = $1 ORDER BY revision DESC LIMIT 1",
        agent_id)
    if last and last["checksum"] == checksum:
        return last["revision"]
    revision = (last["revision"] if last else 0) + 1
    document["revision"] = revision
    await conn.execute(
        """INSERT INTO config_revisions (agent_id, revision, document, checksum, created_by)
           VALUES ($1, $2, $3, $4, $5)""", agent_id, revision, document, checksum, user_id)
    return revision


async def create_defaults(conn, agent_id, repo_root: str) -> None:
    stacks_file = pjoin(repo_root, "00-infrastructure/stacks.txt") if repo_root else ""
    await conn.execute(
        "INSERT INTO agent_settings (agent_id, repo_root, stacks_file) VALUES ($1, $2, $3)",
        agent_id, repo_root, stacks_file)
    for spec in DEFAULT_DATASETS:
        paths = [p.replace("{repo_root}", repo_root) for p in spec["paths"] if repo_root or "{repo_root}" not in p]
        excludes = [p.replace("{repo_root}", repo_root) for p in spec["excludes"]
                    if repo_root or "{repo_root}" not in p]
        await conn.execute(
            """INSERT INTO datasets (agent_id, slug, name, kind, paths, excludes, consistency)
               VALUES ($1, $2, $3, $4, $5, $6, $7)""",
            agent_id, spec["slug"], spec["name"], spec["kind"], paths, excludes, spec["consistency"])
    for stack, mode in DEFAULT_POLICIES.items():
        await conn.execute("INSERT INTO stack_policies (agent_id, stack, mode) VALUES ($1, $2, $3)",
                           agent_id, stack, mode)
