# bergastream — Streaming de música multiusuário, auto-hospedado (substituto do Spotify)

> **Categoria:** app | **Caminho:** `03-apps/bergastream` | **Status:** active (reescrita de 2026; a versão anterior está em `03-apps/bergastream02`)

## 🎯 Finalidade
Busca músicas no Spotify (sem conta, caminho anônimo), no Deezer e no YouTube Music, baixa cada faixa sob demanda (Deezer via Deemix em MP3 320, com YouTube/yt-dlp como alternativa) e toca por streaming. Faixas de playlist buscam qualidade melhor com o tempo (FLAC pelo Deemix ou pela Usenet via Lidarr). Playlists colaborativas, histórico com métricas ("Seu som"), páginas de artista/álbum, importação de links (Spotify/Deezer/YouTube) e download de playlists para ouvir offline nos apps.

Clientes: **app web** (servido pelo próprio stack) e **apps Android, Windows e Linux** (Flutter), publicados como release no GitHub e com atualização pelo próprio app.

Documentação detalhada no próprio stack: `03-apps/bergastream/Documentação.md` (especificação), `ja_implementado.md`, `docs/API_MAP.md`, `docs/DEPLOY.md`, `docs/USUARIOS.md`, `docs/RELEASE.md`.

## 🧱 Stack tecnológica
- **Backend:** Python 3.12, FastAPI, asyncpg (SQL direto, sem ORM), migrações **dbmate** (`backend/db/migrations/*.sql`), Redis (fila de downloads, cache, limite de tentativas), PyJWT + Argon2 (`argon2-cffi`), httpx, ytmusicapi, yt-dlp (+ Deno), ffmpeg/ffprobe.
- **Worker:** mesmo código (`python worker.py`) consumindo a fila do Redis.
- **Frontend:** Flutter 3.44 / Dart 3.12 — Riverpod 3, go_router, dio, just_audio (+ audio_service no Android, media_kit no desktop), Drift (banco local dos apps), background_downloader.
- **Web:** `flutter build web --release --no-web-resources-cdn` servido por nginx (alpine), que também faz proxy de `/api/`.
- **Sidecar:** Deemix (`ghcr.io/bambanah/deemix`, fork mantido; a imagem antiga `bockiii/deemix-docker` parou em 2022).
- **Spotify:** biblioteca SpotifyScraper (token anônimo do web player) + endpoint interno de metadados para o ISRC; a Web API oficial exige Premium do dono do app desde fev/2026.

## 📦 Serviços / Containers

| Serviço (`container_name`) | Imagem / build | Porta | Volumes (`${STORAGE_PATH}/…`) | Redes |
|---|---|---|---|---|
| `bergastream-web` | build `./frontend` (Flutter web → nginx) | 80 | — | internal, **bergatrix-proxy** |
| `bergastream-api` | build `./backend` (uvicorn) | 8000 | `music`, `deemix/downloads`, `pydeps` | internal, egress |
| `bergastream-worker` | build `./backend` (`python worker.py`) | — | `music`, `deemix/downloads`, `pydeps`, `lidarr/music` (ro) | internal, egress |
| `bergastream-lidarr` | `lscr.io/linuxserver/lidarr` | 8686 (`lidarr.${DOMAIN}`, internal-only) | `lidarr/config`, `lidarr/music`, downloads do SABnzbd (`USENET_DOWNLOADS_DIR`) | internal, egress, bergatrix-proxy (Traefik, SABnzbd, Prowlarr) |
| `bergastream-deemix` | `ghcr.io/bambanah/deemix` | 6595 | `deemix/config`, `deemix/downloads` | internal, egress |
| `bergastream-db` | `postgres:16-alpine` | 5432 | `db` | internal |
| `bergastream-redis` | `redis:7-alpine` (appendonly) | 6379 | `redis` | internal |
| `bergastream-migrate` | `ghcr.io/amacneil/dbmate:2` (roda e sai) | — | `./backend/db/migrations` (ro) | internal |

- `bergastream-internal` tem `internal: true` (sem internet); `bergastream-egress` é bridge comum para quem busca no Spotify/YouTube/Deezer.
- Só o `web` entra na `bergatrix-proxy`. O nginx resolve a API pelo nome `bergastream-api` com o DNS do Docker a cada 10 s (API recriada não derruba o web).
- Nenhuma porta publicada no host em produção (`docker-compose.dev.yml` expõe 8080/8000 para desenvolvimento).

## 🌐 Domínios / Roteamento
Modelo **B** de `docs/modelos-labels-traefik.md`, host `bergastream.${DOMAIN}`, serviço `bergastream-service` (porta 80):

| Router | Regra | Middlewares | Prioridade |
|---|---|---|---|
| `bergastream-router` | host, exceto `/api-access-bypass` e aparelhos de confiança | `crowdsec-bouncer@file`, `public-auth@file` | 100 |
| `bergastream-direct` | host + IPs de confiança | — | 110 |
| `bergastream-bypass` | host + `PathPrefix(/api-access-bypass/api)` | `crowdsec-bouncer@file`, `api-access-bypass@file` | 120 |

O bypass libera **só a API** para os apps (o app web continua atrás do Authentik). Os apps recebem `bergastream.daberga.com` e testam primeiro `…/api-access-bypass` (funciona dentro e fora de casa), depois o endereço puro (servidor local sem Traefik).

O nginx confia no `X-Forwarded-For` vindo de redes privadas (`set_real_ip_from`), para o limite de tentativas de login enxergar o IP real.

## 📐 Regras de negócio (resumo)
- **Login obrigatório** em toda a API, exceto `/api/auth/{config,login,refresh,logout,register}`, `/api/images` e a imagem de capa das playlists (`GET /api/playlists/{id}/cover`). Na web, nenhuma tela abre sem login; nos apps dá para usar sem login (biblioteca local e músicas baixadas).
- **Tokens:** access JWT HS256 de 15 min; refresh opaco de 30 dias com rotação e revogação da família inteira se um refresh antigo for reutilizado; token curto de stream (`?t=`) para o player.
- **Limite de tentativas:** 5 falhas por usuário+IP em 15 min → bloqueio de 15 min (Redis).
- **Cadastro:** desligado (`ALLOW_REGISTRATION=false`); contas pela CLI (`docs/USUARIOS.md`).
- **Download de faixa:** Deemix primeiro (sob demanda MP3 320, 128 só se a faixa não tiver 320); faixa do Spotify sem ISRC: ISRC pelos metadados do Spotify ou busca no Deezer por artista + título + duração; o arquivo é identificado pelo item da fila do Deemix (não pelo "mais novo da pasta") e as tags são conferidas com ffprobe — título errado é descartado e cai no YouTube. `python -m app.downloads.verify [--fix]` audita/repara a base.
- **Qualidade:** lida do arquivo com ffprobe (`files.codec/bitrate_kbps/bit_depth/quality_rank`: 10 MP3 128, 20 MP3 192/Opus do YouTube, 30 MP3 320, 40 FLAC, 50 FLAC 24 bits). YouTube guarda o áudio original (Opus/AAC), sem converter.
- **Melhoria das playlists** (`app/quality/upgrader.py`, no worker): faixa em playlist entra em `quality_upgrades`; Deemix FLAC → 320 (a cada 30 dias) e, sem FLAC, o álbum de estúdio no Lidarr (ISRC → MusicBrainz; monitora só aquele álbum, busca todo dia nos primeiros `UPGRADE_DAILY_DAYS` e depois toda semana, dentro de `LIDARR_MAX_ACTIVE`/`LIDARR_DAILY_SEARCHES`; confere a cada 30 min numa fila própria; o FLAC é copiado da pasta do Lidarr, medleys "A / B" viram um FLAC só). Só troca o arquivo por um melhor.
- **Spotify sem conta:** teste diário no worker (`app/search/spotify_health.py`); se a biblioteca quebrar e houver versão nova no PyPI, instala em `pydeps`, testa num processo separado, ativa e reinicia worker e API.
- **Arquivos:** referência contada (playlist/uso); cache de faixas soltas por `CACHE_TTL_HOURS` (48 h); limpeza manual por admin (`POST /api/admin/cleanup`).
- **Playlists:** dono, editores e leitores (`playlist_members`), ordem manual, capa própria (JPEG/PNG/WebP até 5 MB), "adicionado por".
- **Histórico:** `POST /api/history` idempotente por `client_id` (apps enviam o que tocou offline ao reconectar); `GET /api/me/stats` alimenta o Início.
- **Imagens:** `/api/images?url=` é proxy com lista de hosts permitidos (scdn.co, spotifycdn.com, googleusercontent.com, ytimg.com, dzcdn.net), só https, cache em disco, máx. 5 MB.

## 🗄️ Modelo de dados
Migrações dbmate `0001`–`0013`: `tracks`, `external_ids`, `files` (+ qualidade medida, `0013`), `quality_upgrades` (fila de melhoria das playlists, `0013`), `users` (+ `is_admin`, `password_hash` Argon2), `refresh_tokens` (famílias), `playlists` (+ descrição, capa, timestamps), `playlist_tracks` (posição, `added_by`), `playlist_members` (viewer/editor), `play_history` (`client_id` único).

## 🔌 Endpoints / API
Mapa completo em `03-apps/bergastream/docs/API_MAP.md`. Grupos: `/api/auth/*`, `/api/search` e `/api/search/full`, `/api/resolve`, `/api/artists/*`, `/api/albums/*`, `/api/play` + `/api/tracks/{id}/{status,stream,stream-token,download}`, `/api/playlists/*` e `/api/me/playlists`, `/api/users/directory`, `/api/history`, `/api/me/stats`, `/api/images`, `/api/admin/cleanup`.

## 🔗 Integrações externas
Spotify (caminho anônimo: SpotifyScraper + `spclient` para ISRC; PyPI para a atualização automática), Deezer (API pública), Lidarr (serviço próprio; usa o SABnzbd e o Prowlarr do servidor), YouTube Music (ytmusicapi), YouTube (yt-dlp), Deezer (Deemix com ARL), CDNs de capas (via proxy), GitHub Releases (os apps consultam `api.github.com/repos/Agelinena/bergatrix/releases`).

## 🧩 Dependências internas (Bergatrix)
Traefik (`bergatrix-proxy`, wildcard `*.daberga.com`), Authentik (`public-auth@file`), CrowdSec (`crowdsec-bouncer@file`), middleware `api-access-bypass@file` do `dynamic.yml`.

## 🔑 Variáveis de ambiente necessárias
`STORAGE_PATH` (`/mnt/storage/docker_volumes/bergastream`), `DOMAIN`, `PUID`/`PGID`, `POSTGRES_DB/USER/PASSWORD`, `DATABASE_URL`, `DEEMIX_ARL` (conta Premium para 320/FLAC), `LIDARR_API_KEY`/`USENET_DOWNLOADS_DIR`/`LIDARR_KEEP_ALBUMS`/`LIDARR_QUALITY_PROFILE`/`LIDARR_METADATA_PROFILE`/`UPGRADE_DAILY_DAYS`/`LIDARR_MAX_ACTIVE`/`LIDARR_DAILY_SEARCHES` (opcionais), `TZ`, `JWT_SECRET`, `ALLOW_REGISTRATION`, `CACHE_TTL_HOURS`, `LOG_LEVEL`. Ver `.env.example`.

## 🗂️ Estrutura de código
```
03-apps/bergastream/
├── docker-compose.yml / docker-compose.dev.yml / .env.example
├── backend/   app/{auth,api,search,catalog,playlists,history,downloads,images,core}, worker.py, db/migrations, tests/
├── frontend/  lib/{app,core,data,features}, test/, integration_test/, tool/make_icons.py, nginx.conf, Dockerfile
└── docs/      API_MAP.md, DEPLOY.md, USUARIOS.md, RELEASE.md, design/
```
CI: `.github/workflows/bergastream-release.yml` (tag `bergastream-vX.Y.Z` → testes + APK/Linux/Windows → release).

## 🛡️ Gestão de segredos
`.env` fora do git (`JWT_SECRET`, senha do banco, ARL). Chave de assinatura do Android fora do repositório (`~/Documentos/bergastream-assinatura-android/`) e nos secrets `ANDROID_*` do GitHub.

## 🚧 Notas de evolução / pendências
- Deemix trocado pelo fork mantido (out/2026); acompanhar se as falhas antigas (HREF) somem.
- Qualidade por aparelho: `?quality=original|high|normal|low` no stream/download (versões convertidas em `music/variants`); o app escolhe por Wi-Fi/dados/offline e troca as cópias offline quando a qualidade entregue muda.
- Lidarr só de passagem: copiada a música, o resto do álbum é apagado (`LIDARR_KEEP_ALBUMS`).
- Apps Windows/Linux sem assinatura de código; Linux depende de `libmpv` no sistema.
- Sem comando para remover usuário (usar troca de senha aleatória).
