"""Permanência com arquivos de verdade: marcação (files.kind) e pasta
(music/cache ↔ music/permanent) mudam juntas.

Inclui o caso relatado: a faixa entra na playlist antes de o download
terminar; quando o arquivo chega, ele precisa nascer permanente.

Uso: docker compose exec -T api python tests/test_permanence_dirs.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.core.db import close_pool, create_pool
from app.downloads.service import _register_in_db
from app.playlists import repository as repo
from app.storage.permanence import CACHE_DIR, PERMANENT_DIR, reconcile

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


async def state(pool, track_id):
    row = await pool.fetchrow("SELECT kind, path FROM files WHERE track_id = $1", track_id)
    return row["kind"], Path(row["path"]).parent.name, Path(row["path"]).exists()


async def main():
    pool = await create_pool()
    tag = secrets.token_hex(3)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    PERMANENT_DIR.mkdir(parents=True, exist_ok=True)
    user = await pool.fetchval("INSERT INTO users (name, username) VALUES ($1, $1) RETURNING id", f"perm_{tag}")
    playlist = await pool.fetchval("INSERT INTO playlists (user_id, name) VALUES ($1, 'P') RETURNING id", user)
    tracks = []
    try:
        async def new_track(n):
            t = str(await pool.fetchval(
                "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'A', 100) RETURNING id", f"perm {tag} {n}"))
            tracks.append(t)
            return t

        def new_file(track_id):
            f = CACHE_DIR / f"{track_id}.mp3"
            f.write_bytes(b"ID3" + b"\0" * 100)
            return f

        print("=== baixada antes, depois entra na playlist ===")
        a = await new_track("a")
        await _register_in_db(a, new_file(a), "mp3_320")
        ok(await state(pool, a), ("cache", "cache", True), "baixada solta: cache")
        await repo.add_track_to_playlist(pool, playlist, a, user)
        ok(await state(pool, a), ("permanent", "permanent", True), "na playlist: permanente, na pasta permanent/")
        ok((CACHE_DIR / f"{a}.mp3").exists(), False, "saiu de cache/")

        print("=== entra na playlist antes de o download terminar (caso relatado) ===")
        b = await new_track("b")
        await repo.add_track_to_playlist(pool, playlist, b, user)
        await _register_in_db(b, new_file(b), "mp3_320")
        ok(await state(pool, b), ("permanent", "permanent", True), "arquivo chega e nasce permanente")

        print("=== sai da última playlist ===")
        await repo.remove_track_from_playlist(pool, playlist, a)
        ok(await state(pool, a), ("cache", "cache", True), "volta a cache/ (limpeza apaga depois do TTL)")
        last = await pool.fetchval("SELECT last_played_at FROM files WHERE track_id = $1", a)
        ok(last is not None, True, "timer do cache zerado")

        print("=== conserto ao subir (dados antigos) ===")
        c = await new_track("c")
        await pool.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES ($1, $2, 99)", playlist, c)
        f = new_file(c)
        await pool.execute(
            "INSERT INTO files (track_id, path, size_bytes, format, kind) VALUES ($1, $2, 1, 'mp3_320', 'cache')",
            c, str(f))
        ok(await state(pool, c), ("cache", "cache", True), "inconsistente antes")
        fixed = await reconcile(pool)
        ok(fixed >= 1, True, "reconcile corrigiu")
        ok(await state(pool, c), ("permanent", "permanent", True), "inconsistente consertado")
        ok(await reconcile(pool), 0, "segunda passada não tem o que corrigir")
    finally:
        for t in tracks:
            for d in (CACHE_DIR, PERMANENT_DIR):
                (d / f"{t}.mp3").unlink(missing_ok=True)
            await pool.execute("DELETE FROM tracks WHERE id = $1", t)
        await pool.execute("DELETE FROM users WHERE id = $1", user)
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
