"""Testes da autenticação (login, renovação com rotação, logout, limite de
tentativas, rotas protegidas e token de stream).

Uso: docker compose exec -T api python tests/test_auth.py
Cria um usuário temporário e apaga tudo ao final.
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
import jwt

from app.auth import repository as repo
from app.auth import security
from app.config import settings
from app.core.db import close_pool, create_pool
from app.core.redis import close_redis, get_redis
from app.main import app

P = 0
F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def okv(v, m=""):
    ok(bool(v), True, m)


def t1_security():
    print("\n=== 1. Senhas e tokens ===")
    h = security.hash_password("segredo123")
    okv(security.verify_password(h, "segredo123"), "senha certa")
    okv(not security.verify_password(h, "errada"), "senha errada")
    okv(not security.verify_password(None, "qualquer"), "usuário sem senha")
    uid = str(uuid.uuid4())
    payload = security.decode_token(security.create_access_token(uid, False), "access")
    ok(payload["sub"], uid, "access token decodifica")
    try:
        security.decode_token(security.create_stream_token(uid, "x"), "access")
        okv(False, "stream token não serve como access")
    except security.TokenError:
        okv(True, "stream token não serve como access")
    expired = jwt.encode(
        {"sub": uid, "typ": "access", "iss": "bergastream",
         "exp": datetime.now(timezone.utc) - timedelta(seconds=5)},
        security._secret, algorithm="HS256",
    )
    try:
        security.decode_token(expired, "access")
        okv(False, "token vencido recusado")
    except security.TokenError:
        okv(True, "token vencido recusado")
    forged = jwt.encode({"sub": uid, "typ": "access", "iss": "bergastream",
                         "exp": datetime.now(timezone.utc) + timedelta(minutes=5)},
                        "outro-segredo", algorithm="HS256")
    try:
        security.decode_token(forged, "access")
        okv(False, "assinatura falsa recusada")
    except security.TokenError:
        okv(True, "assinatura falsa recusada")


async def t2_api(c: httpx.AsyncClient, username: str, password: str):
    print("\n=== 2. Login, me e rotas protegidas ===")
    r = await c.get("/api/auth/config")
    ok(r.status_code, 200, "config é pública")
    ok((await c.get("/api/search", params={"q": "x"})).status_code, 401, "busca sem token: 401")
    ok((await c.get("/api/me/playlists")).status_code, 401, "playlists sem token: 401")
    ok((await c.post("/api/auth/login", json={"username": username, "password": "errada"})).status_code,
       401, "senha errada: 401")
    ok((await c.post("/api/auth/login", json={"username": "naoexiste_" + username, "password": "x"})).status_code,
       401, "usuário inexistente: 401")
    r = await c.post("/api/auth/login", json={"username": username.upper(), "password": password})
    ok(r.status_code, 200, "login certo (username sem diferenciar maiúsculas)")
    pair = r.json()
    ok(pair["user"]["username"], username, "devolve o usuário")
    ok(r.headers.get("cache-control"), "no-store", "resposta não é cacheada")
    auth = {"Authorization": f"Bearer {pair['access_token']}"}
    r = await c.get("/api/auth/me", headers=auth)
    ok(r.json().get("username"), username, "/me com token")
    ok((await c.get("/api/me/playlists", headers=auth)).status_code, 200, "playlists com token")
    ok((await c.get("/api/auth/me", headers={"Authorization": "Bearer lixo"})).status_code, 401, "token inválido: 401")
    return pair, auth


async def t3_refresh(c: httpx.AsyncClient, username: str, password: str, pair: dict):
    print("\n=== 3. Renovação com rotação e detecção de reuso ===")
    old = pair["refresh_token"]
    r = await c.post("/api/auth/refresh", json={"refresh_token": old})
    ok(r.status_code, 200, "renovação ok")
    new = r.json()["refresh_token"]
    okv(new != old, "refresh token novo")
    r = await c.post("/api/auth/refresh", json={"refresh_token": old})
    ok(r.status_code, 401, "reusar o token antigo: 401")
    r = await c.post("/api/auth/refresh", json={"refresh_token": new})
    ok(r.status_code, 401, "reuso revoga a família (o novo também cai)")
    ok((await c.post("/api/auth/refresh", json={"refresh_token": "nada"})).status_code, 401, "token desconhecido: 401")

    print("\n=== 4. Logout ===")
    r = await c.post("/api/auth/login", json={"username": username, "password": password})
    rt = r.json()["refresh_token"]
    ok((await c.post("/api/auth/logout", json={"refresh_token": rt})).status_code, 204, "logout 204")
    ok((await c.post("/api/auth/refresh", json={"refresh_token": rt})).status_code, 401, "após logout: 401")


async def t4_rate_limit(c: httpx.AsyncClient, username: str, password: str):
    print("\n=== 5. Limite de tentativas ===")
    ip = {"X-Real-IP": "203.0.113.7"}
    for _ in range(settings.login_max_failures):
        await c.post("/api/auth/login", json={"username": username, "password": "errada"}, headers=ip)
    r = await c.post("/api/auth/login", json={"username": username, "password": password}, headers=ip)
    ok(r.status_code, 429, "bloqueia após falhas (mesmo com a senha certa)")
    okv(int(r.headers.get("retry-after", 0)) > 0, "informa Retry-After")
    r = await c.post("/api/auth/login", json={"username": username, "password": password},
                     headers={"X-Real-IP": "203.0.113.8"})
    ok(r.status_code, 200, "outro IP não é afetado")


async def t5_stream_and_admin(c: httpx.AsyncClient, auth: dict, user_id: str):
    print("\n=== 6. Token de stream, admin e playlists alheias ===")
    track = str(uuid.uuid4())
    other = str(uuid.uuid4())
    r = await c.post(f"/api/tracks/{track}/stream-token", headers=auth)
    ok(r.status_code, 200, "gera token de stream")
    token = r.json()["token"]
    ok((await c.get(f"/api/tracks/{track}/stream")).status_code, 401, "stream sem token: 401")
    ok((await c.get(f"/api/tracks/{other}/stream", params={"t": token})).status_code, 401,
       "token de outra faixa: 401")
    ok((await c.get(f"/api/tracks/{track}/stream", params={"t": token})).status_code, 404,
       "token certo passa da autenticação (faixa não existe: 404)")
    ok((await c.get(f"/api/tracks/{track}/stream", params={"t": auth["Authorization"][7:]})).status_code, 401,
       "access token no ?t= não vale")
    ok((await c.post("/api/admin/cleanup", headers=auth)).status_code, 403, "limpeza exige admin")
    # 404 e não 405: o StaticFiles montado em "/" responde aos GET sem rota.
    okv((await c.get("/api/admin/cleanup", headers=auth)).status_code in (404, 405),
        "limpeza não aceita GET")
    ok((await c.get("/api/users", headers=auth)).status_code, 403, "lista de usuários exige admin")
    ok((await c.get(f"/api/users/{uuid.uuid4()}/playlists", headers=auth)).status_code, 404,
       "playlists de outro usuário: 404")
    ok((await c.get(f"/api/users/{user_id}/playlists", headers=auth)).status_code, 200,
       "as próprias playlists: 200")


async def main():
    t1_security()
    pool = await create_pool()
    r = await get_redis()
    username = "teste_auth_" + secrets.token_hex(4)
    password = secrets.token_urlsafe(12)
    row = await repo.create_user(pool, username, security.hash_password(password))
    try:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
            pair, auth = await t2_api(c, username, password)
            await t3_refresh(c, username, password, pair)
            await t4_rate_limit(c, username, password)
            await t5_stream_and_admin(c, auth, str(row["id"]))
    finally:
        await pool.execute("DELETE FROM users WHERE id = $1", row["id"])
        for key in await r.keys(f"bergastream:login_fail:{username}*"):
            await r.delete(key)
        for key in await r.keys(f"bergastream:login_fail:naoexiste_{username}*"):
            await r.delete(key)
        await close_redis()
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    asyncio.run(main())
