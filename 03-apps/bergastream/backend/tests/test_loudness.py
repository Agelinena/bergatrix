"""Volume percebido (normalização) e "baixar de novo".

Uso: docker compose exec -T api python tests/test_loudness.py
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
from app.downloads import loudness
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


def tone(path: Path, volume: float) -> Path:
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                    "-af", f"volume={volume}", "-c:a", "libmp3lame", "-b:a", "192k", str(path)], check=True)
    return path


async def setup(tag):
    pool = await create_pool()
    user = await auth_repo.create_user(pool, f"t_loud_{tag}", hash_password("x" * 12), name=f"loud {tag}")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ids = []
    for name, vol in (("alta", 1.0), ("baixa", 0.1)):
        tid = str(await pool.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, $2, 4) RETURNING id",
            name, f"L {tag}"))
        await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1, 'spotify', $2)",
                           tid, f"loud-{name}-{tag}")
        await store_file(tid, tone(CACHE_DIR / f"src-{tid}.mp3", vol), "deemix", pool)
        ids.append(tid)
    await asyncio.gather(*list(loudness._pending))  # medições em segundo plano
    rows = {r["track_id"]: r for r in await pool.fetch(
        "SELECT track_id::text, loudness_lufs, true_peak_db FROM files WHERE track_id = ANY($1::uuid[])", ids)}
    await close_pool()
    return str(user["id"]), ids, rows


async def cleanup(user_id, ids, tag):
    pool = await create_pool()
    for p in await pool.fetch("SELECT path FROM files WHERE track_id = ANY($1::uuid[])", ids):
        Path(p["path"]).unlink(missing_ok=True)
    await pool.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", ids)
    await pool.execute("DELETE FROM users WHERE id = $1", user_id)
    await close_pool()
    # Conexão nova: a do get_redis() ficou presa ao loop do TestClient.
    import redis.asyncio as aioredis
    from app.config import settings
    redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    for name in q.PRIORITY_QUEUES.values():
        for job in await redis.lrange(name, 0, -1):
            if (await q.get_job(redis, job) or {}).get("track_id") in ids:
                await redis.lrem(name, 0, job)
    for tid in ids:
        await redis.delete(q.track_job_key(tid))
    await redis.aclose()


def main():
    tag = secrets.token_hex(3)
    user_id, ids, rows = asyncio.run(setup(tag))
    loud, quiet = rows[ids[0]], rows[ids[1]]
    try:
        print("=== medição ===")
        ok(loud["loudness_lufs"] is not None and quiet["loudness_lufs"] is not None, True, "medido ao baixar")
        diff = loud["loudness_lufs"] - quiet["loudness_lufs"]
        ok(19 < diff < 21, True, f"10× mais baixo ≈ 20 dB a menos ({diff:.1f})")
        ok(loud["true_peak_db"] > quiet["true_peak_db"], True, "pico real acompanha")

        h = {"Authorization": f"Bearer {create_access_token(user_id, False)}"}
        with TestClient(app) as c:
            st = c.get(f"/api/tracks/{ids[0]}/status", headers=h).json()
            ok(round(st["loudness"]["lufs"], 1), round(loud["loudness_lufs"], 1), "status traz a loudness")
            batch = c.post("/api/tracks/loudness", headers=h,
                           json={"refs": [f"spotify:loud-alta-{tag}", f"spotify:loud-baixa-{tag}", "spotify:nada"]}).json()
            ok(sorted(batch), sorted([f"spotify:loud-alta-{tag}", f"spotify:loud-baixa-{tag}"]),
               "em lote, pelas refs das cópias offline")

            print("=== baixar de novo ===")
            body = {"provider": "spotify", "external_id": f"loud-alta-{tag}", "title": "alta",
                    "artist": f"L {tag}", "duration_seconds": 4}
            r = c.post("/api/tracks/redownload", headers=h, json=body)
            ok((r.status_code, r.json()["status"], r.json()["track_id"]), (200, "downloading", ids[0]),
               "pedido aceito")
            ok(c.get(f"/api/tracks/{ids[0]}/status", headers=h).json()["status"], "queued",
               "arquivo apagado; na fila de novo")
    finally:
        asyncio.run(cleanup(user_id, ids, tag))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
