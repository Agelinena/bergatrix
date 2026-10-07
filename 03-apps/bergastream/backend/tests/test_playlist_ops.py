"""Testes das alterações de playlist em lote (POST /api/playlists/ops):
refs temporários, reenvio seguro, edição offline × edição na web,
conflitos de nome e de exclusão, permissões.

Uso: docker compose exec -T api python tests/test_playlist_ops.py
Cria usuários e faixas temporários e apaga tudo ao final.
"""
from __future__ import annotations

import asyncio
import secrets
import sys
import uuid
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


def op(type_, **kw):
    return {"op_id": str(uuid.uuid4()), "type": type_, **kw}


async def main():
    pool = await create_pool()
    await get_redis()
    tag = secrets.token_hex(3)
    users = {}
    for name in ("dono", "leitor", "fora"):
        users[name] = await auth_repo.create_user(pool, f"o_{name}_{tag}", hash_password("x" * 12), name=f"O {name}")
    h = {k: {"Authorization": f"Bearer {create_access_token(str(v['id']), False)}"} for k, v in users.items()}
    # Faixas A..F inseridas direto (sem rede): o servidor acha pelo id externo.
    letters = "ABCDEF"
    tid = {}
    for i, letter in enumerate(letters):
        t = await pool.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds) VALUES ($1, 'Artista', $2) RETURNING id",
            f"{letter} {tag}", 100 + i)
        await pool.execute("INSERT INTO external_ids (track_id, provider, external_id) VALUES ($1, 'spotify', $2)",
                           t, f"op{tag}{letter}")
        tid[letter] = str(t)

    def track(letter):
        return {"provider": "spotify", "external_id": f"op{tag}{letter}", "title": f"{letter} {tag}",
                "artist": "Artista", "duration_seconds": 100}

    playlist_ids: list[str] = []
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            async def send(ops, who="dono"):
                r = await c.post("/api/playlists/ops", json={"ops": ops}, headers=h[who])
                assert r.status_code == 200, r.text
                return r.json()

            async def order(pid):
                d = (await c.get(f"/api/playlists/{pid}", headers=h["dono"])).json()
                return [t["title"].split()[0] for t in d["tracks"]]

            print("=== playlist criada offline: refs temporários no mesmo lote ===")
            batch = [
                op("create", ref="tmp:p1", name="Offline"),
                op("add", playlist="tmp:p1", track=track("A"), ref="tmp:tA"),
                op("add", playlist="tmp:p1", track=track("B"), ref="tmp:tB"),
                op("move", playlist="tmp:p1", track="tmp:tA", after="tmp:tB"),
            ]
            res = await send(batch)
            ok([r["status"] for r in res["results"]], ["applied"] * 4, "tudo aplicado")
            pid = res["refs"]["tmp:p1"]
            playlist_ids.append(pid)
            ok(res["refs"]["tmp:tA"], tid["A"], "ref da faixa vira o id do servidor")
            ok(await order(pid), ["B", "A"], "mover com refs")

            print("=== reenvio do mesmo lote (rede caiu antes da resposta) ===")
            again = await send(batch)
            ok([r["status"] for r in again["results"]], ["applied"] * 4, "mesmos resultados")
            ok(again["refs"]["tmp:p1"], pid, "mesma playlist")
            n = await pool.fetchval("SELECT count(*) FROM playlists WHERE name = 'Offline' AND user_id = $1",
                                    users["dono"]["id"])
            ok(n, 1, "não duplicou a playlist")
            ok(await order(pid), ["B", "A"], "não duplicou faixas nem moveu de novo")

            print("=== celular offline × web: intenções se combinam ===")
            r = await c.post("/api/playlists", json={"name": "Roadtrip"}, headers=h["dono"])
            rid = r.json()["id"]
            playlist_ids.append(rid)
            for letter in "ABC":
                await c.post(f"/api/playlists/{rid}/tracks", json=track(letter), headers=h["dono"])
            base_updated = (await c.get(f"/api/playlists/{rid}", headers=h["dono"])).json()["updated_at"]
            # Na web, enquanto o celular está sem servidor:
            await c.post(f"/api/playlists/{rid}/tracks", json=track("D"), headers=h["dono"])
            await c.patch(f"/api/playlists/{rid}", json={"name": "Nome da web"}, headers=h["dono"])
            # O celular (que viu [A, B, C] e "Roadtrip") manda a fila ao reconectar:
            res = await send([
                op("remove", playlist=rid, track=tid["B"]),
                op("add", playlist=rid, track=track("E"), ref="tmp:tE"),
                op("move", playlist=rid, track=tid["C"], after=None, before=tid["A"]),
                op("rename", playlist=rid, name="Nome do celular", base="Roadtrip"),
            ])
            ok([r["status"] for r in res["results"]], ["applied", "applied", "applied", "conflict"],
               "faixas aplicadas; nome em conflito")
            ok(res["results"][3]["current"], {"name": "Nome da web"}, "conflito informa o nome atual")
            ok(await order(rid), ["C", "A", "D", "E"], "D da web e E do celular ficam; B sai; C no topo")
            name = (await c.get(f"/api/playlists/{rid}", headers=h["dono"])).json()["name"]
            ok(name, "Nome da web", "nome da web não foi sobrescrito")
            res = await send([op("rename", playlist=rid, name="Nome do celular", base="Nome da web")])
            ok(res["results"][0]["status"], "applied", "'usar o meu' depois do conflito")
            res = await send([op("rename", playlist=rid, name="Nome do celular", base="Roadtrip")])
            ok(res["results"][0]["status"], "applied", "mesmo nome nos dois lados não é conflito")

            print("=== mover com vizinhas que sumiram ===")
            await send([op("remove", playlist=rid, track=tid["D"])])
            res = await send([op("move", playlist=rid, track=tid["E"], after=tid["D"], before=tid["A"])])
            ok(await order(rid), ["C", "E", "A"], "âncora 'depois' sumiu: usa 'antes'")
            await send([op("move", playlist=rid, track=tid["C"], after=tid["F"], before=tid["D"])])
            ok(await order(rid), ["C", "E", "A"], "nenhuma âncora existe: fica onde está")
            res = await send([op("move", playlist=rid, track=tid["B"], after=None)])
            ok(res["results"][0]["status"], "applied", "mover faixa que já saiu não é erro")
            res = await send([op("remove", playlist=rid, track=tid["B"])])
            ok(res["results"][0]["status"], "applied", "remover de novo não é erro")

            print("=== apagar: conflito se mudou depois que o aparelho viu ===")
            res = await send([op("delete", playlist=rid, base_updated_at=base_updated)])
            ok(res["results"][0]["status"], "conflict", "mudou na web: não apaga")
            ok(res["results"][0]["current"]["name"], "Nome do celular", "informa o estado atual")
            ok((await c.get(f"/api/playlists/{rid}", headers=h["dono"])).status_code, 200, "continua existindo")
            res = await send([op("delete", playlist=rid, base_updated_at=base_updated, force=True)])
            ok(res["results"][0]["status"], "applied", "'apagar mesmo assim'")
            ok((await c.get(f"/api/playlists/{rid}", headers=h["dono"])).status_code, 404, "apagada")

            print("=== playlist apagada em outro lugar / permissões / dependências ===")
            res = await send([op("add", playlist=rid, track=track("F")), op("rename", playlist=rid, name="x", base="y")])
            ok([r["status"] for r in res["results"]], ["gone", "gone"], "alterações em playlist apagada")
            await c.put(f"/api/playlists/{pid}/members/{users['leitor']['id']}", json={"role": "viewer"},
                        headers=h["dono"])
            res = await send([op("add", playlist=pid, track=track("C"))], who="leitor")
            ok(res["results"][0]["status"], "forbidden", "quem só vê não altera")
            res = await send([op("rename", playlist=pid, name="x")], who="fora")
            ok(res["results"][0]["status"], "gone", "de fora não vê a playlist")
            res = await send([op("move", playlist=pid, track="tmp:naoexiste", after=None)])
            ok(res["results"][0]["status"], "retry", "depende de faixa ainda não enviada: espera")
            res = await send([op("delete", playlist=pid, base_updated_at="2000-01-01T00:00:00+00:00")], who="leitor")
            ok(res["results"][0]["status"], "forbidden", "só o dono apaga")

            print("=== validação ===")
            r = await c.post("/api/playlists/ops", json={"ops": []}, headers=h["dono"])
            ok(r.status_code, 422, "lote vazio")
            r = await c.post("/api/playlists/ops", json={"ops": [op("create", name="x")]})
            ok(r.status_code, 401, "exige login")
            res = await send([op("create", ref="tmp:v", name="  ")])
            ok(res["results"][0]["status"], "invalid", "nome vazio")
    finally:
        for p in playlist_ids:
            await pool.execute("DELETE FROM playlists WHERE id = $1", p)
        await pool.execute("DELETE FROM playlists WHERE user_id = ANY($1::uuid[])",
                           [u["id"] for u in users.values()])
        for t in tid.values():
            await pool.execute("DELETE FROM tracks WHERE id = $1", t)
        for u in users.values():
            await pool.execute("DELETE FROM users WHERE id = $1", u["id"])
        await close_redis()
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
