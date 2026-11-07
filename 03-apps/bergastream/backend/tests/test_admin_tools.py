"""Letra corrigida (sincronia e texto) e a aba de músicas com erro do admin
(listar, tentar de novo, escolher a fonte, ignorar). Sem rede: as buscas
de candidatos são trocadas por resultados fixos.

Uso: docker compose exec -T api python tests/test_admin_tools.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import asyncpg
from starlette.testclient import TestClient

from app.config import settings
from app.downloads import failures
from app.main import app
from app.search.models import FullSearch, SearchResult

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


async def sql(query, *args, fetch="val"):
    conn = await asyncpg.connect(settings.database_url)
    try:
        return await getattr(conn, "fetch" + fetch)(query, *args)
    finally:
        await conn.close()


LRC = "[00:05.00] Primeira linha\n[00:10.50] Segunda linha\n"


async def setup(tag):
    from app.auth.security import hash_password
    conn = await asyncpg.connect(settings.database_url)
    try:
        admin = await conn.fetchval(
            "INSERT INTO users (username, name, password_hash, is_admin) VALUES ($1, $2, $3, true) RETURNING id",
            f"t_adm_{tag}", f"Admin {tag}", hash_password("senha-admin"))
        user = await conn.fetchval(
            "INSERT INTO users (username, name, password_hash) VALUES ($1, $2, $3) RETURNING id",
            f"t_usr_{tag}", f"Pessoa {tag}", hash_password("senha-pessoa"))
        track = await conn.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'Artista', 200) RETURNING id",
            f"Musica {tag}")
        await conn.execute(
            "INSERT INTO lyrics (track_id, found, synced, plain) VALUES ($1, true, $2, NULL)", track, LRC)
        lost = await conn.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'Artista', 180) RETURNING id",
            f"Perdida {tag}")
        playlist = await conn.fetchval(
            "INSERT INTO playlists (user_id, name) VALUES ($1, $2) RETURNING id", user, f"Lista {tag}")
        await conn.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES ($1, $2, 0)",
            playlist, lost)
    finally:
        await conn.close()
    return str(admin), str(user), str(track), str(lost)


async def cleanup(tag, ids):
    conn = await asyncpg.connect(settings.database_url)
    try:
        await conn.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", ids)
        await conn.execute("DELETE FROM users WHERE username LIKE $1", f"t_%_{tag}")
    finally:
        await conn.close()


async def record(track_id, error="Não baixou do Deezer nem do YouTube"):
    pool = await asyncpg.create_pool(settings.database_url, min_size=1, max_size=1)
    try:
        await failures.record(pool, track_id, "deezer", "123", error)
    finally:
        await pool.close()


def main():
    tag = secrets.token_hex(3)
    admin_id, user_id, track, lost = asyncio.run(setup(tag))
    try:
        with TestClient(app) as c:
            def login(u, p):
                r = c.post("/api/auth/login", json={"username": u, "password": p})
                return {"Authorization": "Bearer " + r.json()["access_token"]}
            settings.password_login = "true"
            adm = login(f"t_adm_{tag}", "senha-admin")
            usr = login(f"t_usr_{tag}", "senha-pessoa")

            print("=== letra: sincronia ===")
            r = c.put(f"/api/lyrics/{track}", headers=usr, json={"offset_ms": 1500})
            ok(r.status_code, 200, "qualquer pessoa ajusta")
            body = r.json()
            ok([line["time_ms"] for line in body["synced"]], [6500, 12000], "tempos já com o atraso")
            ok((body["offset_ms"], body["edited"], body["lrc"]), (1500, True, LRC),
               "devolve o ajuste e o texto original")
            r = c.put(f"/api/lyrics/{track}", headers=usr, json={"offset_ms": -6000})
            ok(r.json()["synced"][0]["time_ms"], 0, "adiantar não deixa tempo negativo")
            ok(c.put(f"/api/lyrics/{track}", headers=usr, json={"offset_ms": 40000}).status_code, 422,
               "ajuste maior que 30 s: 422")

            print("=== letra: texto ===")
            r = c.put(f"/api/lyrics/{track}", headers=usr,
                      json={"lrc": "[00:01.00] Linha nova\n[00:03.25] Outra", "offset_ms": 0})
            ok([(l["time_ms"], l["text"]) for l in r.json()["synced"]],
               [(1000, "Linha nova"), (3250, "Outra")], "texto trocado")
            ok(r.json()["source"], "manual", "fica como manual")
            ok(c.put(f"/api/lyrics/{track}", headers=usr, json={"lrc": "sem tempo nenhum"}).status_code,
               422, "LRC sem tempo: 422")
            ok(c.put(f"/api/lyrics/{track}", headers=usr, json={"lrc": "", "plain": ""}).status_code,
               422, "letra vazia: 422")
            r = c.put(f"/api/lyrics/{lost}", headers=usr, json={"plain": "Letra escrita à mão"})
            ok((r.json()["found"], r.json()["plain"]), (True, "Letra escrita à mão"),
               "música sem letra ganha letra à mão")
            ok(c.put("/api/lyrics/nao-e-uuid", headers=usr, json={"offset_ms": 1}).status_code, 404,
               "faixa inválida: 404")

            print("=== erros de download ===")
            asyncio.run(record(lost))
            asyncio.run(record(lost))
            ok(c.get("/api/admin/failures", headers=usr).status_code, 403, "só admin")
            items = [f for f in c.get("/api/admin/failures", headers=adm).json() if f["track_id"] == lost]
            ok(len(items), 1, "falha listada")
            ok((items[0]["attempts"], items[0]["playlists"], items[0]["title"]), (2, 1, f"Perdida {tag}"),
               "tentativas, playlists e música")

            from app.search import deezer, ytmusic
            ytmusic.search = lambda query, limit=8: [
                SearchResult(provider="ytmusic", external_id="vid_longe", title="X", artist="A",
                             duration_seconds=400),
                SearchResult(provider="ytmusic", external_id="vid_perto", title="X", artist="A",
                             duration_seconds=181)]
            deezer.search_full = lambda query, limit=8: FullSearch(tracks=[
                SearchResult(provider="deezer", external_id="999", title="X", artist="A",
                             duration_seconds=170)])
            found = c.get(f"/api/admin/failures/{lost}/candidates", headers=adm).json()
            ok([f["external_id"] for f in found], ["vid_perto", "999", "vid_longe"],
               "candidatos pela duração mais parecida")

            r = c.post(f"/api/admin/failures/{lost}/source", headers=adm,
                       json={"provider": "ytmusic", "external_id": "vid_perto"})
            ok(r.status_code, 200, "fonte escolhida entra na fila")
            items = [f for f in c.get("/api/admin/failures", headers=adm).json() if f["track_id"] == lost]
            ok(items[0]["queued"], True, "aparece como na fila")
            ok(c.post(f"/api/admin/failures/{lost}/source", headers=adm,
                      json={"provider": "spotify", "external_id": "x"}).status_code, 422,
               "fonte que o worker não baixa direto: 422")

            r = c.post(f"/api/admin/failures/{lost}/ignore", headers=adm, json={"ignored": True})
            ok(r.status_code, 200, "ignorar")
            open_ids = [f["track_id"] for f in c.get("/api/admin/failures", headers=adm).json()]
            ignored_ids = [f["track_id"] for f in
                           c.get("/api/admin/failures?ignored=true", headers=adm).json()]
            ok((lost in open_ids, lost in ignored_ids), (False, True), "sai da lista e vai para ignoradas")
            asyncio.run(record(lost))
            ignored_ids = [f["track_id"] for f in
                           c.get("/api/admin/failures?ignored=true", headers=adm).json()]
            ok(lost in ignored_ids, True, "falhar de novo não desfaz o ignorar")

            asyncio.run(sql("INSERT INTO files (track_id, path, format, kind) VALUES ($1, '/tmp/x.mp3', 'mp3', 'permanent')",
                            lost))
            ignored_ids = [f["track_id"] for f in
                           c.get("/api/admin/failures?ignored=true", headers=adm).json()]
            ok(lost in ignored_ids, False, "baixada: some da lista")
    finally:
        asyncio.run(cleanup(tag, [track, lost]))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
