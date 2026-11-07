"""Configuração por variáveis de ambiente (pydantic-settings)."""
from __future__ import annotations

from urllib.parse import urlsplit

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_config = dict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # ── Banco e Redis ─────────────────────────────────────────
    database_url: str = "postgresql://berganews:berganews@db:5432/berganews"
    redis_url: str = "redis://redis:6379/0"

    # ── Autenticação ──────────────────────────────────────────
    # Segredo dos JWT. Vazio = aleatório a cada início (as sessões caem).
    jwt_secret: str = ""
    access_token_minutes: int = 15
    refresh_token_days: int = 60

    # ── Login pelo Authentik (OIDC) ───────────────────────────
    # O servidor é o cliente OIDC (confidencial), como no Bergastream.
    oidc_issuer: str = ""          # https://authentik.example.com/application/o/berganews/
    oidc_client_id: str = Field(
        "", validation_alias=AliasChoices("BERGANEWS_SSO_CLIENT_ID", "OIDC_CLIENT_ID"))
    oidc_client_secret: str = Field(
        "", validation_alias=AliasChoices("BERGANEWS_SSO_CLIENT_SECRET", "OIDC_CLIENT_SECRET"))
    oidc_redirect_uri: str = ""    # https://news.example.com/api/auth/oidc/callback
    oidc_internal_url: str = ""    # http://authentik-server:9000
    oidc_group_claim: str = "groups"
    oidc_required_group: str = "berganews_users"
    oidc_admin_group: str = "berganews_admins"
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

    # ── Saída para a internet ─────────────────────────────────
    # Todo endereço que vem das pessoas (feeds, páginas, imagens) sai por este
    # proxy (smokescreen), que recusa redes privadas.
    egress_proxy: str = "http://berganews-egress:4750"
    user_agent: str = "Mozilla/5.0 (compatible; Berganews/0.1; leitor RSS pessoal)"

    # ── Coleta ────────────────────────────────────────────────
    fetch_interval_minutes: int = 20
    # Depois de falhas seguidas, espera cada vez mais, até este teto.
    fetch_max_backoff_hours: int = 6
    fetch_concurrency: int = 6
    # Texto completo: só artigos recentes (os antigos ficam com o trecho do RSS).
    extract_max_age_hours: int = 72
    extract_batch: int = 40
    # Abaixo disso, o texto pode ser só o começo (paywall): fica guardado, e o
    # app avisa e oferece o site. Notas curtas do G1 têm ~500 caracteres.
    extract_min_chars: int = 400
    # Refazer a extração das matérias antigas (versão anterior do extrator):
    # quantas por vez, nos intervalos da coleta.
    reextract_batch: int = 20
    # Matérias que ninguém salvou somem depois de N dias (5 meses), com as
    # imagens. As salvas ficam, com as imagens guardadas no servidor.
    article_retention_days: int = 150

    # ── Imagens ───────────────────────────────────────────────
    image_cache_dir: str = "/cache/images"
    image_max_mb: int = 8

    # ── IA local (Ollama) ─────────────────────────────────────
    ollama_url: str = "http://ollama:11434"
    # Modelo multilíngue que caiba na GPU junto com o resto (GTX 1060).
    ai_model: str = "gemma3:4b"
    # Quanto tempo o modelo fica na VRAM depois da última tradução.
    ai_keep_alive: str = "2m"
    ai_num_ctx: int = 4096
    # Embeddings (histórias): modelo multilíngue de 1024 dimensões, leve o
    # bastante para rodar ao longo do dia, em lotes pequenos.
    embed_model: str = "bge-m3"
    embed_batch: int = 16
    # Só artigos recentes viram embedding (o resto é arquivo).
    embed_max_age_days: int = 7

    # ── Histórias ─────────────────────────────────────────────
    # Um artigo entra numa história se a similaridade com um dos artigos-base
    # dela passar do limite, se ela tiver artigo a até N horas, e (no mesmo
    # idioma) se tiverem um nome próprio ou sigla em comum. Calibre com a
    # tela de calibração (GET /api/admin/stories/calibration).
    story_threshold: float = 0.78
    # Acima disso, entra mesmo sem entidade em comum, e vira artigo-base.
    story_strong: float = 0.88
    story_window_hours: int = 72
    story_max_seeds: int = 4

    # Idiomas que o botão de traduzir alterna.
    translate_languages: str = "pt,en"

    @property
    def translate_langs(self) -> list[str]:
        return [x.strip() for x in self.translate_languages.split(",") if x.strip()]

    log_level: str = "INFO"


def _origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


settings = Settings()
