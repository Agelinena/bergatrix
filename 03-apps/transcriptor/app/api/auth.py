"""Login pelo Authentik (OpenID Connect), sessões e tokens pessoais da API.

Fluxo: /auth/login guarda state, nonce e PKCE no banco e manda o navegador ao
Authentik; /auth/callback troca o código pelos tokens (cliente confidencial +
PKCE), valida o id_token (assinatura pelo JWKS, issuer, audience, nonce),
confere o grupo e abre uma sessão. O cookie da sessão é aleatório e só o
hash dele fica no banco.

O servidor fala com o Authentik pelo endereço interno (OIDC_INTERNAL_URL),
mantendo o Host público: o Authentik monta o issuer pelo host.

A API também aceita `Authorization: Bearer trs_…` (token pessoal criado na
interface). Pedidos com cookie que mudam algo exigem o cabeçalho
`X-Transcriptor: 1` e a mesma origem (proteção contra CSRF).
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import logging
import re
import secrets
from dataclasses import dataclass
from time import monotonic
from urllib.parse import urlencode, urlsplit, urlunsplit

import httpx
import jwt
from fastapi import HTTPException, Request

from app.config import settings

logger = logging.getLogger("transcriptor.auth")

SESSION_COOKIE = "__Host-transcriptor" if settings.secure_cookies else "transcriptor"
STATE_TTL_SECONDS = 600
TOKEN_PREFIX = "trs_"
SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}
_NEXT_PATH = re.compile(r"^/(?!/)[^\\\s]*$")


class LoginError(Exception):
    """Falha mostrada à pessoa na tela de login."""


@dataclass(frozen=True)
class Identity:
    subject: str
    username: str
    email: str
    name: str
    groups: tuple[str, ...]


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def s256(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


def safe_next(path: str | None) -> str:
    return path if path and len(path) < 500 and _NEXT_PATH.match(path) else "/"


class OIDCClient:
    def __init__(self, client: httpx.AsyncClient | None = None):
        self._client = client or httpx.AsyncClient(timeout=10.0)
        self._discovery: dict | None = None
        self._keys: dict = {}
        self._keys_at = 0.0
        self._lock = asyncio.Lock()

    def _server_url(self, url: str) -> tuple[str, dict]:
        internal = settings.oidc_internal_url.rstrip("/")
        if not internal:
            return url, {}
        public, base = urlsplit(url), urlsplit(internal)
        target = urlunsplit((base.scheme, base.netloc, public.path, public.query, ""))
        return target, {"Host": public.netloc, "X-Forwarded-Proto": public.scheme or "https"}

    async def _get(self, url: str) -> dict:
        target, headers = self._server_url(url)
        response = await self._client.get(target, headers=headers)
        response.raise_for_status()
        return response.json()

    async def discovery(self) -> dict:
        if self._discovery is None:
            self._discovery = await self._get(settings.oidc_issuer.rstrip("/") + "/.well-known/openid-configuration")
        return self._discovery

    async def authorize_url(self, state: str, nonce: str, challenge: str) -> str:
        endpoint = (await self.discovery())["authorization_endpoint"]
        return endpoint + "?" + urlencode({
            "response_type": "code",
            "client_id": settings.sso_client_id,
            "redirect_uri": settings.redirect_uri,
            "scope": "openid profile email",
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        })

    async def exchange(self, code: str, verifier: str) -> dict:
        target, headers = self._server_url((await self.discovery())["token_endpoint"])
        response = await self._client.post(target, headers=headers, data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": settings.redirect_uri,
            "code_verifier": verifier,
            "client_id": settings.sso_client_id,
            "client_secret": settings.sso_client_secret,
        })
        if response.status_code >= 400:
            logger.warning("[oidc] troca do código recusada: HTTP %s %s", response.status_code, response.text[:200])
            raise LoginError("O Authentik recusou o login. Tente de novo.")
        return response.json()

    async def _key(self, kid: str, force: bool = False):
        async with self._lock:
            if force or not self._keys or monotonic() - self._keys_at > 3600:
                jwks = await self._get((await self.discovery())["jwks_uri"])
                self._keys = {k["kid"]: jwt.PyJWK.from_dict(k).key for k in jwks.get("keys", []) if k.get("kid")}
                self._keys_at = monotonic()
        return self._keys.get(kid)

    async def identity(self, id_token: str, nonce: str) -> Identity:
        try:
            header = jwt.get_unverified_header(id_token)
            algorithm = header.get("alg")
            if algorithm not in ("RS256", "ES256"):
                raise LoginError("Configure uma chave de assinatura (RS256) no provider do Authentik.")
            kid = header.get("kid", "")
            key = await self._key(kid) or await self._key(kid, force=True)
            if key is None:
                raise jwt.InvalidTokenError("chave desconhecida")
            claims = jwt.decode(
                id_token, key, algorithms=[algorithm], audience=settings.sso_client_id,
                issuer=(await self.discovery()).get("issuer", settings.oidc_issuer),
                options={"require": ["exp", "iat", "iss", "aud", "sub"]}, leeway=30)
        except LoginError:
            raise
        except (jwt.PyJWTError, httpx.HTTPError, KeyError, ValueError) as error:
            logger.warning("[oidc] id_token inválido: %s", error)
            raise LoginError("Não foi possível confirmar o login no Authentik.") from error
        if not secrets.compare_digest(str(claims.get("nonce", "")), nonce):
            raise LoginError("Login expirado ou repetido. Tente de novo.")
        groups = claims.get("groups") or []
        if isinstance(groups, str):
            groups = [groups]
        email = str(claims.get("email") or "").strip().lower()
        username = str(claims.get("preferred_username") or email.split("@")[0] or "usuario").strip()[:64]
        return Identity(subject=str(claims["sub"]), username=username, email=email,
                        name=str(claims.get("name") or username).strip()[:120], groups=tuple(map(str, groups)))


_client: OIDCClient | None = None


def client() -> OIDCClient:
    global _client
    if _client is None:
        _client = OIDCClient()
    return _client


def set_client(value: OIDCClient | None) -> None:
    """Testes: Authentik falso."""
    global _client
    _client = value


# ── Login ────────────────────────────────────────────────────────────

async def begin_login(pool, next_path: str) -> str:
    state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
    await pool.execute("DELETE FROM login_states WHERE created_at < now() - make_interval(secs => $1)",
                       STATE_TTL_SECONDS)
    await pool.execute("INSERT INTO login_states (state, nonce, verifier, next_path) VALUES ($1, $2, $3, $4)",
                       state, nonce, verifier, safe_next(next_path))
    return await client().authorize_url(state, nonce, s256(verifier))


async def finish_login(pool, code: str, state: str, user_agent: str) -> tuple[str, str]:
    """Valida o retorno do Authentik. Devolve (token da sessão, caminho de volta)."""
    pending = await pool.fetchrow(
        """DELETE FROM login_states WHERE state = $1 AND created_at > now() - make_interval(secs => $2)
           RETURNING nonce, verifier, next_path""", state, STATE_TTL_SECONDS) if state else None
    if pending is None:
        raise LoginError("O login expirou. Tente de novo.")
    tokens = await client().exchange(code, pending["verifier"])
    if not tokens.get("id_token"):
        raise LoginError("O Authentik não devolveu a identidade (escopo openid).")
    identity = await client().identity(tokens["id_token"], pending["nonce"])
    allowed = {g for g in (settings.users_group, settings.admins_group) if g}
    if allowed and not allowed.intersection(identity.groups):
        raise LoginError("Sua conta não tem acesso ao Transcriptor. Peça para o administrador.")
    user_id = await pool.fetchval(
        """INSERT INTO users (oidc_subject, username, name, email, is_admin, last_login_at)
           VALUES ($1, $2, $3, $4, $5, now())
           ON CONFLICT (oidc_subject) DO UPDATE SET username = EXCLUDED.username, name = EXCLUDED.name,
               email = EXCLUDED.email, is_admin = EXCLUDED.is_admin, last_login_at = now()
           RETURNING id""",
        identity.subject, identity.username, identity.name, identity.email,
        bool(settings.admins_group) and settings.admins_group in identity.groups)
    token = secrets.token_urlsafe(32)
    await pool.execute(
        """INSERT INTO sessions (token_hash, user_id, expires_at, user_agent)
           VALUES ($1, $2, now() + make_interval(days => $3), $4)""",
        token_hash(token), user_id, settings.session_days, user_agent[:200])
    return token, pending["next_path"]


async def end_session(pool, token: str | None) -> None:
    if token:
        await pool.execute("DELETE FROM sessions WHERE token_hash = $1", token_hash(token))


# ── Quem está pedindo ────────────────────────────────────────────────

@dataclass(frozen=True)
class User:
    id: object
    username: str
    name: str
    email: str
    is_admin: bool
    via_token: bool


def _same_origin(request: Request) -> bool:
    origin = request.headers.get("origin")
    if origin is None:
        referer = request.headers.get("referer", "")
        origin = f"{urlsplit(referer).scheme}://{urlsplit(referer).netloc}" if referer else ""
    return origin == settings.public_origin


async def current_user(request: Request) -> User:
    pool = request.app.state.pool
    authorization = request.headers.get("authorization", "")
    if authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
        row = await pool.fetchrow(
            """UPDATE api_tokens SET last_used_at = now() WHERE token_hash = $1
               RETURNING user_id""", token_hash(token)) if token.startswith(TOKEN_PREFIX) else None
        if row is None:
            raise HTTPException(401, "Token inválido.")
        via_token = True
        user_id = row["user_id"]
    else:
        cookie = request.cookies.get(SESSION_COOKIE)
        row = await pool.fetchrow(
            """UPDATE sessions SET last_seen_at = now() WHERE token_hash = $1 AND expires_at > now()
               RETURNING user_id""", token_hash(cookie)) if cookie else None
        if row is None:
            raise HTTPException(401, "Entre pelo Authentik.")
        if request.method not in SAFE_METHODS and (
                request.headers.get("x-transcriptor") != "1" or not _same_origin(request)):
            raise HTTPException(403, "Pedido recusado (origem).")
        via_token = False
        user_id = row["user_id"]
    user = await pool.fetchrow("SELECT id, username, name, email, is_admin FROM users WHERE id = $1", user_id)
    if user is None:
        raise HTTPException(401, "Conta não encontrada.")
    return User(user["id"], user["username"], user["name"], user["email"], user["is_admin"], via_token)


async def web_user(request: Request) -> User:
    """Rotas que só fazem sentido na interface (gerenciar tokens)."""
    user = await current_user(request)
    if user.via_token:
        raise HTTPException(403, "Use a interface para gerenciar tokens.")
    return user


async def admin_user(request: Request) -> User:
    user = await current_user(request)
    if not user.is_admin:
        raise HTTPException(403, "Só para administradores.")
    return user


# ── Tokens pessoais ──────────────────────────────────────────────────

async def create_token(pool, user_id, name: str) -> tuple[dict, str]:
    secret = TOKEN_PREFIX + secrets.token_urlsafe(32)
    row = await pool.fetchrow(
        """INSERT INTO api_tokens (user_id, name, prefix, token_hash) VALUES ($1, $2, $3, $4)
           RETURNING id, name, prefix, created_at, last_used_at""",
        user_id, name, secret[:len(TOKEN_PREFIX) + 6], token_hash(secret))
    return token_public(row), secret


def token_public(row) -> dict:
    return {"id": str(row["id"]), "name": row["name"], "prefix": row["prefix"],
            "created_at": row["created_at"].isoformat(),
            "last_used_at": row["last_used_at"].isoformat() if row["last_used_at"] else None}
