"""Testes do histórico e das métricas (Passo 10).

Uso: docker compose exec -T api python tests/test_history.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx

from app.auth import repository as auth_repo
from app.auth.security import create_access_token, hash_password
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
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


async def main():
    pool = await create_pool()
    await get_redis()
    tag = secrets.token_hex(3)
    user = await auth_repo.create_user(pool, f"t_hist_{tag}", hash_password("x" * 12))
    other = await auth_repo.create_user(pool, f"t_hist2_{tag}", hash_password("x" * 12))
    h = {"Authorization": f"Bearer {create_access_token(str(user['id']), False)}"}
    h2 = {"Authorization": f"Bearer {create_access_token(str(other['id']), False)}"}
    tids = []
    for i, (title, artist, album, secs) in enumerate([
        (f"Hist A {tag}", "Banda X", "Disco 1", 200),
        (f"Hist B {tag}", "Banda X", "Disco 1", 100),
        (f"Hist C {tag}", "Banda Y", "Disco 2", 300),
    ]):
        tid = await pool.fetchval(
            "INSERT INTO tracks (title, artist, album, duration_seconds) VALUES ($1,$2,$3,$4) RETURNING id",
            title, artist, album, secs)
        await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1,'spotify',$2)",
                           tid, f"h{tag}{i}")
        tids.append(tid)

    def play(i, when, cid=None):
        return {"client_id": str(cid or uuid.uuid4()), "played_at": when.isoformat(),
                "track": {"provider": "spotify", "external_id": f"h{tag}{i}", "title": "x", "artist": "y"}}

    now = datetime.now(timezone.utc)
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            print("=== registrar ===")
            dup = uuid.uuid4()
            r = await c.post("/api/history", json={"plays": [play(0, now, dup), play(0, now), play(1, now), play(2, now)]}, headers=h)
            ok(r.json(), {"accepted": 4, "duplicates": 0}, "registra 4")
            r = await c.post("/api/history", json={"plays": [play(0, now, dup)]}, headers=h)
            ok(r.json(), {"accepted": 0, "duplicates": 1}, "reenviar o mesmo client_id não duplica")
            last_month = now.replace(day=1) - timedelta(days=2)
            await c.post("/api/history", json={"plays": [play(2, last_month)]}, headers=h)
            await c.post("/api/history", json={"plays": [play(2, now)]}, headers=h2)
            ok((await c.post("/api/history", json={"plays": [play(0, now)]})).status_code, 401, "exige login")

            print("=== métricas do mês ===")
            s = (await c.get("/api/me/stats", headers=h)).json()
            ok(s["plays_month"], 4, "conta só o mês atual e só do usuário")
            ok(s["seconds_month"], 200 * 2 + 100 + 300, "segundos ouvidos")
            ok(s["distinct_tracks_month"], 3, "músicas diferentes")
            ok([(a["name"], a["plays"]) for a in s["top_artists"]], [("Banda X", 3), ("Banda Y", 1)], "artistas mais ouvidos")
            ok(s["top_tracks"][0]["title"], f"Hist A {tag}", "faixa mais tocada primeiro")
            ok(s["top_tracks"][0]["plays"], 2, "com a contagem")
            ok(s["top_tracks"][0]["provider"], "spotify", "faixa com provider para tocar")
            ok([a["title"] for a in s["top_albums"]], ["Disco 1", "Disco 2"], "álbuns mais ouvidos")
            ok(s["month"], now.strftime("%Y-%m"), "mês")

            print("=== Biblioteca: última playlist tocada primeiro ===")
            first = (await c.post("/api/playlists", json={"name": "Antiga"}, headers=h)).json()["id"]
            second = (await c.post("/api/playlists", json={"name": "Nova"}, headers=h)).json()["id"]
            names = [p["name"] for p in (await c.get("/api/me/playlists", headers=h)).json()]
            ok(names[:2], ["Nova", "Antiga"], "sem reprodução: última alterada primeiro")
            p_ = play(0, now)
            p_["playlist_id"] = first
            ok((await c.post("/api/history", json={"plays": [p_]}, headers=h)).status_code, 200,
               "reprodução com playlist")
            mine = (await c.get("/api/me/playlists", headers=h)).json()
            ok([p["name"] for p in mine][:2], ["Antiga", "Nova"], "tocada vai para o topo")
            ok(mine[0]["last_played_at"] is not None, True, "last_played_at informado")
            gone = play(1, now)
            gone["playlist_id"] = str(uuid.uuid4())
            r = await c.post("/api/history", json={"plays": [gone]}, headers=h)
            ok(r.json()["accepted"], 1, "playlist inexistente não perde a reprodução")
            ok([p["name"] for p in (await c.get("/api/me/playlists", headers=h2)).json()], [],
               "outra pessoa não vê")

            print("=== situação do servidor (Ajustes) ===")
            r = await c.get("/api/server/status", headers=h)
            ok(r.status_code, 200, "status do servidor")
            st = r.json()
            ok(set(st), {"storage", "queue", "deemix"}, "seções")
            ok(st["storage"]["tracks"] >= 0 and st["storage"]["disk_free"] is not None, True,
               "músicas e disco")
            ok(isinstance(st["deemix"]["available"], bool), True, "fila do Deemix (ou indisponível)")
            ok((await c.get("/api/server/status")).status_code, 401, "exige login")

            print("=== falhas do Deemix registradas (e se o YouTube recuperou) ===")
            from app.downloads import deemix as deemix_mod
            from app.downloads.service import _note_deemix_failure
            from app.tracks.models import PlayRequest
            redis = await get_redis()
            before = await redis.llen("bergastream:deemix:failures")
            deemix_mod._errors["999"] = "Cannot read properties of undefined (reading 'HREF')"
            await _note_deemix_failure(
                PlayRequest(provider="spotify", external_id="x", title=f"Falhou {tag}", artist="Banda"),
                "999", recovered=True)
            st = (await c.get("/api/server/status", headers=h)).json()
            first = st["deemix"]["recent_failures"][0]
            ok((first["title"], first["recovered"], "HREF" in first["error"]),
               (f"Falhou {tag}", True, True), "falha com motivo e recuperada pelo YouTube")
            ok(deemix_mod.pop_error("999"), None, "motivo consumido")
            await redis.lpop("bergastream:deemix:failures")
            ok(await redis.llen("bergastream:deemix:failures"), before, "limpeza do teste")
    finally:
        await pool.execute("DELETE FROM playlists WHERE user_id = ANY($1::uuid[])", [user["id"], other["id"]])
        await pool.execute("DELETE FROM users WHERE id = ANY($1::uuid[])", [user["id"], other["id"]])
        await pool.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", tids)
        await close_redis()
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
