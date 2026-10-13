"""Fila sem downloads duplicados e stream estável (Range).

Uso: docker compose exec -T api python tests/test_stream_queue.py
"""
from __future__ import annotations

import asyncio
import secrets
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from starlette.testclient import TestClient

from app.auth import repository as auth_repo
from app.auth.security import create_access_token, hash_password
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
from app.downloads import queue as q
from app.downloads.service import store_file
from app.main import app
from app.storage.permanence import CACHE_DIR

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


async def queue_checks(tag: str) -> None:
    redis = await get_redis()
    track = f"00000000-0000-0000-0000-{tag:0>12}"
    try:
        print("=== fila: a mesma faixa não entra duas vezes ===")
        first = await q.enqueue(redis, track, "spotify", priority=3)
        again = await q.enqueue(redis, track, "spotify", priority=3)
        ok(again, first, "segundo pedido reaproveita o job")
        ok(await redis.lpos(q.PRIORITY_QUEUES[3], first) is not None, True, "está na fila de playlists")
        promoted = await q.enqueue(redis, track, "spotify", priority=1)
        ok(promoted, first, "play da mesma faixa: mesmo job")
        ok((await redis.lpos(q.PRIORITY_QUEUES[3], first), await redis.lpos(q.PRIORITY_QUEUES[1], first) is not None),
           (None, True), "promovido para a fila de quem está ouvindo")
        ok((await q.get_job(redis, first))["priority"], "1", "prioridade atualizada")
        await q.set_job_status(redis, first, "done")
        newer = await q.enqueue(redis, track, "spotify", priority=1)
        ok(newer != first, True, "job concluído: pedido novo cria outro")
        ok(await redis.ttl(f"bergastream:job:{newer}") > 0, True, "job expira sozinho")
    finally:
        for name in q.PRIORITY_QUEUES.values():
            for job in await redis.lrange(name, 0, -1):
                if (await q.get_job(redis, job) or {}).get("track_id") == track:
                    await redis.lrem(name, 0, job)
        await redis.delete(q.track_job_key(track))
        await close_redis()


async def setup(tag):
    pool = await create_pool()
    user = await auth_repo.create_user(pool, f"t_stream_{tag}", hash_password("x" * 12), name=f"stream {tag}")
    tid = str(await pool.fetchval(
        "INSERT INTO tracks (title, artist, duration_seconds) VALUES ('S', $1, 3) RETURNING id", f"T {tag}"))
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    src = CACHE_DIR / f"src-{tid}.mp3"
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=duration=3",
                    "-c:a", "libmp3lame", "-b:a", "128k", str(src)], check=True)
    await store_file(tid, src, "deemix", pool)
    path = await pool.fetchval("SELECT path FROM files WHERE track_id = $1", tid)
    await close_pool()
    return str(user["id"]), tid, Path(path)


async def cleanup(user_id, tid, path):
    pool = await create_pool()
    path.unlink(missing_ok=True)
    await pool.execute("DELETE FROM tracks WHERE id = $1", tid)
    await pool.execute("DELETE FROM users WHERE id = $1", user_id)
    await close_pool()


def main():
    tag = secrets.token_hex(3)
    asyncio.run(queue_checks(tag))
    user_id, tid, path = asyncio.run(setup(tag))
    size = path.stat().st_size
    try:
        print("=== stream: Range ===")
        h = {"Authorization": f"Bearer {create_access_token(user_id, False)}"}
        with TestClient(app) as c:
            r = c.get(f"/api/tracks/{tid}/stream", headers={**h, "Range": "bytes=100-199"})
            ok((r.status_code, len(r.content), r.headers["content-range"]), (206, 100, f"bytes 100-199/{size}"),
               "trecho pedido")
            r = c.get(f"/api/tracks/{tid}/stream", headers={**h, "Range": f"bytes={size - 10}-{size + 500}"})
            ok((r.status_code, len(r.content)), (206, 10), "fim além do arquivo: ajustado (antes 416)")
            r = c.get(f"/api/tracks/{tid}/stream", headers={**h, "Range": f"bytes={size}-"})
            ok(r.status_code, 416, "início além do arquivo: 416")
            r = c.get(f"/api/tracks/{tid}/status", headers=h)
            ok(r.json()["status"], "ready", "status pronto")
    finally:
        asyncio.run(cleanup(user_id, tid, path))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
