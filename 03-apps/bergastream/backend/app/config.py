from pydantic_settings import BaseSettings, SettingsConfigDict
from functools import lru_cache


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Domínios separados
    web_domain: str = "localhost:3000"
    api_domain: str = "localhost:8000"

    # Database
    database_url: str = "postgresql+asyncpg://bergastream:devpassword@localhost:5432/bergastream"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # JWT
    jwt_secret_key: str = "changeme_very_long_random_secret_key_min_32_chars"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 10080  # 7 days

    # Music sources
    deemix_arl: str = ""           # passado ao container deemix via env ARL
    deemix_url: str = ""           # ex: http://bergastream-deemix:6595
    deemix_downloads_path: str = "" # volume compartilhado, ex: /data/music/deemix_dl
    spotipy_client_id: str = ""
    spotipy_client_secret: str = ""

    # AI / recommendations
    openrouter_api_key: str = ""
    openrouter_model: str = "google/gemini-flash-1.5"
    lastfm_api_key: str = ""

    # Paths
    music_permanent_path: str = "/data/music/permanent"
    music_cache_path: str = "/data/music/cache"
    media_covers_path: str = "/data/media/covers"
    cache_expire_hours: int = 48

    # App
    log_level: str = "INFO"
    # Workers dedicados a streaming (QUEUE_STREAM) — yt-dlp only, sem throttle
    stream_workers: int = 2
    # Worker dedicado a downloads via deemix (QUEUE_BG) — sempre 1, sequencial
    deemix_bg_workers: int = 1
    # Workers dedicados a downloads via yt-dlp em background (QUEUE_YTDLP)
    ytdlp_bg_workers: int = 2
    # Máximo de processos yt-dlp simultâneos em modo DOWNLOAD (20–60 s cada).
    # Compartilhado entre stream workers e ytdlp bg workers.
    max_yt_concurrent: int = 2
    # Máximo de processos yt-dlp simultâneos em modo BUSCA (`ytsearch5 --dump-json`).
    # Buscas duram ~1–2 s; separar o semáforo evita que streams travem
    # esperando uma busca passar atrás de downloads ativos.
    max_yt_search_concurrent: int = 4
    # Mantido por compatibilidade
    max_download_workers: int = 10
    background_workers: int = 3  # deprecated — substituído por deemix_bg_workers + ytdlp_bg_workers
    # CORS_ORIGINS deve incluir https://{WEB_DOMAIN}
    cors_origins: str = "http://localhost:3000,http://localhost:8080"

    @property
    def cors_origins_list(self) -> list[str]:
        origins = [o.strip() for o in self.cors_origins.split(",")]
        # Sempre inclui o web_domain automaticamente
        web = f"https://{self.web_domain}"
        if web not in origins:
            origins.append(web)
        return origins


@lru_cache
def get_settings() -> Settings:
    return Settings()
