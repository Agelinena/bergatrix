"""Letras (LRCLIB): formato LRC, limpeza do título, escolha da versão,
cache no banco (inclusive "não achou") e LRCLIB fora do ar. Sem rede.

Uso: docker compose exec -T api python tests/test_lyrics.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx

from app.auth import repository as auth_repo
from app.auth.security import create_access_token, hash_password
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
from app.lyrics import service as ly
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


LRC = "[ar:Scorpions]\n[00:28.60] Listening to the wind of change\n[00:05.5] Intro\n[01:02.123][02:10.00] Refrão\n"


async def main():
    print("=== formato LRC ===")
    lines = ly.parse_lrc(LRC)
    ok([(l.time_ms, l.text) for l in lines],
       [(5500, "Intro"), (28600, "Listening to the wind of change"), (62123, "Refrão"), (130000, "Refrão")],
       "tempos em ms, em ordem, refrão com dois tempos")
    ok(ly.parse_lrc(None), [], "sem letra")

    print("=== título limpo para a busca ===")
    ok(ly.clean_title("Bohemian Rhapsody - Remastered 2011"), "Bohemian Rhapsody", "remaster")
    ok(ly.clean_title("Wind Of Change (feat. Fulano)"), "Wind Of Change", "feat")
    ok(ly.clean_title("Tempo Perdido - Ao Vivo"), "Tempo Perdido", "ao vivo")
    ok(ly.clean_title("Live and Let Die"), "Live and Let Die", "palavra no meio não sai")

    print("=== escolha da versão na busca ===")
    items = [
        {"duration": 263, "syncedLyrics": "[00:01.00] a"},
        {"duration": 352, "plainLyrics": "só texto"},
        {"duration": 355, "syncedLyrics": "[00:01.00] b"},
        {"duration": 354, "instrumental": True},
    ]
    ok(ly._pick(items, 354)["syncedLyrics"], "[00:01.00] b", "duração próxima e sincronizada")
    ok(ly._pick([{"duration": 200, "syncedLyrics": "x"}], 354), None, "duração muito diferente: nada")

    print("=== cache no banco ===")
    pool = await create_pool()
    await get_redis()
    tag = secrets.token_hex(3)
    user = await auth_repo.create_user(pool, f"t_ly_{tag}", hash_password("x" * 12))
    h = {"Authorization": f"Bearer {create_access_token(str(user['id']), False)}"}
    tids = []
    calls = []
    original = ly.fetch_lrclib
    try:
        for i in range(3):
            tid = await pool.fetchval(
                "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'Scorpions', 312) RETURNING id",
                f"Letra {tag} {i}")
            await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1,'spotify',$2)",
                               tid, f"ly{tag}{i}")
            tids.append(str(tid))

        async def fake(title, artist, album, duration):
            calls.append(title)
            if title.endswith(" 1"):
                return None
            if title.endswith(" 2"):
                raise httpx.ConnectError("fora do ar")
            return {"syncedLyrics": LRC, "plainLyrics": "texto"}

        ly.fetch_lrclib = fake
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            def body(i):
                return {"provider": "spotify", "external_id": f"ly{tag}{i}", "title": f"Letra {tag} {i}",
                        "artist": "Scorpions", "duration_seconds": 312}

            r = await c.post("/api/lyrics", json=body(0), headers=h)
            d = r.json()
            ok((r.status_code, d["found"], len(d["synced"]), d["synced"][1]["time_ms"]),
               (200, True, 4, 28600), "achou e devolve linhas com tempo")
            await c.post("/api/lyrics", json=body(0), headers=h)
            ok(calls.count(f"Letra {tag} 0"), 1, "segunda vez vem do banco")

            d = (await c.post("/api/lyrics", json=body(1), headers=h)).json()
            ok(d["found"], False, "não achou")
            await c.post("/api/lyrics", json=body(1), headers=h)
            ok(calls.count(f"Letra {tag} 1"), 1, "'não achou' também fica guardado")
            await pool.execute("UPDATE lyrics SET fetched_at = now() - interval '8 days' WHERE track_id = $1", tids[1])
            await c.post("/api/lyrics", json=body(1), headers=h)
            ok(calls.count(f"Letra {tag} 1"), 2, "tenta de novo depois de 7 dias")

            d = (await c.post("/api/lyrics", json=body(2), headers=h)).json()
            ok(d["found"], False, "LRCLIB fora do ar: sem letra")
            ok(await pool.fetchval("SELECT count(*) FROM lyrics WHERE track_id = $1", tids[2]), 0,
               "falha de rede não fica guardada")
            ok((await c.post("/api/lyrics", json=body(0))).status_code, 401, "exige login")
    finally:
        ly.fetch_lrclib = original
        for t in tids:
            await pool.execute("DELETE FROM tracks WHERE id = $1", t)
        await pool.execute("DELETE FROM users WHERE id = $1", user["id"])
        await close_redis()
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
