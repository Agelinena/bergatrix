"""Testes das playlists completas (Passo 8): CRUD, quem adicionou, ordem,
permissões (dono / edita / vê / de fora), foto e permanência ao apagar.

Uso: docker compose exec -T api python tests/test_playlists.py
Cria usuários e faixas temporários e apaga tudo ao final.
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


PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")


async def main():
    pool = await create_pool()
    await get_redis()
    tag = secrets.token_hex(3)
    users = {}
    for name in ("dono", "editor", "leitor", "fora"):
        row = await auth_repo.create_user(pool, f"t_{name}_{tag}", hash_password("x" * 12), name=f"T {name}")
        users[name] = row
    h = {k: {"Authorization": f"Bearer {create_access_token(str(v['id']), False)}"} for k, v in users.items()}
    # Faixas inseridas direto (sem rede); duas com arquivo pronto.
    track_ids = []
    for i in range(3):
        tid = await pool.fetchval(
            "INSERT INTO tracks (title, artist, album, duration_seconds) VALUES ($1, 'Artista', 'Álbum', $2) RETURNING id",
            f"Faixa {tag} {i}", 100 + i)
        await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1, 'spotify', $2)",
                           tid, f"sp{tag}{i}")
        if i < 2:
            await pool.execute("INSERT INTO files (track_id, path, size_bytes, format, kind) VALUES ($1, $2, 1000, 'mp3_192', 'cache')",
                               tid, f"/tmp/{tid}.mp3")
        track_ids.append(str(tid))
    playlist_ids: list[str] = []
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            print("=== criar, adicionar, detalhe ===")
            r = await c.post("/api/playlists", json={"name": "Roadtrip"}, headers=h["dono"])
            ok(r.status_code, 201, "cria")
            pid = r.json()["id"]
            playlist_ids.append(pid)
            ok(r.json()["role"], "owner", "dono é owner")
            for i in range(3):
                body = {"provider": "spotify", "external_id": f"sp{tag}{i}", "title": f"Faixa {tag} {i}",
                        "artist": "Artista", "duration_seconds": 100 + i}
                r = await c.post(f"/api/playlists/{pid}/tracks", json=body, headers=h["dono"])
                ok(r.status_code, 200, f"adiciona faixa {i}")
            r = await c.get(f"/api/playlists/{pid}", headers=h["dono"])
            d = r.json()
            ok([t["title"][-1] for t in d["tracks"]], ["0", "1", "2"], "ordem de adição")
            ok(d["tracks"][0]["added_by"]["name"], "T dono", "quem adicionou")
            ok((d["track_count"], d["duration_seconds"]), (3, 303), "contagem e duração")
            ok([t["ready"] for t in d["tracks"]], [True, True, False], "faixas prontas no servidor")
            ok(await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_ids[0]), "permanent", "faixa vira permanent")

            print("=== permissões ===")
            ok((await c.get(f"/api/playlists/{pid}", headers=h["fora"])).status_code, 404, "de fora não vê (404)")
            ok((await c.put(f"/api/playlists/{pid}/members/{users['editor']['id']}", json={"role": "editor"}, headers=h["dono"])).status_code, 204, "dono adiciona quem edita")
            ok((await c.put(f"/api/playlists/{pid}/members/{users['leitor']['id']}", json={"role": "viewer"}, headers=h["dono"])).status_code, 204, "dono adiciona quem vê")
            ok((await c.put(f"/api/playlists/{pid}/members/{users['fora']['id']}", json={"role": "editor"}, headers=h["editor"])).status_code, 403, "quem edita não muda pessoas")
            r = await c.get(f"/api/playlists/{pid}", headers=h["leitor"])
            ok((r.status_code, r.json()["role"]), (200, "viewer"), "quem vê abre")
            ok(r.json()["people_count"], 3, "3 pessoas")
            ok((await c.delete(f"/api/playlists/{pid}/tracks/{track_ids[0]}", headers=h["leitor"])).status_code, 403, "quem vê não remove")
            ok((await c.patch(f"/api/playlists/{pid}", json={"name": "X"}, headers=h["leitor"])).status_code, 403, "quem vê não renomeia")
            r = await c.patch(f"/api/playlists/{pid}", json={"name": "Roadtrip 2"}, headers=h["editor"])
            ok((r.status_code, r.json()["name"], r.json()["role"]), (200, "Roadtrip 2", "editor"), "quem edita renomeia")
            ok((await c.delete(f"/api/playlists/{pid}", headers=h["editor"])).status_code, 403, "quem edita não apaga")
            mine = {p["id"]: p["role"] for p in (await c.get("/api/me/playlists", headers=h["leitor"])).json()}
            ok(mine.get(pid), "viewer", "compartilhada aparece na lista de quem vê")

            print("=== ordem ===")
            r = await c.put(f"/api/playlists/{pid}/order", json={"track_ids": [track_ids[2], track_ids[0]]}, headers=h["editor"])
            ok(r.status_code, 204, "reordena")
            d = (await c.get(f"/api/playlists/{pid}", headers=h["dono"])).json()
            ok([t["track_id"] for t in d["tracks"]], [track_ids[2], track_ids[0], track_ids[1]], "nova ordem (faltantes no fim)")

            print("=== foto ===")
            r = await c.put(f"/api/playlists/{pid}/cover", files={"file": ("a.png", PNG, "image/png")}, headers=h["editor"])
            ok(r.status_code, 200, "envia foto")
            url = r.json()["cover_url"]
            ok(url.startswith(f"/api/playlists/{pid}/cover?v="), True, "cover_url versionada")
            r = await c.get(url)
            ok((r.status_code, r.content[:4]), (200, PNG[:4]), "foto pública pelo id")
            ok((await c.put(f"/api/playlists/{pid}/cover", files={"file": ("a.txt", b"x", "text/plain")}, headers=h["dono"])).status_code, 415, "recusa não-imagem")

            print("=== remover e apagar ===")
            r = await c.delete(f"/api/playlists/{pid}/tracks/{track_ids[1]}", headers=h["editor"])
            ok(r.json()["status"], "cache", "faixa sem playlist volta a cache")
            r2 = await c.post("/api/playlists", json={"name": "Outra"}, headers=h["dono"])
            pid2 = r2.json()["id"]
            playlist_ids.append(pid2)
            await c.post(f"/api/playlists/{pid2}/tracks", json={"provider": "spotify", "external_id": f"sp{tag}0", "title": "x", "artist": "y"}, headers=h["dono"])
            ok((await c.delete(f"/api/playlists/{pid}", headers=h["dono"])).status_code, 204, "dono apaga")
            ok(await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_ids[0]), "permanent", "faixa em outra playlist continua permanent")
            ok((await c.get(f"/api/playlists/{pid}", headers=h["dono"])).status_code, 404, "apagada some")
            ok((await c.get("/api/users/directory", headers=h["fora"])).status_code, 200, "diretório de usuários")
    finally:
        for pid in playlist_ids:
            await pool.execute("DELETE FROM playlists WHERE id = $1", pid)
        for tid in track_ids:
            await pool.execute("DELETE FROM tracks WHERE id = $1", tid)
        for u in users.values():
            await pool.execute("DELETE FROM users WHERE id = $1", u["id"])
        await close_redis()
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
