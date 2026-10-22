"""Login pelo Authentik (OpenID Connect), com o servidor como cliente.

O app não fala com o Authentik: abre o navegador em /api/auth/oidc/start,
o Authentik faz o login e volta para /api/auth/oidc/callback; o servidor
troca o código pelos tokens do Authentik (cliente confidencial + PKCE),
valida o id_token (assinatura pelo JWKS, issuer, audience, nonce), liga a
conta a um usuário do Bergastream e devolve ao app um código de uso único.
O app troca esse código (provando o PKCE dele) pelos tokens do Bergastream
em /api/auth/oidc/exchange — o resto (renovação, streaming, WebSockets)
segue igual. Funciona igual na web, no Android e no computador.

Contas de antes do OIDC: no primeiro login, o usuário do Authentik é ligado
ao do Bergastream de mesmo username (ou, sem isso, de mesmo e-mail); dali em
diante, pelo "sub" do Authentik. Nada se perde.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import re
import secrets
from dataclasses import dataclass
from time import monotonic
from urllib.parse import urlencode, urlsplit, urlunsplit

import httpx
import jwt

from app.config import settings

logger = logging.getLogger("bergastream.auth.oidc")

STATE_TTL = 600   # s para concluir o login no Authentik
CODE_TTL = 120    # s para o app trocar o código pelos tokens
_STATE_KEY = "bergastream:oidc:state:"
_CODE_KEY = "bergastream:oidc:code:"

# Para onde o servidor pode devolver o app (nada de mandar o código para fora):
APP_SCHEME = "com.bergatrix.bergastream"
_LOOPBACK = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):\d{1,5}(/[^?#]*)?$")


class OIDCError(Exception):
    """Falha mostrada à pessoa (página de erro do callback ou 400)."""


@dataclass(frozen=True)
class Identity:
    subject: str
    username: str
    email: str
    name: str
    groups: tuple[str, ...]


def valid_app_redirect(redirect: str) -> bool:
    """Web: caminho relativo no mesmo domínio; Android: o esquema do app;
    computador: endereço local (127.0.0.1) aberto pelo próprio app."""
    if redirect.startswith("/") and not redirect.startswith("//") and "\\" not in redirect:
        return True
    if redirect.startswith(f"{APP_SCHEME}://"):
        return True
    return bool(_LOOPBACK.match(redirect))


def s256(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def with_query(url: str, **params: str) -> str:
    parts = urlsplit(url)
    query = (parts.query + "&" if parts.query else "") + urlencode(params)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))


class OIDCClient:
    """Fala com o Authentik: descoberta, troca do código e chaves (JWKS)."""

    def __init__(self, client: httpx.AsyncClient | None = None):
        self._client = client or httpx.AsyncClient(timeout=10.0)
        self._discovery: dict | None = None
        self._keys: dict = {}
        self._keys_at = 0.0
        self._lock = asyncio.Lock()

    def _server_url(self, url: str) -> tuple[str, dict]:
        """URL para o servidor chamar (interna, se configurada) e cabeçalhos:
        com o endereço interno, o Host continua o público (o Authentik monta o
        issuer pelo host)."""
        internal = settings.oidc_internal_url.rstrip("/")
        if not internal:
            return url, {}
        public = urlsplit(url)
        base = urlsplit(internal)
        rewritten = urlunsplit((base.scheme, base.netloc, public.path, public.query, ""))
        return rewritten, {"Host": public.netloc, "X-Forwarded-Proto": public.scheme or "https"}

    async def _get(self, url: str) -> dict:
        target, headers = self._server_url(url)
        r = await self._client.get(target, headers=headers)
        r.raise_for_status()
        return r.json()

    async def discovery(self) -> dict:
        if self._discovery is None:
            issuer = settings.oidc_issuer.rstrip("/") + "/"
            self._discovery = await self._get(issuer + ".well-known/openid-configuration")
        return self._discovery

    async def authorize_url(self, state: str, nonce: str, challenge: str) -> str:
        endpoint = (await self.discovery())["authorization_endpoint"]
        return endpoint + "?" + urlencode({
            "response_type": "code",
            "client_id": settings.oidc_client_id,
            "redirect_uri": settings.oidc_redirect_uri,
            "scope": "openid profile email",
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        })

    async def exchange(self, code: str, verifier: str) -> dict:
        endpoint = (await self.discovery())["token_endpoint"]
        target, headers = self._server_url(endpoint)
        r = await self._client.post(target, headers=headers, data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": settings.oidc_redirect_uri,
            "code_verifier": verifier,
            "client_id": settings.oidc_client_id,
            "client_secret": settings.oidc_client_secret,
        })
        if r.status_code >= 400:
            logger.warning("[oidc] troca do código recusada: HTTP %s %s", r.status_code, r.text[:200])
            raise OIDCError("O Authentik recusou o login. Tente de novo.")
        return r.json()

    async def _key(self, kid: str, force: bool = False):
        async with self._lock:
            if force or not self._keys or monotonic() - self._keys_at > 3600:
                jwks = await self._get((await self.discovery())["jwks_uri"])
                self._keys = {k["kid"]: jwt.PyJWK.from_dict(k).key
                              for k in jwks.get("keys", []) if k.get("kid")}
                self._keys_at = monotonic()
        return self._keys.get(kid)

    async def identity(self, id_token: str, nonce: str) -> Identity:
        try:
            header = jwt.get_unverified_header(id_token)
            alg = header.get("alg")
            if alg not in ("RS256", "ES256"):
                raise OIDCError("Configure uma chave de assinatura (RS256) no provider do Authentik.")
            key = await self._key(header.get("kid", "")) or await self._key(header.get("kid", ""), force=True)
            if key is None:
                raise jwt.InvalidTokenError("chave desconhecida")
            claims = jwt.decode(
                id_token, key, algorithms=[alg], audience=settings.oidc_client_id,
                issuer=(await self.discovery()).get("issuer", settings.oidc_issuer),
                options={"require": ["exp", "iat", "iss", "aud", "sub"]}, leeway=30)
        except OIDCError:
            raise
        except (jwt.PyJWTError, httpx.HTTPError, KeyError, ValueError) as exc:
            logger.warning("[oidc] id_token inválido: %s", exc)
            raise OIDCError("Não foi possível confirmar o login no Authentik.") from exc
        if claims.get("nonce") != nonce:
            raise OIDCError("Login expirado ou repetido. Tente de novo.")
        groups = claims.get(settings.oidc_group_claim) or []
        if isinstance(groups, str):
            groups = [groups]
        email = str(claims.get("email") or "").strip().lower()
        username = str(claims.get("preferred_username") or claims.get("nickname")
                       or email.split("@")[0]).strip()
        return Identity(subject=str(claims["sub"]), username=username, email=email,
                        name=str(claims.get("name") or username).strip() or username,
                        groups=tuple(str(g) for g in groups))


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


# ── Estado do login (Redis) ──────────────────────────────────────────

async def begin(redis, app_redirect: str, app_challenge: str) -> str:
    """Guarda o pedido e devolve a URL do Authentik."""
    if not valid_app_redirect(app_redirect):
        raise OIDCError("Endereço de retorno não permitido.")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", app_challenge):
        raise OIDCError("Pedido de login inválido.")
    state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
    await redis.set(_STATE_KEY + state, json.dumps({
        "nonce": nonce, "verifier": verifier, "redirect": app_redirect,
        "app_challenge": app_challenge}), ex=STATE_TTL)
    return await client().authorize_url(state, nonce, s256(verifier))


async def finish(redis, code: str, state: str) -> tuple[Identity, dict]:
    """Callback do Authentik: valida e devolve a identidade e o pedido."""
    raw = await redis.getdel(_STATE_KEY + state) if state else None
    if not raw:
        raise OIDCError("Login expirado. Volte ao Bergastream e tente de novo.")
    pending = json.loads(raw)
    tokens = await client().exchange(code, pending["verifier"])
    if not tokens.get("id_token"):
        raise OIDCError("O Authentik não devolveu a identidade (escopo openid).")
    identity = await client().identity(tokens["id_token"], pending["nonce"])
    if settings.oidc_required_group and settings.oidc_required_group not in identity.groups:
        raise OIDCError("Sua conta não tem acesso ao Bergastream. Peça para o administrador.")
    return identity, pending


async def issue_code(redis, user_id: str, app_challenge: str) -> str:
    code = secrets.token_urlsafe(32)
    await redis.set(_CODE_KEY + code, json.dumps({"user_id": user_id, "challenge": app_challenge}),
                    ex=CODE_TTL)
    return code


async def redeem_code(redis, code: str, app_verifier: str) -> str | None:
    """Código de uso único → id do usuário (se o PKCE do app confere)."""
    raw = await redis.getdel(_CODE_KEY + code) if code else None
    if not raw:
        return None
    data = json.loads(raw)
    if not secrets.compare_digest(s256(app_verifier), data["challenge"]):
        return None
    return data["user_id"]


# ── Conta do Bergastream ─────────────────────────────────────────────

def _clean_username(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]", "", value)[:32]
    return value or "usuario"


async def _sync_identity(pool, user_id, identity: Identity) -> None:
    """O Authentik é a fonte: usuário, nome e e-mail seguem os de lá a cada
    login. Se o valor já é de outra conta aqui, fica o atual (e o log avisa).
    A ligação é pelo sub, então nada disso a desfaz."""
    import asyncpg
    values = (("username", _clean_username(identity.username) if identity.username else ""),
              ("name", identity.name.strip()[:60]),
              ("email", identity.email))
    for column, value in values:
        if not value:
            continue
        try:
            await pool.execute(
                f"UPDATE users SET {column} = $2 WHERE id = $1 AND {column} IS DISTINCT FROM $2",
                user_id, value)
        except asyncpg.UniqueViolationError:
            logger.warning("[oidc] %s do Authentik já é de outra conta aqui; mantido o atual "
                           "na conta %s", column, user_id)


async def link_user(pool, identity: Identity):
    """Usuário do Bergastream da identidade: já ligado pelo sub; senão o de
    mesmo username ou e-mail (contas de antes do OIDC); senão um novo."""
    from app.auth import repository as repo
    row = await pool.fetchrow("SELECT id FROM users WHERE oidc_subject = $1", identity.subject)
    how = "sub"
    if row is None and identity.username:
        row = await pool.fetchrow(
            "SELECT id FROM users WHERE lower(username) = lower($1) AND oidc_subject IS NULL",
            identity.username)
        how = "username"
    if row is None and identity.email:
        row = await pool.fetchrow(
            "SELECT id FROM users WHERE lower(email) = $1 AND oidc_subject IS NULL", identity.email)
        how = "e-mail"
    if row is None:
        if not settings.oidc_auto_create:
            raise OIDCError("Não há uma conta do Bergastream para este usuário. Peça para o administrador.")
        base = _clean_username(identity.username)
        username, n = base, 1
        while await pool.fetchval("SELECT 1 FROM users WHERE lower(username) = lower($1)", username):
            n += 1
            username = f"{base[:29]}{n}"
        name, n = identity.name, 1
        while await pool.fetchval("SELECT 1 FROM users WHERE name = $1", name):
            n += 1
            name = f"{identity.name} ({n})"
        row = await repo.create_user(pool, username, None, name=name)
        how = "nova conta"
    if await pool.fetchval("SELECT disabled_at IS NOT NULL FROM users WHERE id = $1", row["id"]):
        raise OIDCError("Sua conta do Bergastream está desativada. Fale com o administrador.")
    admin = (settings.oidc_admin_group in identity.groups) if settings.oidc_admin_group else None
    await pool.execute(
        """UPDATE users SET oidc_subject = $2, last_login_at = now(),
                  is_admin = COALESCE($3, is_admin)
           WHERE id = $1""",
        row["id"], identity.subject, admin)
    await _sync_identity(pool, row["id"], identity)
    if how != "sub":
        logger.info("[oidc] %s ligado ao usuário %s (%s)", identity.username, row["id"], how)
    return await repo.get_user_by_id(pool, str(row["id"]))
