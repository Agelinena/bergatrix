"""Aparelhos conectados ("Tocar em…"): presença, aparelho ativo, estado,
comandos remotos e transferência entre aparelhos.

Uso: docker compose exec -T api python tests/test_devices.py
"""
from __future__ import annotations

import asyncio
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


async def setup(tag):
    pool = await create_pool()
    users = {}
    for name in ("lucas", "marina"):
        users[name] = await auth_repo.create_user(pool, f"d_{name}_{tag}", hash_password("x" * 12), name=f"{name} {tag}")
    await close_pool()
    return {k: (str(v["id"]), create_access_token(str(v["id"]), False)) for k, v in users.items()}


async def cleanup(ids):
    pool = await create_pool()
    await pool.execute("DELETE FROM users WHERE id = ANY($1::uuid[])", ids)
    await close_pool()


def recv(ws, kind, limit=10):
    for _ in range(limit):
        message = ws.receive_json()
        if message["type"] == kind:
            return message
    raise AssertionError(f"sem mensagem {kind}")


OPEN = []


def recv_until(ws, kind, pred, limit=10):
    for _ in range(limit):
        message = recv(ws, kind)
        if pred(message):
            return message
    raise AssertionError(f"sem {kind} esperado")


def connect(c, token, device_id, name, platform):
    ws = c.websocket_connect("/api/devices/ws").__enter__()
    OPEN.append(ws)
    ws.send_json({"type": "auth", "token": token,
                  "device": {"id": device_id, "name": name, "platform": platform}})
    return ws


def main():
    import secrets
    tag = secrets.token_hex(3)
    users = asyncio.run(setup(tag))
    tok = {k: v[1] for k, v in users.items()}
    try:
        with TestClient(app) as c:
            print("=== presença ===")
            web = connect(c, tok["lucas"], "dev-web", "Chrome", "web")
            hello = recv(web, "hello")
            ok((hello["device_id"], hello["active"], [d["id"] for d in hello["devices"]]),
               ("dev-web", None, ["dev-web"]), "hello com a lista de aparelhos")
            phone = connect(c, tok["lucas"], "dev-phone", "Galaxy", "android")
            recv(phone, "hello")
            listing = recv(web, "devices")
            ok(sorted(d["name"] for d in listing["devices"]), ["Chrome", "Galaxy"],
               "o navegador vê o celular entrar")
            other = connect(c, tok["marina"], "dev-m", "PC da Marina", "windows")
            ok([d["id"] for d in recv(other, "hello")["devices"]], ["dev-m"],
               "cada pessoa só vê os próprios aparelhos")

            print("=== aparelho ativo e estado ===")
            phone.send_json({"type": "activate"})
            ok(recv(web, "devices")["active"], "dev-phone", "celular virou o ativo")
            recv(phone, "devices")
            phone.send_json({"type": "state", "state": {"track": {"title": "A"}, "status": "tocando"}})
            st = recv(web, "state")
            ok((st["state"]["track"]["title"], st["from"], "at" in st["state"]), ("A", "dev-phone", True),
               "estado do ativo chega aos outros")
            web.send_json({"type": "state", "state": {"track": {"title": "X"}}})
            web.send_json({"type": "ping", "t0": 1})
            ok(recv(web, "pong")["t0"], 1, "estado de quem não é o ativo é ignorado")

            print("=== controle remoto ===")
            web.send_json({"type": "command", "command": {"action": "next"}})
            cmd = recv(phone, "command")
            ok((cmd["command"], cmd["from"]), ({"action": "next"}, "Chrome"), "comando chega ao ativo")
            phone.send_json({"type": "command", "command": {"action": "next"}})
            ok(recv(phone, "error")["type"], "error", "o ativo não manda comando para si")

            print("=== tocar em outro aparelho ===")
            web.send_json({"type": "transfer", "to": "dev-web"})
            ok(recv(phone, "handoff")["to"], "dev-web", "o ativo é avisado para passar a vez")
            phone.send_json({"type": "handoff_state", "state": {"queue": "fila", "position_ms": 42000}})
            here = recv(web, "play_here")
            ok(here["state"], {"queue": "fila", "position_ms": 42000}, "fila e ponto chegam ao escolhido")
            ok(recv(phone, "devices")["active"], "dev-web", "agora o navegador é o ativo")

            web.send_json({"type": "transfer", "to": "dev-phone", "state": {"queue": "da web"}})
            ok(recv(phone, "play_here")["state"], {"queue": "da web"},
               "o ativo transfere mandando o próprio estado")

            print("=== saída e reconexão ===")
            phone.__exit__(None, None, None)
            OPEN.remove(phone)
            listing = recv_until(web, "devices", lambda m: len(m["devices"]) == 1)
            ok((listing["active"], [d["id"] for d in listing["devices"]]), (None, ["dev-web"]),
               "o ativo saiu: ninguém toca")
            web2 = connect(c, tok["lucas"], "dev-web", "Chrome", "web")
            recv(web2, "hello")
            try:
                for _ in range(5):
                    web.receive_json()
                ok(True, False, "aba antiga fecha")
            except WebSocketDisconnect as exc:
                ok(exc.code, 4409, "mesmo aparelho de novo: a conexão antiga fecha (4409)")
            bad = c.websocket_connect("/api/devices/ws").__enter__()
            OPEN.append(bad)
            bad.send_json({"type": "auth", "token": "x", "device": {"id": "a", "platform": "web"}})
            try:
                bad.receive_json()
                ok(True, False, "token inválido")
            except WebSocketDisconnect as exc:
                ok(exc.code, 4401, "token inválido: 4401")
            for ws in OPEN:
                try:
                    ws.__exit__(None, None, None)
                except Exception:
                    pass
    finally:
        asyncio.run(cleanup([v[0] for v in users.values()]))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
