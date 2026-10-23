"""Configuração por variáveis de ambiente (prefixo TRANSCRIPTOR_), lida pela
API e pelo worker. Os nomes no .env estão no .env.example."""

from __future__ import annotations

from urllib.parse import urlsplit

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="TRANSCRIPTOR_", extra="ignore")

    # ── Banco e pastas ────────────────────────────────────────
    database_url: str = "postgresql://transcriptor:transcriptor@db:5432/transcriptor"
    # Endereço público, sem barra no fim (o compose monta a partir do DOMAIN).
    public_url: str = "http://localhost:8000"
    # Uploads e áudio temporário (CACHE_PATH: sem backup).
    work_dir: str = "/work"
    # Modelos baixados do Hugging Face (CACHE_PATH: sem backup).
    models_dir: str = "/models"

    # ── Login pelo Authentik (OIDC) ───────────────────────────
    oidc_issuer: str = ""          # https://authentik.example.com/application/o/transcriptor/
    sso_client_id: str = ""
    sso_client_secret: str = ""
    # O servidor fala com o Authentik por aqui, sem passar pelo Traefik.
    oidc_internal_url: str = ""    # http://authentik-server:9000
    users_group: str = "transcriptor_users"
    admins_group: str = "transcriptor_admins"
    session_days: int = 14

    # ── Limites ───────────────────────────────────────────────
    max_upload_mb: int = 2048
    max_duration_minutes: int = 240
    max_active_jobs: int = 20      # por pessoa, na fila ou rodando
    retention_days: int = 180      # 0 = guarda até a pessoa apagar
    audio_days: int = 7            # áudio para ouvir junto com o texto

    # ── Modelos e worker ──────────────────────────────────────
    models: str = "small,turbo,large-v3"
    default_model: str = "turbo"
    idle_unload_minutes: int = 5
    # Toda saída do worker para a internet (yt-dlp, Hugging Face) passa por
    # este proxy, que recusa endereços privados (anti-SSRF).
    egress_proxy: str = ""         # http://transcriptor-egress:4750
    worker_name: str = "gpu"

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

    @property
    def enabled_models(self) -> list[str]:
        return [name.strip() for name in self.models.split(",") if name.strip()]

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024


settings = Settings()
