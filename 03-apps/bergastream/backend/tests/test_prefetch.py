"""POST /api/play?prefetch=true: pré-busca vai para a fila média; tocar a
mesma música depois a promove para a alta.

Uso: docker compose exec -T api python tests/test_prefetch.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import asyncpg
import redis.asyncio as aioredis
from starlette.testclient import TestClient

from app.config import settings
from app.downloads import queue as q
from app.main import app

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


async def user(tag):
    from app.auth.security import hash_password
    conn = await asyncpg.connect(settings.database_url)
    try:
        await conn.execute(
            "INSERT INTO users (username, name, password_hash) VALUES ($1, 'Pré', $2)",
            f"t_pre_{tag}", hash_password("senha-pre"))
    finally:
        await conn.close()


async def job_of(track_id):
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    try:
        job_id = await r.get(q.track_job_key(track_id))
        job = await r.hgetall(f"bergastream:job:{job_id}")
        await_in = {name: await r.lpos(key, job_id) for name, key in
                    (("alta", q.PRIORITY_QUEUES[1]), ("média", q.PRIORITY_QUEUES[2]))}
        return job.get("priority"), {k for k, v in await_in.items() if v is not None}
    finally:
        await r.aclose()


async def cleanup(tag, ids):
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    conn = await asyncpg.connect(settings.database_url)
    try:
        for tid in ids:
            job_id = await r.get(q.track_job_key(tid))
            for key in q.PRIORITY_QUEUES.values():
                await r.lrem(key, 0, job_id or "")
            await r.delete(q.track_job_key(tid), f"bergastream:job:{job_id}")
        await conn.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", ids)
        await conn.execute("DELETE FROM users WHERE username = $1", f"t_pre_{tag}")
    finally:
        await conn.close()
        await r.aclose()


def main():
    tag = secrets.token_hex(3)
    asyncio.run(user(tag))
    ids = []
    try:
        with TestClient(app) as c:
            settings.password_login = "true"
            r = c.post("/api/auth/login", json={"username": f"t_pre_{tag}", "password": "senha-pre"})
            h = {"Authorization": "Bearer " + r.json()["access_token"]}
            body = {"provider": "deezer", "external_id": f"9{tag}", "title": f"Pré {tag}",
                    "artist": "Banda", "duration_seconds": 200}
            print("=== pré-busca ===")
            r = c.post("/api/play", headers=h, params={"prefetch": "true"}, json=body)
            tid = r.json()["track_id"]
            ids.append(tid)
            ok(r.json()["status"], "downloading", "entra na fila")
            ok(asyncio.run(job_of(tid)), ("2", {"média"}), "fila média")
            print("=== tocar a mesma promove ===")
            c.post("/api/play", headers=h, json=body)
            ok(asyncio.run(job_of(tid)), ("1", {"alta"}), "promovida para a alta, sem duplicar")
            print("=== clique direto ===")
            body2 = {**body, "external_id": f"8{tag}", "title": f"Clique {tag}"}
            tid2 = c.post("/api/play", headers=h, json=body2).json()["track_id"]
            ids.append(tid2)
            ok(asyncio.run(job_of(tid2)), ("1", {"alta"}), "clique vai para a alta")
    finally:
        asyncio.run(cleanup(tag, ids))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
