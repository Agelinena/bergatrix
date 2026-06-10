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
    # Workers de download via deemix (QUEUE_BG).  Antes era 1 (single-
    # consumer) porque chamadas paralelas ao sidecar conflitavam.  Agora
    # protegemos a submissão (cancel + emit) com um asyncio.Lock e cada
    # arquivo recebido é claimado via Redis SADD — então é seguro
    # paralelizar.  2 é um bom default; 3+ pode forçar o sidecar a ter
    # vários downloads simultâneos e degradar a velocidade individual.
    # Subimos para 3 (com o submit-lock serializando submissões, os workers
    # extras paralelizam a fase de polling/move, acelerando playlists grandes).
    deemix_bg_workers: int = 3
    # Workers dedicados a downloads via yt-dlp em background (QUEUE_YTDLP)
    ytdlp_bg_workers: int = 2
    # Máximo de processos yt-dlp simultâneos em modo DOWNLOAD de BACKGROUND
    # (prefetch/playlist, 20–60 s cada).  Pool SEPARADO do streaming on-demand
    # (max_yt_stream_concurrent) — antes ambos dividiam este semáforo, então um
    # download de playlist em massa podia segurar todos os slots e fazer o
    # clique do usuário esperar 60 s.  Agora o stream tem pool dedicado.
    max_yt_concurrent: int = 2
    # Máximo de processos yt-dlp simultâneos em modo DOWNLOAD de STREAMING
    # on-demand (clique do usuário).  Pool com prioridade — nunca é disputado
    # por downloads de background.  Total de processos yt-dlp simultâneos =
    # max_yt_concurrent + max_yt_stream_concurrent (ajuste conforme a máquina).
    max_yt_stream_concurrent: int = 2
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
