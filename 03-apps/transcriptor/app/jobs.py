"""Fila e transcrições no Postgres: o que a API e o worker compartilham."""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Iterable
from uuid import UUID

import asyncpg

from app.config import settings
from app.formats import Segment

ACTIVE = ("downloading", "preparing", "transcribing")
WAITING = ("uploading", "queued")
FINISHED = ("done", "failed", "canceled")

PUBLIC_FIELDS = (
    "id", "title", "source_kind", "source_url", "source_bytes", "model", "language", "prompt", "status",
    "progress", "error", "duration_seconds", "detected_language", "has_audio", "created_at", "started_at",
    "finished_at",
)


def work_dir(job_id: UUID | str) -> Path:
    return Path(settings.work_dir) / str(job_id)


def upload_path(job_id: UUID | str) -> Path:
    return work_dir(job_id) / "source"


def playback_path(job_id: UUID | str) -> Path:
    return work_dir(job_id) / "playback.m4a"


def remove_work(job_id: UUID | str) -> None:
    shutil.rmtree(work_dir(job_id), ignore_errors=True)


def public(row: asyncpg.Record | dict) -> dict:
    data = {field: row[field] for field in PUBLIC_FIELDS}
    data["id"] = str(data["id"])
    for field in ("created_at", "started_at", "finished_at"):
        if data[field] is not None:
            data[field] = data[field].isoformat()
    return data


# ── API ──────────────────────────────────────────────────────────────

async def create(pool, user_id, *, title: str, source_kind: str, model: str, language: str | None,
                 prompt: str, status: str, source_url: str | None = None, source_bytes: int | None = None):
    return await pool.fetchrow(
        """INSERT INTO jobs (user_id, title, source_kind, source_url, source_bytes, model, language, prompt, status)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING *""",
        user_id, title, source_kind, source_url, source_bytes, model, language, prompt, status)


async def active_count(pool, user_id) -> int:
    return await pool.fetchval(
        "SELECT count(*) FROM jobs WHERE user_id = $1 AND status = ANY($2::text[])",
        user_id, list(WAITING + ACTIVE))


async def get(pool, user_id, job_id):
    return await pool.fetchrow("SELECT * FROM jobs WHERE id = $1 AND user_id = $2", job_id, user_id)


async def listing(pool, user_id, query: str = "", limit: int = 50, before=None):
    if query:
        return await pool.fetch(
            """SELECT * FROM jobs
               WHERE user_id = $1 AND status <> 'uploading'
                 AND (search @@ websearch_to_tsquery('portuguese', $2) OR title ILIKE '%' || $3 || '%')
               ORDER BY created_at DESC LIMIT $4""",
            user_id, query, query.replace("%", r"\%").replace("_", r"\_"), limit)
    return await pool.fetch(
        """SELECT * FROM jobs WHERE user_id = $1 AND status <> 'uploading'
             AND ($2::timestamptz IS NULL OR created_at < $2)
           ORDER BY created_at DESC LIMIT $3""",
        user_id, before, limit)


async def segments(pool, job_id, after: int = -1) -> list[Segment]:
    rows = await pool.fetch(
        "SELECT idx, start_ms, end_ms, text FROM segments WHERE job_id = $1 AND idx > $2 ORDER BY idx",
        job_id, after)
    return [Segment(r["idx"], r["start_ms"], r["end_ms"], r["text"]) for r in rows]


async def rebuild_transcript(connection, job_id) -> None:
    await connection.execute(
        """UPDATE jobs SET transcript = coalesce(
               (SELECT string_agg(text, ' ' ORDER BY idx) FROM segments WHERE job_id = $1), '')
           WHERE id = $1""", job_id)


async def edit_segment(pool, job_id, idx: int, text: str) -> bool:
    async with pool.acquire() as connection, connection.transaction():
        done = await connection.execute(
            "UPDATE segments SET text = $3, edited = true WHERE job_id = $1 AND idx = $2", job_id, idx, text)
        if done == "UPDATE 0":
            return False
        await rebuild_transcript(connection, job_id)
    return True


async def rename(pool, job_id, title: str) -> None:
    await pool.execute("UPDATE jobs SET title = $2 WHERE id = $1", job_id, title)


async def cancel(pool, job_id) -> None:
    """Na fila ou subindo: cancela na hora. Rodando: o worker para no próximo trecho."""
    await pool.execute(
        """UPDATE jobs SET
               status = CASE WHEN status = ANY($2::text[]) THEN 'canceled' ELSE status END,
               finished_at = CASE WHEN status = ANY($2::text[]) THEN now() ELSE finished_at END,
               cancel_requested = status = ANY($3::text[])
           WHERE id = $1""", job_id, list(WAITING), list(ACTIVE))


async def retry(pool, job_id) -> bool:
    async with pool.acquire() as connection, connection.transaction():
        await connection.execute("DELETE FROM segments WHERE job_id = $1", job_id)
        done = await connection.execute(
            """UPDATE jobs SET status = 'queued', progress = 0, error = NULL, cancel_requested = false,
                   attempts = 0, transcript = '', started_at = NULL, finished_at = NULL, worker = NULL
               WHERE id = $1 AND status IN ('failed', 'canceled')""", job_id)
    return done == "UPDATE 1"


async def delete(pool, job_id) -> None:
    await pool.execute("DELETE FROM jobs WHERE id = $1", job_id)
    remove_work(job_id)


# ── Worker ───────────────────────────────────────────────────────────

async def claim(pool, worker: str):
    return await pool.fetchrow(
        """UPDATE jobs SET status = CASE WHEN source_kind = 'url' THEN 'downloading' ELSE 'preparing' END,
               worker = $1, started_at = now(), heartbeat_at = now(), attempts = attempts + 1, progress = 0
           WHERE id = (SELECT id FROM jobs WHERE status = 'queued' ORDER BY created_at
                       FOR UPDATE SKIP LOCKED LIMIT 1)
           RETURNING *""", worker)


async def update(pool, job_id, **fields) -> bool:
    """Atualiza o job em andamento e manda sinal de vida. False se a pessoa
    pediu para cancelar (ou apagou o job)."""
    columns = ", ".join(f"{name} = ${i}" for i, name in enumerate(fields, start=2))
    sets = f"{columns}, heartbeat_at = now()" if columns else "heartbeat_at = now()"
    row = await pool.fetchrow(f"UPDATE jobs SET {sets} WHERE id = $1 RETURNING cancel_requested",
                              job_id, *fields.values())
    return row is not None and not row["cancel_requested"]


async def add_segments(pool, job_id, items: Iterable[Segment]) -> None:
    await pool.executemany(
        "INSERT INTO segments (job_id, idx, start_ms, end_ms, text) VALUES ($1, $2, $3, $4, $5)",
        [(job_id, s.idx, s.start_ms, s.end_ms, s.text) for s in items])


async def finish(pool, job_id, status: str, error: str | None = None) -> None:
    async with pool.acquire() as connection, connection.transaction():
        if status == "done":
            await rebuild_transcript(connection, job_id)
        await connection.execute(
            """UPDATE jobs SET status = $2, error = $3, finished_at = now(), cancel_requested = false,
                   progress = CASE WHEN $2 = 'done' THEN 1 ELSE progress END
               WHERE id = $1""", job_id, status, error)


async def requeue_stale(pool, stale_seconds: int = 120, max_attempts: int = 2) -> int:
    """Jobs de um worker que morreu (sem sinal de vida): de volta à fila, ou
    falha depois de tentar duas vezes."""
    rows = await pool.fetch(
        """UPDATE jobs SET
               status = CASE WHEN cancel_requested THEN 'canceled'
                             WHEN attempts >= $2 THEN 'failed' ELSE 'queued' END,
               error = CASE WHEN NOT cancel_requested AND attempts >= $2
                            THEN 'O processamento foi interrompido duas vezes.' END,
               finished_at = CASE WHEN cancel_requested OR attempts >= $2 THEN now() END,
               cancel_requested = false,
               progress = 0
           WHERE status = ANY($3::text[]) AND heartbeat_at < now() - make_interval(secs => $1)
           RETURNING id, status""", stale_seconds, max_attempts, list(ACTIVE))
    for row in rows:
        if row["status"] == "queued":
            await pool.execute("DELETE FROM segments WHERE job_id = $1", row["id"])
    return len(rows)
