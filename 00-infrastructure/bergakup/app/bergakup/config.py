"""Configuração por variáveis de ambiente (prefixo BERGAKUP_). Os nomes no .env
estão no .env.example."""

from __future__ import annotations

from urllib.parse import urlsplit

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="BERGAKUP_", extra="ignore")

    database_url: str = "postgresql://bergakup:bergakup@db:5432/bergakup"
    # Endereço da interface, sem barra no fim (o compose monta a partir do DOMAIN).
    public_url: str = "http://localhost:8000"
    static_dir: str = "/code/static"

    # ── Login pelo Authentik (OIDC) ───────────────────────────
    oidc_issuer: str = ""          # https://authentik.example.com/application/o/bergakup/
    sso_client_id: str = ""
    sso_client_secret: str = ""
    oidc_internal_url: str = ""    # http://authentik-server:9000
    # Só quem está neste grupo do Authentik entra.
    users_group: str = "bergakup_admins"
    session_days: int = 7

    # ── Agente ────────────────────────────────────────────────
    # Agente sem sinal de vida há mais que isso vira alerta.
    agent_stale_minutes: int = 10

    @property
    def public_origin(self) -> str:
        parts = urlsplit(self.public_url)
        return f"{parts.scheme}://{parts.netloc}"

    @property
    def redirect_uri(self) -> str:
        return self.public_origin + "/auth/callback"

    @property
    def secure_cookies(self) -> bool:
        return self.public_origin.startswith("https://")

    @property
    def oidc_enabled(self) -> bool:
        return bool(self.oidc_issuer and self.sso_client_id and self.sso_client_secret)


settings = Settings()
