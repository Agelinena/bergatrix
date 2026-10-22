"""Login pelo Authentik (OIDC) com um Authentik falso: conta antiga ligada
pelo username (mesmas playlists), depois pelo sub; conta nova; grupo; PKCE
do app; retorno só para endereços permitidos; senha desligada.

Uso: docker compose exec -T api python tests/test_oidc.py
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from starlette.testclient import TestClient

from app.auth import oidc
from app.auth import repository as auth_repo
from app.auth.security import hash_password
from app.config import settings
from app.core.db import close_pool, create_pool
from app.main import app

P = F = 0
ISSUER = "https://authentik.example.com/application/o/bergastream/"


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


class FakeAuthentik:
    """Responde discovery, token e JWKS; o próximo login é [user]."""

    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.user: dict = {}
        self.codes: dict[str, str] = {}  # code → nonce (vem do authorize)
        self.wrong_nonce = False

    def jwks(self) -> dict:
        jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self.key.public_key()))
        return {"keys": [{**jwk, "kid": "k1", "use": "sig", "alg": "RS256"}]}

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("/.well-known/openid-configuration"):
            return httpx.Response(200, json={
                "issuer": ISSUER,
                "authorization_endpoint": "https://authentik.example.com/application/o/authorize/",
                "token_endpoint": "https://authentik.example.com/application/o/token/",
                "jwks_uri": "https://authentik.example.com/application/o/bergastream/jwks/"})
        if path.endswith("/jwks/"):
            return httpx.Response(200, json=self.jwks())
        if path.endswith("/token/"):
            form = parse_qs(request.content.decode())
            code = form["code"][0]
            if form.get("client_secret") != ["segredo"] or code not in self.codes:
                return httpx.Response(400, json={"error": "invalid_grant"})
            now = int(time.time())
            claims = {"iss": ISSUER, "aud": "bergastream", "iat": now, "exp": now + 300,
                      "nonce": "outro" if self.wrong_nonce else self.codes.pop(code), **self.user}
            token = jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": "k1"})
            return httpx.Response(200, json={"id_token": token, "access_token": "x"})
        return httpx.Response(404)


def pkce():
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def login(c: TestClient, fake: FakeAuthentik, redirect: str = "/") -> tuple[httpx.Response, str]:
    """start → (Authentik) → callback. Devolve a resposta do callback e o verifier."""
    verifier, challenge = pkce()
    r = c.get("/api/auth/oidc/start", params={"redirect": redirect, "challenge": challenge},
              follow_redirects=False)
    assert r.status_code == 302, r.text
    query = parse_qs(urlsplit(r.headers["location"]).query)
    code = secrets.token_hex(8)
    fake.codes[code] = query["nonce"][0]
    cb = c.get("/api/auth/oidc/callback", params={"code": code, "state": query["state"][0]},
               follow_redirects=False)
    return cb, verifier


def one_time_code(resp: httpx.Response) -> str:
    return parse_qs(urlsplit(resp.headers["location"]).query)["oidc_code"][0]


async def setup(tag):
    pool = await create_pool()
    user = await auth_repo.create_user(pool, f"lucas{tag}", hash_password("x" * 12), name=f"Lucas {tag}")
    playlist = await pool.fetchval(
        "INSERT INTO playlists (user_id, name) VALUES ($1, 'Rock de antes') RETURNING id", user["id"])
    await close_pool()
    return str(user["id"]), str(playlist)


async def cleanup(tag):
    pool = await create_pool()
    await pool.execute("DELETE FROM users WHERE username ILIKE $1 OR name ILIKE $2",
                       f"%{tag}%", f"%{tag}%")
    await close_pool()


def main():
    tag = secrets.token_hex(3)
    old = {k: getattr(settings, k) for k in (
        "oidc_issuer", "oidc_client_id", "oidc_client_secret", "oidc_redirect_uri",
        "oidc_required_group", "oidc_admin_group", "password_login")}
    settings.oidc_issuer, settings.oidc_client_id = ISSUER, "bergastream"
    settings.oidc_client_secret = "segredo"
    settings.oidc_redirect_uri = "https://bergastream.example.com/api/auth/oidc/callback"
    settings.oidc_required_group, settings.oidc_admin_group = "bergastream-users", ""
    settings.password_login = "auto"
    fake = FakeAuthentik()
    oidc.set_client(oidc.OIDCClient(httpx.AsyncClient(transport=httpx.MockTransport(fake.handler))))
    user_id, playlist_id = asyncio.run(setup(tag))
    try:
        with TestClient(app) as c:
            print("=== configuração ===")
            cfg = c.get("/api/auth/config").json()
            ok((cfg["oidc_enabled"], cfg["password_login_enabled"]), (True, False),
               "OIDC ligado; senha desligada (auto)")
            r = c.post("/api/auth/login", json={"username": f"lucas{tag}", "password": "x" * 12})
            ok(r.status_code, 403, "login por senha recusado")

            print("=== conta de antes: ligada pelo username ===")
            fake.user = {"sub": f"sub-lucas-{tag}", "preferred_username": f"lucas{tag}",
                         "email": f"lucas{tag}@example.com", "name": "Lucas", "groups": ["bergastream-users"]}
            cb, verifier = login(c, fake)
            ok((cb.status_code, cb.headers["location"].startswith("/?oidc_code=")), (302, True),
               "volta para o app web com o código")
            code = one_time_code(cb)
            ok(c.post("/api/auth/oidc/exchange", json={"code": code, "verifier": "x" * 43}).status_code,
               401, "verificador errado (PKCE do app) não troca")
            cb, verifier = login(c, fake)
            code = one_time_code(cb)
            tokens = c.post("/api/auth/oidc/exchange", json={"code": code, "verifier": verifier})
            ok((tokens.status_code, tokens.json()["user"]["id"]), (200, user_id), "mesmo usuário de antes")
            ok(c.post("/api/auth/oidc/exchange", json={"code": code, "verifier": verifier}).status_code,
               401, "código vale uma vez só")
            h = {"Authorization": f"Bearer {tokens.json()['access_token']}"}
            names = [p["name"] for p in c.get("/api/me/playlists", headers=h).json()]
            ok("Rock de antes" in names, True, "as playlists continuam dele")

            print("=== depois: pelo sub (mesmo mudando o username) ===")
            fake.user = {**fake.user, "preferred_username": f"lucas-novo-{tag}"}
            cb, verifier = login(c, fake)
            again = c.post("/api/auth/oidc/exchange", json={"code": one_time_code(cb), "verifier": verifier})
            ok(again.json()["user"]["id"], user_id, "ligado pelo sub")

            print("=== conta nova, grupo e retorno ===")
            fake.user = {"sub": f"sub-marina-{tag}", "preferred_username": f"marina{tag}",
                         "email": f"marina{tag}@example.com", "name": f"Marina {tag}",
                         "groups": ["bergastream-users"]}
            cb, verifier = login(c, fake, redirect="com.bergatrix.bergastream://auth")
            ok(cb.headers["location"].startswith("com.bergatrix.bergastream://auth?oidc_code="), True,
               "Android: volta pelo esquema do app")
            novo = c.post("/api/auth/oidc/exchange", json={"code": one_time_code(cb), "verifier": verifier})
            ok((novo.status_code, novo.json()["user"]["username"]), (200, f"marina{tag}"), "conta nova criada")

            cb, _ = login(c, fake, redirect="http://127.0.0.1:53111/callback")
            ok(cb.headers["location"].startswith("http://127.0.0.1:53111/callback?oidc_code="), True,
               "computador: volta pelo endereço local")

            fake.user = {**fake.user, "sub": f"sub-joao-{tag}", "preferred_username": f"joao{tag}",
                         "groups": ["outra-coisa"]}
            cb, _ = login(c, fake)
            ok((cb.status_code, "não tem acesso" in cb.text), (200, True), "fora do grupo: recusado")

            _, challenge = pkce()
            r = c.get("/api/auth/oidc/start", params={"redirect": "https://evil.example.com/x",
                                                      "challenge": challenge}, follow_redirects=False)
            ok((r.status_code, "não permitido" in r.text), (200, True), "retorno para fora: recusado")

            fake.user = {**fake.user, "groups": ["bergastream-users"]}
            fake.wrong_nonce = True
            cb, _ = login(c, fake)
            ok("expirado ou repetido" in cb.text, True, "nonce diferente: recusado")
            fake.wrong_nonce = False

            r = c.get("/api/auth/oidc/callback", params={"code": "x", "state": "nao-existe"},
                      follow_redirects=False)
            ok("Login expirado" in r.text, True, "state desconhecido: recusado")
    finally:
        for k, v in old.items():
            setattr(settings, k, v)
        oidc.set_client(None)
        asyncio.run(cleanup(tag))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
