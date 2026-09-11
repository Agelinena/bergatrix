# bergastream — Plataforma de streaming de música multi-usuário, auto-hospedada (substituto do Spotify)

> **Categoria:** app | **Caminho:** `03-apps/bergastream` | **Status:** active

## 🎯 Finalidade
BergaStream é um serviço de streaming de música self-hosted, pensado como substituto do Spotify dentro do homelab Bergatrix. O usuário pesquisa faixas em Deezer, Spotify e YouTube e as ouve via streaming sob demanda; o backend resolve cada faixa para um arquivo de áudio real, baixando-o na hora.

A resolução prioriza qualidade: tenta primeiro o Deezer via sidecar deemix (FLAC / MP3-320 / MP3-128 conforme a capacidade da conta ARL) e, se falhar, cai para o YouTube via yt-dlp (MP3). O áudio é servido em chunks com suporte a byte-range; enquanto o arquivo ainda está sendo baixado, o backend usa um modo "follow" (estilo `tail -f`) para começar a tocar quase imediatamente. Além do playback, oferece playlists colaborativas, curtidas, histórico, rádio por similaridade (Last.fm ou IA via OpenRouter), downloads offline e controle multi-dispositivo estilo Spotify Connect. É exposto à internet via Traefik.

## 🧱 Stack tecnológica
- **Backend:** Python 3.12 (`python:3.12-slim`), FastAPI 0.115, Uvicorn (single worker), SQLAlchemy 2.0 async + asyncpg, Alembic, Pydantic v2 / pydantic-settings.
- **Persistência:** PostgreSQL 16 (alpine), Redis 7 (alpine, appendonly).
- **Auth:** python-jose (JWT HS256), passlib/bcrypt, python-multipart, email-validator.
- **HTTP/IO:** httpx, aiohttp, aiofiles.
- **Pipeline de mídia:** yt-dlp (+ deno e nodejs como runtimes JS do extractor), ytmusicapi, spotipy, mutagen, ffmpeg.
- **Frontend:** Flutter (Dart >=3.3, alvos Web/Android/Windows/Linux; `ios:false`), Riverpod + codegen, go_router, just_audio / just_audio_background, dio, flutter_secure_storage, cached_network_image, connectivity_plus, web_socket_channel, multicast_dns (Cast/mDNS), file_picker.
- **Web server:** Nginx (alpine) servindo o build Flutter Web.
- **Sidecar:** deemix (`registry.gitlab.com/bockiii/deemix-docker:latest`).

## 📦 Serviços / Containers

| Serviço | Imagem / Build | Porta (interna) | Volumes | Redes | depends_on | Healthcheck |
|---|---|---|---|---|---|---|
| **deemix** | `registry.gitlab.com/bockiii/deemix-docker:latest` | 6595 | `deemix_config:/config`, `deemix_dl:/downloads` | internal, bergatrix-proxy | — | `wget -qO- /api/connect` (30s/5s/3, start 20s) |
| **api** | build `./backend` (multi-stage; `alembic upgrade head && uvicorn ... --workers 1`) | 8000 | `music:/data/music`, `media:/data/media`, `deemix_dl:/data/music/deemix_dl` | internal, bergatrix-proxy | db (healthy), redis (healthy) | `python urllib GET /api/health` (30s/5s/3, start 30s) |
| **web** | build `./frontend` (`flutter build web --dart-define=API_URL=https://${API_DOMAIN}` → nginx:alpine) | 80 | — | bergatrix-proxy | api | — |
| **db** | `postgres:16-alpine` | 5432 (não exposta) | `db:/var/lib/postgresql/data` | internal | — | `pg_isready` (10s/5s/5) |
| **redis** | `redis:7-alpine` (`--appendonly yes`) | 6379 (não exposta) | `redis:/data` | internal | — | `redis-cli ping` (10s/3s/5) |

- Todos os serviços usam `restart: unless-stopped`. Não há configuração de `deploy`, limites de recurso ou GPU.
- Volumes residem no host sob `${VOLUMES_BASE}/bergastream/...`.
- O Dockerfile da api instala `ffmpeg, curl, git, nodejs, unzip, ca-certificates` e `deno` (este último necessário para o extractor moderno do yt-dlp).
- O sidecar deemix compartilha `deemix_dl` com a api (montado como `/data/music/deemix_dl`), permitindo que o backend capture os arquivos baixados (com hardlink/symlink para o follow-mode).
- Existe também um `docker-compose.dev.yml` separado (api/db/redis com portas expostas, sem Traefik, hot-reload, target `development`).

## 🌐 Domínios / Roteamento
Roteamento por Traefik (rede `bergatrix-proxy`, entrypoint `websecure`, `tls=true` sem `certresolver`). Os três routers (`web`, `api`, `deemix`) consomem o wildcard `*.daberga.com` compartilhado do Traefik — nenhum emite certificado individual:

| Router | Host | Porta LB |
|---|---|---|
| `bergastream-web` | `${WEB_DOMAIN}` | 80 |
| `bergastream-api` | `${API_DOMAIN}` | 8000 |
| `bergastream-deemix` | `${DEEMIX_DOMAIN}` | 6595 |

`db` e `redis` ficam apenas na rede interna (`internal`, bridge), sem exposição. O Nginx do `web` retorna 404 em `/api/` — a API vive em domínio separado; a `API_URL` é compilada no app Flutter em build-time via `--dart-define`. Sem middlewares Traefik adicionais.

## 📐 Regras de negócio
- **Referência contada:** um arquivo de áudio só é apagado do disco quando nenhum `playlist_tracks` nem `offline_tracks` aponta para o track (`CleanupService.run_once`).
- **Cache 48h** (`CACHE_EXPIRE_HOURS`, default 48): faixas tocadas mas não em playlists/offline ficam em `/data/music/cache` com `cache_expires_at`. O `CleanupService` roda a cada 1h (3600s): expira/remove arquivos órfãos e varre o cache dir removendo arquivos cujo *stem* não consta em `tracks`.
- **Streaming chunked** (`stream_service`): resolve `permanent > cache > arquivo-no-disco > download-while-streaming` (`_trigger_and_wait`, timeout 150s, com pub/sub `track_ready` + poll de disco de fallback). Arquivos completos servem com `Content-Length` + byte-range (206/200, chunk de 64 KB); arquivos ainda baixando (lock `.lock` presente) usam follow-mode com headers `X-BergaStream-Mode=follow` e `X-BergaStream-Estimated-Length` (estimativa por duração: ~110 KB/s FLAC, ~40 KB/s demais) para o ExoPlayer.
- **Segurança:** `get_current_user` valida o JWT (HS256, `sub`/`exp`) **e** exige uma linha em `sessions` com o mesmo token e `expires_at > now`. Logout deleta a sessão. Todos os endpoints exigem JWT exceto `/api/auth/*`, `/api/cover/proxy` e `GET /api/playlists/shared/{token}`. `/api/stream` aceita token via header Bearer **ou** query `?token=` (fallback para áudio HTML5 web). `require_admin` exige `is_admin`.
- **Pipeline de resolução por faixa:** (1) arquivo existente; (2) candidato Deezer verificado por duração (±5% ou ±10s, cache Redis de 7 dias) baixado via deemix — bitrate escolhido pela conta ARL (`9=FLAC` se `can_stream_lossless`, `3=MP3_320` se `can_stream_hq`, senão `1=MP3_128`); (3) fallback YouTube via yt-dlp (busca `ytsearch5`, scoring título 70% + artista 30%, threshold 0.4, com verificação de duração; download `bestaudio`→MP3); (4) último recurso: primeiro resultado YouTube não verificado (não cacheado). Verificação pós-download por mutagen.
- **Filas Redis (3 pools de workers isolados):** `QUEUE_STREAM` (yt-dlp on-demand, prioridade), `QUEUE_BG` (deemix; submissão serializada por `asyncio.Lock`; claim atômico do arquivo via `SADD` em `deemix:claimed_files`), `QUEUE_YTDLP` (yt-dlp background + fallback do deemix, retry exponencial 3s/6s/8s, máx 2 retries). Reserva atômica de slot via `SADD` em `DOWNLOADING_SET`; promoção BG→STREAM marcada em `STREAM_PROMOTED` (workers BG/ytdlp descartam o duplicado); `QUEUED_SET` faz dedupe. Na inicialização, `DOWNLOADING_SET` e `STREAM_PROMOTED` são limpos.
- **Single worker proposital** (`uvicorn --workers 1`): semáforos asyncio (pools yt-dlp stream/bg/search separados) e o lock do deemix precisam ser compartilhados no mesmo processo.
- **Playlists colaborativas:** dono edita metadados, gerencia colaboradores e exclui; colaboradores podem add/remover/reordenar faixas e disparar download permanente. `share_token` público permite visualizar e "seguir" (clonar) a playlist sem auth na visualização.
- **Registro de faixas:** faixas precisam estar em `tracks` (via `POST /api/tracks/register` ou auto-registro no `POST /api/queue/prefetch`) antes de stream/like/playlist/download — senão workers pulam, endpoints retornam 404, e o history ignora silenciosamente (evita violação de FK).
- **Rádio:** `source=lastfm` usa Last.fm `track.getSimilar` (variantes de artista, limpeza de título, diversidade máx 2/artista, suplemento via `artist.getSimilar`, resolução por Deezer em chunks com early-stop) e cai para Deezer radio nativo > artist top tracks; `source=ai` usa OpenRouter (default `google/gemini-flash-1.5`). Resultados cacheados 1h.
- **Multi-dispositivo (WebSocket `/api/sync`):** primeiro device vira `active`; só o active publica estado (broadcast aos demais); outros enviam comandos remotos ou fazem `transfer`. Estado mantido **só em memória** por usuário e descartado quando o último device sai.
- **Auto-updater:** background task (delay inicial 60s) faz `pip install --upgrade` de yt-dlp/ytmusicapi/spotipy/mutagen a cada 24h; status em `/api/admin/updater/status`, execução forçada em `/api/admin/updater/run`.
- **Restrições de admin:** não pode remover o próprio `is_admin` nem excluir a própria conta pelo painel.
- **Upload de capa:** apenas JPEG/PNG/WebP, máx 5 MB, salvo em `MEDIA_COVERS_PATH` e servido por `https://{API_DOMAIN}/media/covers/`.
- **Bootstrap de admin:** não automatizado — `register` sempre cria `is_admin=false`; o primeiro admin é promovido por outro admin ou manualmente no banco.

## 🗄️ Modelo de dados
PostgreSQL via SQLAlchemy 2.0 / Alembic (migrations `0001_initial_schema`, `0002_add_is_admin_and_collaborators`).

- **users** (`id` UUID PK, `username` String(50) unique idx, `email` String(255) unique idx, `password_hash`, `avatar_url`, `is_active` default true, `is_admin` default false [migration 0002], `created_at`/`updated_at`).
- **sessions** (`id` UUID PK, `user_id` FK users CASCADE, `token` String(512) unique idx, `expires_at`, `created_at`, `device_info`) — JWT persistido e validado no DB.
- **tracks** (`id` String(100) PK no formato `deezer_<id>`/`youtube_<id>`/`spotify_<id>`, `title`, `artist`, `album`, `album_id`, `artist_id`, `duration_ms`, `year`, `cover_url`, `source` String(20), `source_id`, `file_path` [permanent], `cache_path` [cache], `is_permanent`, `cache_expires_at`, `file_size_bytes` BigInteger, `audio_quality` String(10) [`flac`/`mp3_320`/`mp3_128`], `created_at`, `last_accessed_at`; property `current_file_path = file_path or cache_path`).
- **playlists** (`id` UUID, `owner_id` FK CASCADE, `name`, `description`, `cover_url`, `is_public`, `is_shared`, `share_token` String(64) unique idx [`secrets.token_urlsafe(48)`], timestamps) — `is_shared`/`share_token` já no schema inicial 0001.
- **playlist_tracks** (`id` UUID, `playlist_id` FK CASCADE, `track_id` FK CASCADE, `position` com `UniqueConstraint(playlist_id, position)`, `added_at`, `added_by` FK users SET NULL).
- **playlist_collaborators** (`playlist_id`+`user_id` PK composto, `added_at`) — criada na migration 0002.
- **liked_songs** (`user_id`+`track_id` PK composto, `liked_at`).
- **play_history** (`id` UUID, `user_id` FK CASCADE idx, `track_id` FK CASCADE, `played_at` idx, `duration_played_ms`, `completed`, `source_context`, `context_id`).
- **offline_tracks** (`user_id`+`track_id` PK composto, `downloaded_at`, `device_path`).

**Redis** (não-relacional): LISTs `bergastream:queue:{stream,bg,ytdlp}`; SETs `bergastream:{downloading,queued,promoted}` e `bergastream:deemix:claimed_files` (TTL 300s); pub/sub `bergastream:track_ready`; caches `bergastream:candidate:{deezer|yt}:*` (TTL 7 dias) e `bergastream:radio:*` (TTL 1h).

## 🔌 Endpoints / API
Montados sob `/api`. Principais grupos:

- **Auth:** `POST /auth/register`, `POST /auth/login`, `POST /auth/logout`, `GET /auth/me`, `PUT /auth/me`, `POST /auth/change-password`.
- **Busca/metadados:** `GET /search` (`source=deezer|spotify|youtube|all`), `GET /artist/{id}`, `GET /artist/{id}/tracks`, `GET /album/{id}`, `GET /cover/proxy` (sem auth).
- **Stream/fila:** `GET /stream/{track_id}` (Bearer ou `?token=`), `DELETE /stream/{track_id}/cache`, `POST /tracks/register`, `POST /queue/clear`, `POST /queue/prefetch`.
- **Biblioteca:** `GET /library/tracks`, `GET /library/stats`, `GET /library/likes`, `GET /library/offline`.
- **Playlists:** `GET/POST /playlists`, `GET/PUT/DELETE /playlists/{id}`, `GET /playlists/shared/{token}` (sem auth), `POST /playlists/shared/{token}/follow`, `POST /playlists/{id}/tracks`, `DELETE /playlists/{id}/tracks/{track_id}`, `PATCH /playlists/{id}/tracks/reorder`, `POST /playlists/{id}/cover`, `POST /playlists/{id}/share`, `GET/POST /playlists/{id}/collaborators`, `DELETE /playlists/{id}/collaborators/{user_id}`, `POST /playlists/{id}/download`, `GET /playlists/{id}/download/status`.
- **Likes/Offline:** `POST|DELETE /likes/{track_id}`, `POST|DELETE /offline/{track_id}`.
- **Histórico:** `POST /history`, `GET /history`, `GET /history/stats`, `DELETE /history`.
- **Rádio/Resolve:** `POST /radio/seed`, `GET /radio/next` (`source=lastfm|ai`), `POST /resolve/track`, `POST /resolve/playlist`.
- **Admin:** `GET/POST /admin/users`, `PATCH/DELETE /admin/users/{id}`, `GET /admin/queue-stats`, `GET /admin/updater/status`, `POST /admin/updater/run`.
- **Sync/Util:** `WS /sync?token=<jwt>`, `GET /health`, `GET /docs | /redoc | /openapi.json`.

## 🔗 Integrações externas
- **Deezer API** (`api.deezer.com`) — busca, metadados, rádio, top tracks, ISRC.
- **deemix** (sidecar) — download Deezer autenticado por ARL (REST `/api/connect`, `/api/loginArl`, `/api/addToQueue`; cancel via `/api/cancelAllDownloads` ou `/api/clearQueue`).
- **YouTube** via `yt-dlp` (busca + download) e **ytmusicapi** (metadados); `deno`+`nodejs` como runtimes JS do extractor.
- **Spotify Web API** via `spotipy` (Client Credentials) — busca, metadados, resolução de URLs.
- **Last.fm** (`ws.audioscrobbler.com/2.0`) — `track.getSimilar` / `artist.getSimilar` para rádio.
- **OpenRouter** (`openrouter.ai`) — rádio por IA (modelo configurável, default `google/gemini-flash-1.5`).
- **Chromecast / Cast v2** — descoberta via mDNS (`multicast_dns`) no frontend.
- **Let's Encrypt** (via Traefik) — CA do wildcard `*.daberga.com` que os routers consomem via `tls=true` (cert emitido uma única vez pela stack do Traefik; este app não emite cert individual).

## 🧩 Dependências internas (Bergatrix)
- **Traefik** — reverse proxy/TLS na rede externa compartilhada `bergatrix-proxy`, roteando `WEB_DOMAIN`, `API_DOMAIN` e `DEEMIX_DOMAIN`.
- **Rede `bergatrix-proxy`** (external: true).
- **PostgreSQL e Redis próprios da stack** (não compartilhados), apenas na rede interna `internal`.
- Volumes no host sob `${VOLUMES_BASE}/bergastream` (music, media, deemix_config, deemix_dl, db, redis).

> Não depende de Authentik nem LiteLLM; a stack traz seu próprio DB/Redis.

## 🔑 Variáveis de ambiente necessárias
*(apenas nomes — valores nunca expostos)*

- **Infra/Domínios:** `VOLUMES_BASE`, `WEB_DOMAIN`, `API_DOMAIN`, `DEEMIX_DOMAIN`, `CORS_ORIGINS`.
- **Banco/Cache:** `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_URL`.
- **Auth/JWT:** `JWT_SECRET_KEY`, `JWT_ALGORITHM`, `JWT_EXPIRE_MINUTES`.
- **Fontes de música:** `DEEMIX_ARL`, `DEEMIX_URL`, `DEEMIX_DOWNLOADS_PATH`, `SPOTIPY_CLIENT_ID`, `SPOTIPY_CLIENT_SECRET`, `PUID`, `PGID`.
- **IA/Recomendação:** `OPENROUTER_API_KEY`, `OPENROUTER_MODEL`, `LASTFM_API_KEY`.
- **Paths/Cache:** `MUSIC_PERMANENT_PATH`, `MUSIC_CACHE_PATH`, `MEDIA_COVERS_PATH` *(existe em `config.py`; ausente do `.env.example`)*, `CACHE_EXPIRE_HOURS`.
- **App/Tuning:** `LOG_LEVEL`, `STREAM_WORKERS`, `DEEMIX_BG_WORKERS`, `YTDLP_BG_WORKERS`, `MAX_YT_CONCURRENT`, `MAX_YT_STREAM_CONCURRENT`, `MAX_YT_SEARCH_CONCURRENT` *(existe em `config.py`, default 4; ausente do `.env.example`)*.
- **Frontend (build-arg, não env do backend):** `API_URL` (injetado via `--dart-define`).

## 🗂️ Estrutura de código
- `backend/app/main.py` — cria o FastAPI, inclui routers sob `/api`, monta `/media/covers`, configura CORS e inicia 3 background tasks no lifespan (cleanup, fila de download, updater).
- `backend/app/config.py` — `Settings` (pydantic-settings, `env_file='.env'`), tuning de workers/semáforos, `cors_origins_list`.
- `backend/app/database.py` — engine async, `AsyncSessionLocal`, `Base`, `get_db`.
- `backend/app/dependencies.py` — `HTTPBearer`, `get_current_user`, `require_admin`.
- `backend/app/models/` — `user`, `track`, `playlist`, `history`, `offline`.
- `backend/app/schemas/` — `auth`, `track`, `playlist`, `history` (Pydantic).
- `backend/app/routers/` — `auth`, `search`, `stream`, `library`, `playlists`, `history`, `radio`, `users` (+`offline_router`), `admin`, `resolve`, `sync` (WebSocket).
- `backend/app/services/` — `auth_service` (JWT/bcrypt/sessões), `metadata_service` (Deezer/Spotify/YouTube), `downloader_service` (deemix + yt-dlp, follow-mode), `queue_service` (3 pools Redis), `stream_service` (byte-range/follow), `radio_service` (Last.fm/IA/Deezer), `cleanup_service`, `updater_service`.
- `backend/alembic/versions/` — `0001_initial_schema`, `0002_add_is_admin_and_collaborators`.
- `frontend/lib/core/` — `api_client` (Dio + interceptor JWT), `constants` (`kApiBaseUrl`), `router`, `theme`, `offline_cache`, `storage`, `logger`.
- `frontend/lib/{providers,screens,services,widgets,models}/` — Riverpod codegen, telas (home/search/library/playlist/album/artist/radio/history/player/settings/auth), `audio_player_service`, `offline_service`, `cast/` (web/io), widgets de player/cards/layout.
- `frontend/scripts/` — `generate_icons.py` (cairosvg) **e** `generate_icons_pillow.py` (Pillow puro, alternativa Windows; **ambos presentes**).
- `frontend/nginx.conf`, `frontend/Dockerfile`, `backend/Dockerfile`, `docker-compose.yml`, `docker-compose.dev.yml`, `CLAUDE.md`, `.env.example`.

## 🛡️ Gestão de segredos
Segredos são providos via arquivo `.env` **não versionado** (o `.gitignore` exclui `.env` e `*.env`); o repositório versiona apenas `.env.example` com placeholders (`changeme_*`, `your_*_here`). O `docker-compose.yml` usa `env_file: .env` no serviço `api` e injeta variáveis específicas em `db` (`POSTGRES_*`) e `deemix` (`ARL=${DEEMIX_ARL}`, `PUID`, `PGID`). O backend lê tudo via pydantic-settings. JWT é assinado com `JWT_SECRET_KEY` (HS256) e as sessões são persistidas/validadas em `sessions`; senhas com bcrypt; o frontend guarda o JWT em `flutter_secure_storage`.

**Nenhum segredo real foi encontrado commitado na árvore canônica.** Observação: o `docker-compose.dev.yml` contém credencial de desenvolvimento fraca/hardcoded (`POSTGRES_PASSWORD=devpassword`, também como default em `config.py`) — é um placeholder de ambiente local, não um segredo de produção, mas recomenda-se não reaproveitá-lo fora do dev.

## 🚧 Notas de evolução / pendências
- O `nginx.conf` serve só o Web (SPA) e retorna 404 em `/api/` — API e Web em domínios Traefik separados.
- Tuning de concorrência evoluiu (deemix workers 1→3, `_BG_SLEEP` 0.5s→0, semáforos yt-dlp separados); `max_download_workers` e `background_workers` marcados como deprecated. O log de `start_workers` ainda comenta "deemix is single-consumer" embora o default agora seja 3.
- Docstring de `download_youtube_by_id` menciona retry em 429 com 30s/60s, mas o código usa `_MAX_YT_RETRIES=0` (não retenta — encaminha ao deemix). Docstring desatualizado.
- `_sweep_orphan_files` usa `f.stem` para casar com `track_id`; um lock `<id>.mp3.lock` tem stem `<id>.mp3` (não casa) e seria removido como órfão — risco potencial durante downloads concorrentes.
- `requirements.txt` inclui `aioredis` (arquivado/deprecado) ao lado de `redis`; o código usa `redis.asyncio`.
- `history/stats` retorna `hours_per_day=[]` (campo presente no schema, não populado).
- `frontend/windows/` aparece como untracked (alvo desktop recém-adicionado); `pubspec` declara `ios:false`.
- `OfflineService` em web apenas registra no backend; download real de arquivo só em plataformas não-web.
- Migrations vão até 0002; demais campos da Playlist já estavam no schema 0001.

## ❓ Perguntas em aberto
- Como o primeiro admin (`is_admin=true`) é criado em produção? Confirmado que não há seed/bootstrap; presumivelmente promovido manualmente no DB no primeiro deploy.
- O sweep de órfãos pode apagar locks parciais `<id>.ext.lock` (stem não casa com `track_id`) durante downloads concorrentes — há proteção (filtrar `.lock`) ou é inofensivo na prática?
- Single worker + estado de sync apenas em memória: como escalar horizontalmente? Não há coordenação multi-processo além do Redis para as filas.
- O bitrate deemix segue a capacidade da conta ARL; não há config para forçar qualidade, e o ARL expira sem fluxo de renovação automatizado.
- Existe de fato cache Redis para busca Deezer (`bergastream:deezer_search:*`, TTL 24h)? Não foi confirmado nos arquivos lidos (`metadata_service` não inspecionado nesta passagem).

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
