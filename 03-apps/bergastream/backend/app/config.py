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
    deemix_arl: str = ""
    spotipy_client_id: str = ""
    spotipy_client_secret: str = ""
    gemini_api_key: str = ""

    # Paths
    music_permanent_path: str = "/data/music/permanent"
    music_cache_path: str = "/data/music/cache"
    media_covers_path: str = "/data/media/covers"
    cache_expire_hours: int = 48

    # App
    log_level: str = "INFO"
    max_download_workers: int = 10
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
