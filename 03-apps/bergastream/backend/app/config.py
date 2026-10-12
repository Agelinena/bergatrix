"""Configuração tipada via variáveis de ambiente (pydantic-settings)."""

from __future__ import annotations

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # extra="ignore": um .env antigo com chaves que saíram (ex.: SPOTIFY_*) não
    # impede o app de subir.
    model_config = dict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # ── Banco ─────────────────────────────────────────────────
    database_url: str = "postgresql://bergastream:bergastream@db:5432/bergastream"

    # ── Deezer ────────────────────────────────────────────────
    deemix_arl: str = ""            # DEEMIX_ARL do .env
    deemix_url: str = "http://deemix:6595"

    # ── Spotify ───────────────────────────────────────────────
    # Sem conta nem chave (ver app/search/spotify.py). Pasta persistente onde
    # o teste diário instala versões novas da SpotifyScraper quando o Spotify
    # muda o web player (vazio = sem atualização automática).
    pydeps_dir: str = "/data/pydeps"

# ── Redis ────────────────────────────────────────────────
    redis_url: str = "redis://redis:6379/0"
    # ── Paths ─────────────────────────────────────────────────
    music_dir: str = "/data/music"
    cache_ttl_hours: int = 48

    # ── YouTube (plano B do download) ─────────────────────────
    # Cookies (formato Netscape) de uma conta do YouTube, para quando o
    # YouTube pedir "não sou um robô" ao servidor. Opcional.
    yt_cookies_file: str = ""
    # Gerador de PO Tokens (serviço pot-provider do compose): o YouTube
    # confia mais nos pedidos e bloqueia menos o servidor. Vazio = sem ele.
    pot_provider_url: str = "http://bergastream-pot:4416"

    # ── Melhoria de qualidade (faixas de playlist) ────────────
    # Lidarr (stack do Jellyfin) baixa o álbum em FLAC pela Usenet. Vazio =
    # sem Lidarr (as playlists melhoram só pelo Deemix).
    lidarr_url: str = ""
    lidarr_api_key: str = ""
    # Perfis do Lidarr por nome (vazio = o de nome com "lossless"/"flac", ou
    # o primeiro) e pasta raiz (vazio = a primeira cadastrada).
    lidarr_quality_profile: str = ""
    lidarr_metadata_profile: str = ""
    lidarr_root_folder: str = ""
    # A pasta de música do Lidarr como o Lidarr a vê (no container dele) e
    # onde ela está montada aqui (só leitura).
    lidarr_remote_root: str = "/music"
    lidarr_local_root: str = "/data/lidarr"
    # Busca na Usenet todo dia nos primeiros N dias; depois, toda semana.
    upgrade_daily_days: int = 14
    # Depois de copiar a música, apaga o resto do álbum do Lidarr (o Lidarr só
    # baixa álbuns inteiros). true = mantém o álbum na biblioteca do Lidarr.
    lidarr_keep_albums: bool = False

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