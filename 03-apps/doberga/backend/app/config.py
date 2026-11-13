"""Configuração por variáveis de ambiente (pydantic-settings)."""
from __future__ import annotations

from urllib.parse import urlsplit

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_config = dict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # ── Banco e Redis ─────────────────────────────────────────
    database_url: str = "postgresql://doberga:doberga@db:5432/doberga"
    redis_url: str = "redis://redis:6379/0"

    # ── Autenticação ──────────────────────────────────────────
    # Segredo dos JWT. Vazio = aleatório a cada início (as sessões caem).
    jwt_secret: str = ""
    access_token_minutes: int = 15
    refresh_token_days: int = 60
    # Um refresh token recém-trocado ainda vale por estes segundos. Com sinal
    # ruim (mercado), a resposta da troca se perde, e o app tenta de novo com o
    # token antigo: sem a tolerância, isso derrubaria a sessão.
    refresh_grace_seconds: int = 120

    # ── Login pelo Authentik (OIDC) ───────────────────────────
    # O servidor é o cliente OIDC (confidencial), como no Berganews.
    oidc_issuer: str = ""          # https://authentik.example.com/application/o/doberga/
    oidc_client_id: str = Field(
        "", validation_alias=AliasChoices("DOBERGA_SSO_CLIENT_ID", "OIDC_CLIENT_ID"))
    oidc_client_secret: str = Field(
        "", validation_alias=AliasChoices("DOBERGA_SSO_CLIENT_SECRET", "OIDC_CLIENT_SECRET"))
    oidc_redirect_uri: str = ""    # https://doberga.example.com/api/auth/oidc/callback
    oidc_internal_url: str = ""    # http://authentik-server:9000
    oidc_group_claim: str = "groups"
    oidc_required_group: str = "doberga_users"
    oidc_admin_group: str = "doberga_admins"
    oidc_account_url: str = ""

    @property
    def oidc_enabled(self) -> bool:
        return bool(self.oidc_issuer and self.oidc_client_id and self.oidc_redirect_uri)

    @property
    def authentik_account_url(self) -> str:
        if self.oidc_account_url:
            return self.oidc_account_url
        return f"{_origin(self.oidc_issuer)}/if/user/#/settings" if self.oidc_issuer else ""

    @property
    def public_url(self) -> str:
        return _origin(self.oidc_redirect_uri) if self.oidc_redirect_uri else ""

    # ── Sync ──────────────────────────────────────────────────
    # Versões do protocolo que a API aceita (cabeçalho X-Doberga-Sync).
    sync_protocol: int = 1
    sync_min_protocol: int = 1
    sync_push_max_ops: int = 200
    sync_pull_limit: int = 500
    # Linhas apagadas (lápides) e operações aplicadas somem depois disso. Um
    # aparelho parado por mais tempo refaz o espaço do zero.
    sync_retention_days: int = 90

    # ── App ───────────────────────────────────────────────────
    # O app pede para atualizar abaixo da mínima e oferece a mais recente.
    app_min_version: str = "0.1.0"
    app_latest_version: str = ""
    app_download_url: str = ""

    # ── Convites ──────────────────────────────────────────────
    invite_days: int = 7
    invite_max_uses: int = 10

    log_level: str = "INFO"


def _origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


settings = Settings()
