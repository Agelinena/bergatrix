"""Configuração tipada via variáveis de ambiente (pydantic-settings)."""

from __future__ import annotations

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_config = dict(env_file=".env", env_file_encoding="utf-8")

    # ── Banco ─────────────────────────────────────────────────
    database_url: str = "postgresql://bergastream:bergastream@db:5432/bergastream"

    # ── Deezer ────────────────────────────────────────────────
    deemix_arl: str = ""            # DEEMIX_ARL do .env
    deemix_url: str = "http://deemix:6595"

    # ── Spotify (opcional) ────────────────────────────────────
    spotify_client_id: str = ""
    spotify_client_secret: str = ""

# ── Redis ────────────────────────────────────────────────
    redis_url: str = "redis://redis:6379/0"
    # ── Paths ─────────────────────────────────────────────────
    music_dir: str = "/data/music"
    cache_ttl_hours: int = 48

    # ── Autenticação ──────────────────────────────────────────
    # Segredo dos JWT. Vazio = gera um aleatório ao subir (as sessões caem a
    # cada reinício); em produção defina JWT_SECRET no .env.
    jwt_secret: str = ""
    access_token_minutes: int = 15
    refresh_token_days: int = 30
    stream_token_hours: int = 6
    allow_registration: bool = False
    # Falhas de login por usuário+IP antes de bloquear por login_block_minutes.
    login_max_failures: int = 5
    login_block_minutes: int = 15

    # ── App ───────────────────────────────────────────────────
    log_level: str = "INFO"


settings = Settings()