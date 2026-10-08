"""Sessões compartilhadas de ponta a ponta: REST + WebSocket com duas
pessoas conectadas ao mesmo tempo.

Uso: docker compose exec -T api python tests/test_sessions.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.auth import repository as auth_repo
from app.auth.security import create_access_token, hash_password
from app.core.db import close_pool, create_pool
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


def t(name, secs=200):
    return {"provider": "spotify", "external_id": f"sess-{name}", "title": name, "artist": "Banda",
            "duration_seconds": secs}


async def setup(tag):
    pool = await create_pool()
    users = {}
    for name in ("lucas", "marina", "joao"):
        users[name] = await auth_repo.create_user(pool, f"s_{name}_{tag}", hash_password("x" * 12), name=name)
    await close_pool()
    return {k: (str(v["id"]), create_access_token(str(v["id"]), False)) for k, v in users.items()}


async def cleanup(ids):
    pool = await create_pool()
    await pool.execute("DELETE FROM listen_sessions WHERE owner_id = ANY($1::uuid[])", ids)
    await pool.execute("DELETE FROM users WHERE id = ANY($1::uuid[])", ids)
    await close_pool()


def recv(ws, kind, limit=10):
    """Próxima mensagem do tipo [kind] (pula as outras, ex.: online/offline)."""
    for _ in range(limit):
        message = ws.receive_json()
        if message["type"] == kind:
            return message
    raise AssertionError(f"não chegou {kind}")


def main():
    tag = secrets.token_hex(3)
    users = asyncio.run(setup(tag))
    h = {k: {"Authorization": f"Bearer {tok}"} for k, (_, tok) in users.items()}
    uid = {k: i for k, (i, _) in users.items()}
    tok = {k: tk for k, (_, tk) in users.items()}
    try:
        with TestClient(app) as c:
            print("=== criar e convidar ===")
            r = c.post("/api/sessions", json={"name": "Sexta", "pause_mode": "all"}, headers=h["lucas"])
            ok(r.status_code, 201, "cria a sessão")
            sid = r.json()["id"]
            ok((r.json()["owner"]["id"], r.json()["members"][0]["status"]), (uid["lucas"], "joined"),
               "dono já está dentro")
            ok(c.get("/api/sessions/me", headers=h["marina"]).json(), {"current": None, "invites": []},
               "marina sem sessão nem convite")
            ok(c.post(f"/api/sessions/{sid}/invite", json={"user_ids": [uid["marina"]]},
                      headers=h["lucas"]).status_code, 204, "convida a marina")
            invites = c.get("/api/sessions/me", headers=h["marina"]).json()["invites"]
            ok((len(invites), invites[0]["name"], invites[0]["invited_by"]["id"]), (1, "Sexta", uid["lucas"]),
               "marina vê o convite")
            ok(c.post(f"/api/sessions/{sid}/join", headers=h["joao"]).status_code, 403,
               "sem convite não entra")
            ok(c.post(f"/api/sessions/{sid}/join", headers=h["marina"]).status_code, 200, "marina entra")
            ok(c.get("/api/sessions/me", headers=h["marina"]).json()["current"]["id"], sid,
               "sessão atual da marina")

            print("=== tempo real com duas pessoas ===")
            with c.websocket_connect(f"/api/sessions/{sid}/ws?token={tok['lucas']}") as wl, \
                    c.websocket_connect(f"/api/sessions/{sid}/ws?token={tok['marina']}") as wm:
                hello = recv(wl, "hello")
                ok(hello["session"]["pause_mode"], "all", "hello com a sessão")
                recv(wm, "hello")
                wl.send_json({"type": "ping", "t0": 123})
                pong = recv(wl, "pong")
                ok((pong["t0"], pong["server_now"] > 0), (123, True), "ping/pong para sincronizar relógio")

                wl.send_json({"type": "action", "action": "play_list",
                              "tracks": [t("A"), t("B"), t("C")], "index": 0})
                pl = recv(wl, "playback")["playback"]
                pm = recv(wm, "playback")
                ok((pm["playback"]["version"], pm["by"]), (pl["version"], f"s_lucas_{tag}"),
                   "a marina recebe o mesmo estado")
                ok(pm["playback"]["queue"][0]["track"]["title"], "A", "tocando A para os dois")

                wm.send_json({"type": "action", "action": "add", "track": t("D")})
                ok([e["track"]["title"] for e in recv(wl, "playback")["playback"]["queue"]],
                   ["A", "B", "C", "D"], "fila da marina chega para o lucas")
                recv(wm, "playback")
                wm.send_json({"type": "action", "action": "next"})
                pb = recv(wl, "playback")["playback"]
                recv(wm, "playback")
                ok(pb["queue"][pb["index"]]["track"]["title"], "B", "próxima vale para todos")

                wm.send_json({"type": "action", "action": "pause"})
                ok(recv(wl, "playback")["playback"]["playing"], False, "pausa para todos (modo 'all')")
                recv(wm, "playback")
                wl.send_json({"type": "action", "action": "resume"})
                recv(wl, "playback")
                recv(wm, "playback")

                print("=== configurações (só o dono) ===")
                ok(c.patch(f"/api/sessions/{sid}", json={"pause_mode": "individual"},
                           headers=h["marina"]).status_code, 403, "marina não muda o modo")
                r = c.patch(f"/api/sessions/{sid}", json={"pause_mode": "individual"}, headers=h["lucas"])
                ok(r.json()["pause_mode"], "individual", "dono muda para pausa individual")
                ok(recv(wm, "session")["session"]["pause_mode"], "individual", "todos ficam sabendo")
                wm.send_json({"type": "action", "action": "pause"})
                wm.send_json({"type": "ping", "t0": 1})
                ok(wm.receive_json()["type"], "pong", "pausa individual não muda o estado de ninguém")

                wm.send_json({"type": "action", "action": "voar", "id": "x1"})
                err = recv(wm, "error")
                ok((err["id"], "desconhecida" in err["message"]), ("x1", True), "ação inválida volta erro")

                print("=== remover pessoa ===")
                ok(c.delete(f"/api/sessions/{sid}/members/{uid['marina']}", headers=h["marina"]).status_code,
                   403, "só o dono remove")
                ok(c.delete(f"/api/sessions/{sid}/members/{uid['marina']}", headers=h["lucas"]).status_code,
                   204, "dono remove a marina")
                ok(recv(wm, "removed")["type"], "removed", "a marina é avisada")
                ok(c.get("/api/sessions/me", headers=h["marina"]).json()["current"], None,
                   "marina fora da sessão")

            print("=== acesso ao WebSocket ===")
            try:
                with c.websocket_connect(f"/api/sessions/{sid}/ws?token=invalido") as ws:
                    ws.receive_json()
                ok(True, False, "token inválido")
            except WebSocketDisconnect as exc:
                ok(exc.code, 4401, "token inválido: 4401 (o app renova e reconecta)")
            try:
                with c.websocket_connect(f"/api/sessions/{sid}/ws?token={tok['joao']}") as ws:
                    ws.receive_json()
                ok(True, False, "não participante")
            except WebSocketDisconnect as exc:
                ok(exc.code, 4403, "não participante: 4403")

            with c.websocket_connect(f"/api/sessions/{sid}/ws") as ws:
                ws.send_json({"type": "auth", "token": tok["lucas"]})
                ok(recv(ws, "hello")["type"], "hello", "token na primeira mensagem")
            try:
                with c.websocket_connect(f"/api/sessions/{sid}/ws") as ws:
                    ws.send_json({"type": "auth", "token": "invalido"})
                    ws.receive_json()
                ok(True, False, "token inválido na mensagem")
            except WebSocketDisconnect as exc:
                ok(exc.code, 4401, "token inválido na mensagem: 4401")

            print("=== ação por HTTP e encerrar ===")
            r = c.post(f"/api/sessions/{sid}/actions", json={"action": "seek", "position_ms": 30000},
                       headers=h["lucas"])
            ok((r.status_code, r.json()["position_ms"]), (200, 30000), "ação pelo HTTP")
            with c.websocket_connect(f"/api/sessions/{sid}/ws?token={tok['lucas']}") as wl:
                recv(wl, "hello")
                ok(c.delete(f"/api/sessions/{sid}", headers=h["marina"]).status_code, 403, "só o dono encerra")
                ok(c.delete(f"/api/sessions/{sid}", headers=h["lucas"]).status_code, 204, "dono encerra")
                ok(recv(wl, "ended")["type"], "ended", "todos recebem 'encerrada'")
            ok(c.get(f"/api/sessions/{sid}", headers=h["lucas"]).status_code, 404, "sessão encerrada some")

            print("=== uma sessão por vez; sair esvazia ===")
            s2 = c.post("/api/sessions", json={"name": "Uma"}, headers=h["lucas"]).json()["id"]
            s3 = c.post("/api/sessions", json={"name": "Outra"}, headers=h["lucas"]).json()["id"]
            ok(c.get("/api/sessions/me", headers=h["lucas"]).json()["current"]["id"], s3,
               "criar outra sai da anterior")
            ok(c.get(f"/api/sessions/{s2}", headers=h["lucas"]).status_code, 404,
               "a anterior, vazia, acabou")
            ok(c.post(f"/api/sessions/{s3}/leave", headers=h["lucas"]).status_code, 204, "sai da sessão")
            ok(c.get(f"/api/sessions/{s3}", headers=h["lucas"]).status_code, 404, "sem ninguém, acaba")
            ok(c.post("/api/sessions", json={"pause_mode": "x"}, headers=h["lucas"]).status_code, 422,
               "modo de pausa inválido")
    finally:
        asyncio.run(cleanup(list(uid.values())))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


main()
