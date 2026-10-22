"""Configuração tipada via variáveis de ambiente (pydantic-settings)."""

from __future__ import annotations

from pydantic import AliasChoices, Field
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
    # Lidarr (serviço `lidarr` deste compose) baixa o álbum em FLAC pela
    # Usenet. Sem LIDARR_API_KEY = desligado (as playlists melhoram só pelo
    # Deemix).
    lidarr_url: str = "http://bergastream-lidarr:8686"
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
    # Busca na Usenet todo dia nos primeiros N dias do álbum no Lidarr;
    # depois, toda semana (entre uma e outra, o RSS do Lidarr pega o que sair).
    upgrade_daily_days: int = 3
    # No máximo N álbuns na fase de busca diária; as outras faixas esperam vaga
    # (o Lidarr carrega a discografia de cada artista novo).
    lidarr_max_active: int = 30
    # Teto de buscas no indexador por 24 h (pedidos novos + repetições).
    lidarr_daily_searches: int = 100
    # Parte do orçamento diário guardada para pedidos novos: as buscas
    # repetidas dos álbuns já pedidos não podem gastar tudo.
    lidarr_request_reserve: int = 30
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

    # ── Login pelo Authentik (OIDC) ───────────────────────────
    # O servidor é o cliente OIDC (confidencial): o app abre o navegador no
    # Authentik e recebe de volta os tokens do Bergastream. Sem OIDC_ISSUER,
    # só o login por senha.
    oidc_issuer: str = ""          # https://authentik.example.com/application/o/bergastream/
    # Nomes do padrão (docs/05-acesso.md na raiz): BERGASTREAM_SSO_CLIENT_ID e
    # BERGASTREAM_SSO_CLIENT_SECRET. OIDC_CLIENT_ID/SECRET também valem.
    oidc_client_id: str = Field(
        "", validation_alias=AliasChoices("BERGASTREAM_SSO_CLIENT_ID", "OIDC_CLIENT_ID"))
    oidc_client_secret: str = Field(
        "", validation_alias=AliasChoices("BERGASTREAM_SSO_CLIENT_SECRET", "OIDC_CLIENT_SECRET"))
    # Exatamente o cadastrado no provider: https://bergastream.example.com/api/auth/oidc/callback
    oidc_redirect_uri: str = ""
    # Opcional: endereço interno para o servidor falar com o Authentik (ex.:
    # http://authentik-server:9000, com a API na rede bergatrix-proxy). Vazio =
    # usa o endereço público do issuer.
    oidc_internal_url: str = ""
    oidc_group_claim: str = "groups"
    oidc_required_group: str = ""  # vazio = qualquer conta do Authentik que tenha acesso ao app
    oidc_admin_group: str = ""     # vazio = não mexe em quem é admin
    # Conta do Authentik sem usuário correspondente aqui: cria um novo.
    oidc_auto_create: bool = True
    # Login por usuário e senha do Bergastream: "auto" = só sem OIDC; "true"
    # mantém (emergência); "false" desliga.
    password_login: str = "auto"

    @property
    def oidc_enabled(self) -> bool:
        return bool(self.oidc_issuer and self.oidc_client_id and self.oidc_redirect_uri)

    @property
    def password_login_enabled(self) -> bool:
        if self.password_login.lower() in ("true", "1", "yes"):
            return True
        if self.password_login.lower() in ("false", "0", "no"):
            return False
        return not self.oidc_enabled

    # Página "Minha conta" do Authentik (trocar usuário, e-mail e senha) e a
    # de usuários do admin. Vazio = deduzidas do issuer.
    oidc_account_url: str = ""

    @property
    def authentik_account_url(self) -> str:
        if self.oidc_account_url:
            return self.oidc_account_url
        return f"{_origin(self.oidc_issuer)}/if/user/#/settings" if self.oidc_issuer else ""

    @property
    def authentik_admin_url(self) -> str:
        return f"{_origin(self.oidc_issuer)}/if/admin/#/identity/users" if self.oidc_issuer else ""

    # ── E-mail (SMTP) ─────────────────────────────────────────
    # Avisos para as pessoas (senha trocada, convite, redefinir senha). Sem
    # SMTP_HOST, nada é enviado e o resto funciona igual.
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_from: str = ""            # "Bergastream <bergastream@example.com>"
    smtp_security: str = "starttls"  # starttls | ssl | none
    smtp_timeout_seconds: int = 20
    # Endereço público do app, para os links dos e-mails. Vazio = deduzido do
    # OIDC_REDIRECT_URI.
    app_url: str = ""
    # Validade do link de "redefinir senha" e do convite.
    password_reset_hours: int = 2
    invite_hours: int = 72

    @property
    def mail_enabled(self) -> bool:
        return bool(self.smtp_host and self.smtp_from)

    @property
    def public_url(self) -> str:
        if self.app_url:
            return self.app_url.rstrip("/")
        return _origin(self.oidc_redirect_uri) if self.oidc_redirect_uri else ""

    # ── App ───────────────────────────────────────────────────
    log_level: str = "INFO"


def _origin(url: str) -> str:
    from urllib.parse import urlsplit
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


settings = Settings()