"""Testes das versões por qualidade (stream/download com ?quality=) pela API,
com arquivos de áudio de verdade gerados pelo ffmpeg.

Uso: docker compose exec -T api python tests/test_variants.py
"""
from __future__ import annotations

import asyncio
import secrets
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx

from app.auth import repository as auth_repo
from app.auth.security import create_access_token, hash_password
from app.core.db import close_pool, create_pool
from app.core.redis import get_redis
from app.downloads import variants
from app.downloads.audio_info import AudioInfo
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


def make_audio(path: Path, args: list[str]) -> Path:
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
                    *args, str(path)], check=True)
    return path


print("=== o que cada nível entrega (sem arquivos) ===")
flac = AudioInfo("flac", None, 44100, 16)
ok([variants.delivered(flac, lv).label for lv in variants.LEVELS],
   ["FLAC 16/44.1", "MP3 320", "AAC 160", "AAC 96"], "mestre FLAC: converte nos níveis menores")
mp3 = AudioInfo("mp3", 320, 44100, None)
ok([variants.delivered(mp3, lv).label for lv in variants.LEVELS],
   ["MP3 320", "MP3 320", "AAC 160", "AAC 96"], "mestre 320: alta = o próprio arquivo")
opus = AudioInfo("opus", 140, 48000, None)
ok([variants.delivered(opus, lv).label for lv in variants.LEVELS],
   ["Opus 140", "Opus 140", "Opus 140", "AAC 96"], "Opus do YouTube: nunca aumenta, só reduz no econômico")
low = AudioInfo("mp3", 128, 44100, None)
ok({variants.delivered(low, lv).label for lv in variants.LEVELS}, {"MP3 128"}, "MP3 128: sempre o próprio")
ok(variants.delivered(None, "high").label, "", "sem medição: o mestre")


async def main():
    pool = await create_pool()
    await get_redis()
    tag = secrets.token_hex(3)
    user = await auth_repo.create_user(pool, f"t_var_{tag}", hash_password("x" * 12))
    h = {"Authorization": f"Bearer {create_access_token(str(user['id']), False)}"}
    tid = str(await pool.fetchval(
        "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'A', 8) RETURNING id", f"var {tag}"))
    await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1, 'spotify', $2)",
                       tid, f"v{tag}")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        await store_file(tid, make_audio(CACHE_DIR / f"src-{tag}.flac", ["-c:a", "flac", "-sample_fmt", "s16"]),
                         "lidarr", pool)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            print("=== status e lote informam o que cada nível entrega ===")
            st = (await c.get(f"/api/tracks/{tid}/status", headers=h)).json()
            ok({k: v["label"] for k, v in st["qualities"].items()},
               {"original": "FLAC 16/44.1", "high": "MP3 320", "normal": "AAC 160", "low": "AAC 96"}, "status")
            bulk = (await c.post("/api/tracks/qualities", headers=h,
                                 json={"refs": [f"spotify:v{tag}", "spotify:nao-existe", "sem-dois-pontos"]})).json()
            ok(list(bulk), [f"spotify:v{tag}"], "lote: só as refs com arquivo no servidor")
            ok(bulk[f"spotify:v{tag}"]["high"], {"label": "MP3 320", "rank": 30}, "lote: label e rank")

            print("=== stream em 'normal': converte uma vez, guarda e aceita Range ===")
            r = await c.get(f"/api/tracks/{tid}/stream", params={"quality": "normal"}, headers=h)
            ok((r.status_code, r.headers["x-track-format"], r.headers["x-track-quality"]),
               (200, "m4a", "AAC 160"), "AAC 160 em .m4a")
            made = list(variants.VARIANTS_DIR.glob(f"{tid}.normal.*"))
            ok(len(made), 1, "versão guardada em music/variants")
            first_mtime = made[0].stat().st_mtime
            r = await c.get(f"/api/tracks/{tid}/stream", params={"quality": "normal"},
                            headers={**h, "Range": "bytes=100-199"})
            ok((r.status_code, len(r.content), r.headers["x-track-quality"]), (206, 100, "AAC 160"),
               "Range sobre a versão (o player avança no meio)")
            ok(len(list(variants.VARIANTS_DIR.glob(f"{tid}.normal.*"))), 1, "não converte de novo")
            ok(made[0].stat().st_mtime >= first_mtime, True, "uso renova a validade")

            print("=== download offline ===")
            r = await c.get(f"/api/tracks/{tid}/download", params={"quality": "original"}, headers=h)
            ok((r.status_code, r.headers["x-track-format"], r.headers["x-track-quality-rank"]),
               (200, "flac", "40"), "original = o FLAC")
            r = await c.get(f"/api/tracks/{tid}/download", headers=h)
            ok(r.headers["x-track-format"], "flac", "sem ?quality= (apps antigos): original")
            r = await c.get(f"/api/tracks/{tid}/download", params={"quality": "alta"}, headers=h)
            ok(r.status_code, 422, "nível inválido é recusado")

            print("=== mestre trocado: versões antigas somem, nada é aumentado ===")
            await store_file(tid, make_audio(CACHE_DIR / f"src2-{tag}.mp3", ["-c:a", "libmp3lame", "-b:a", "128k"]),
                             "deemix", pool)
            ok(list(variants.VARIANTS_DIR.glob(f"{tid}.*")), [], "versões do mestre antigo apagadas")
            r = await c.get(f"/api/tracks/{tid}/stream", params={"quality": "high"}, headers=h)
            ok((r.headers["x-track-format"], r.headers["x-track-quality"]), ("mp3", "MP3 128"),
               "pediu 320, só há 128: vai o 128")
    finally:
        path = await pool.fetchval("SELECT path FROM files WHERE track_id = $1", tid)
        if path:
            Path(path).unlink(missing_ok=True)
        variants.remove_for(tid)
        await pool.execute("DELETE FROM tracks WHERE id = $1", tid)
        await pool.execute("DELETE FROM users WHERE id = $1", user["id"])
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
