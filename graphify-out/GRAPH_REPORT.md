# Graph Report - bergatrix  (2026-11-06)

## Corpus Check
- 565 files · ~406,236 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 76 file(s) not represented in the graph (top: (none) 22, .example 16, .xml 9)

## Summary
- 9355 nodes · 17701 edges · 429 communities (375 shown, 54 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 816 edges (avg confidence: 0.89)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `95166a77`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- player_controller.dart
- database.dart
- test_subtitle_refine.py
- create_pool
- lyrics.dart
- Engine
- desktop_shell.dart
- package:flutter_riverpod/flutter_riverpod.dart
- database.g.dart
- playlist_store.dart
- sessionProvider
- app/static/assets/js/app.js
- sessions/service.py
- download_manager.dart
- CurrentUser
- session_repository.dart
- session_sheet.dart
- Pipeline
- downloads/service.py
- settings_screen.dart
- api/static/assets/js/app.js
- server.py
- api/main.py
- auth/routes.py
- CurrentUser
- jsQR.js
- accounts/routes.py
- group_session.dart
- ConsumerWidget
- sync_test.dart
- App
- worker/core/scanner.py
- helpers.dart
- session.dart
- device_controller.dart
- fake_player.dart
- server_status_repository.dart
- OIDCClient
- arr.py
- queue_panel.dart
- CurrentUser
- asyncio
- package:flutter/material.dart
- group_session_test.dart
- Store
- web/main.py
- test_auth.py
- _
- Storages.tsx
- protocol.js
- app
- bergakup/main.py
- admin_users_screen.dart
- json
- playlist_models.dart
- playlist_repository.dart
- play_queue.dart
- access_redirect_test.dart
- accounts/service.py
- downloads/youtube.py
- core/bazarr.py
- subprocess
- catalog/service.py
- Lidarr
- sync_service.dart
- test_integration.py
- internal_users.yml
- berga_sizes.dart
- auth.py
- wazuh.dashboard
- restic.go
- my_application.cc
- form_dialog.dart
- dart:async
- update_service.dart
- app_harness.dart
- lyrics.dart
- track_row.dart
- account_repository.dart
- playlists.py
- search_full.dart
- playlist_sync_test.dart
- track_menu.dart
- jobs.py
- bouncer
- history/routes.py
- app_harness.dart
- test_oidc.py
- update_prompt.dart
- web_api.py
- spotify.py
- SearchResult
- package:dio/dio.dart
- context.Context
- test_units.py
- 3. Passos 6 a 13
- StatelessWidget
- Segment
- wazuh.indexer.yml
- dependencies
- drop
- environment
- account.dart
- auth.dart
- ops.py
- List
- audio_engine.dart
- networks
- catalog_repository.dart
- lidarr.py
- key_value_store.dart
- ../theme/berga_colors.dart
- Worker
- utils.cpp
- traefik
- lyrics/service.py
- traefik — Reverse proxy / ingress central do homelab Bergatrix (Traefik v3.6.2) com TLS wildcard automatico via Let's Encrypt e DNS-01 challenge no deSEC.
- auth_interceptor_test.dart
- fake_auth_repository.dart
- playback_repository.dart
- qrcode.mjs
- Settings
- server/routes.py
- devices/routes.py
- stats.dart
- player_controller_test.dart
- playlist_screen.dart
- app_release.dart
- variants.py
- 00-visao-geral.md
- 📐 Bergatrix — Convenções & Padrões de Desenvolvimento
- test_quality.py
- app_text_field.dart
- Processor
- agent_api.py
- login.go
- DataClass
- history_repository.dart
- sync_notices.dart
- lyrics_repository.dart
- oidc_launcher_io.dart
- FlutterWindow
- win32_window.cpp
- homeassistant
- dataclasses
- environment
- re
- FakeLidarr
- make_icons.py
- authentik — Provedor de identidade (IdP) e SSO self-hosted que centraliza autenticacao e fornece ForwardAuth ao Traefik
- app.go
- cover.dart
- search_result.dart
- search_repository.dart
- resolve.py
- crowdsec
- test_quality.py
- routes.dart
- docker.go
- track_actions_sheet.dart
- @JsonSerializable
- auth_repository.dart
- text_input_dialog.dart
- bergakup/auth.py
- fake_update.dart
- qrcode
- Subir
- Translator
- search_screen.dart
- berga_text.dart
- buttons.dart
- .addData
- docs/README.md
- ollama
- worker
- opensearch_dashboards.yml
- Modelos de Labels do Traefik — Bergatrix
- homeassistant — Plataforma de automação residencial (Home Assistant Core em container) exposta via Traefik no Modelo B (Authentik de fora, direto para dispositivos de confiança, bypass para o app Companion)
- jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC
- n8n — Plataforma de automação de workflows self-hosted, com imagem customizada (Python/yt-dlp) e execução de comandos habilitada
- networks — Runbook de bootstrap que cria as duas redes Docker externas compartilhadas (bergatrix-proxy e bergatrix-backend) das quais todo o homelab depende
- rss — Leitor de feeds RSS auto-hospedado (FreshRSS) com PostgreSQL dedicado, exposto via Traefik em freshrss.${DOMAIN}
- Segment
- artist_screen.dart
- local_playlists.dart
- http_auth_repository.dart
- media_notification.dart
- Armazenamento
- berga-news — Agregador de RSS auto-hospedado que agrupa artigos por tópico com IA e gera digests resumidos em português
- bitwarden — Gerenciador de senhas auto-hospedado (Vaultwarden) exposto via Traefik com o wildcard TLS compartilhado *.daberga.com
- cloudbeaver — Console web de administracao de banco de dados (CloudBeaver) para o Postgres global do homelab, protegido por Tailscale + Authentik SSO via Traefik
- drop — Transferência segura e efêmera de mensagens/segredos entre dois dispositivos, com criptografia ponta-a-ponta no navegador e servidor como relay zero-knowledge.
- litellm — Proxy/gateway LiteLLM auto-hospedado que expoe uma API unica compativel com OpenAI, roteando para modelos da OpenRouter (free e pagos), com um sidecar que sincroniza o catalogo e gerencia virtual keys
- openuiweb — Open WebUI (interface estilo ChatGPT) auto-hospedada como "Bergatrix AI", conectada ao LiteLLM e a um Ollama local com GPU NVIDIA, exposta em chat.${DOMAIN} mas restrita a LAN
- transcriptor — Serviço de transcrição de áudio/vídeo com Whisper (faster-whisper) acelerado por GPU, com UI web, fila e API REST v1
- wazuh — Plataforma SIEM/XDR (Wazuh 4.7.2) auto-hospedada para monitoramento de segurança, detecção de intrusão e conformidade
- vaultwarden
- test_catalog.py
- dumps.go
- optimizer
- Nextcloud
- bergastream — Streaming de música multiusuário, auto-hospedado (substituto do Spotify)
- ghostmap — Geocodificador privacy-first via Whoogle + Nominatim, com UI/PWA Flask que gera links geo:/OpenStreetMap
- jobs
- api
- immich-machine-learning
- collabora
- egress
- Padrão de stacks
- cloudbeaver
- logging
- services
- deemix
- bool get
- Migração para o novo armazenamento
- Win32Window
- Drop
- download_manager_test.dart
- migrate
- db
- with
- postgresql
- migrate
- Bergastream — usuários
- renderRole
- worker.py
- web/manifest.json
- 1. Backend (FastAPI + PostgreSQL + Redis)
- assets/manifest.json
- services
- audit
- api
- nodes
- Redes Docker
- 🛡️ Bergatrix — Arquitetura de Rede & Segurança
- ldap
- server
- Plan
- db
- Bergastream — subir no servidor
- format.dart
- @DataClassName
- windows/flutter/generated_plugin_registrant.cc
- .MessageHandler
- services
- database
- immich-server
- catalogo
- jellyfin
- networks
- services
- x-env
- Transcriptor
- Padrão de acesso (Traefik + Authentik)
- steps
- dashboard
- traefik.yml
- dnsChallenge
- docker
- services
- worker
- healthcheck
- GroupSessionController
- dev_dependencies
- _this
- environment
- redis
- bazarr
- legendarr-web
- prowlarr
- qbittorrent
- radarr
- recyclarr
- sabnzbd
- sonarr
- redis
- system_unix.go
- 🍊 Bergatrix — Visão Geral
- 1. O que está migrado (no repositório)
- release
- websecure
- environment
- app_layout.dart
- environment
- web
- worker
- Bergastream — login pelo Authentik
- 11. Passos de implementação
- Point
- Bergastream — O que já foi implementado
- _this
- legendarr-worker
- torrent-indexer-br
- db
- app
- berga_colors.dart
- cron
- 1513629884013
- Infraestrutura
- Documentação da Infraestrutura: Edge Node L4 & Homelab
- healthcheck
- redis
- pathlib
- lidarr
- redis
- track.dart
- playlist_merge.dart
- PlayerController
- pubspec.yaml
- flutter
- _this
- qrPolynomial
- healthcheck
- flaresolverr
- healthcheck
- generator
- Login pelo Authentik em apps sem OIDC (LDAP)
- tls
- web
- bergatrix.yaml
- player_controller_test.dart
- services
- pot-provider
- Bergastream — versões dos apps (Android, Windows, Linux)
- analysis_options.yaml
- playlist.dart
- FileAssembler
- router.dart
- migrate
- compilerOptions
- version
- windows
- 🍊 BERGATRIX
- bouncer
- entryPoint
- auth/repository.py
- web_version_watcher.dart
- depends_on
- Ligar e desligar tudo
- env
- acquis.yaml
- page_reload.dart
- Scanner
- android
- test
- start-traefik.sh
- MainActivity.kt
- greeting.dart
- logout
- playlist_cover_test.dart
- bergastream
- derrubar-tudo.sh
- subir-tudo.sh
- app
- page_reload_stub.dart
- flutter
- 10-exige-instalacao.sh
- init.sh
- wazuh/README.md
- CLAUDE.md
- plan.py
- features_test.go
- migrate
- local_playlists.dart
- secrets
- runs.go
- web/app.js
- environment
- dart:math
- 🔑 Bergatrix — Guia do `.env` (como construir, o que ter e como manipular)
- services
- db
- mail.py
- claude-sync
- main
- traefik — Reverse proxy / ingress central do homelab Bergatrix (Traefik v3.6.2) com TLS wildcard automatico via Let's Encrypt e DNS-01 challenge no deSEC.
- healthcheck
- environment
- Bergastream — Mapa da API (API_MAP.md)
- environment
- build
- oidc_launcher_web.dart
- fake_oidc.dart
- codigo/build.sh
- build.sh
- install.sh
- types.d.ts
- FakeSessionRepository
- bergakup/agent
- updateSendButton
- onSwap
- SessionSocket
- playlists/service.py
- UpdateLauncher
- claude-sync
- Hub
- catalog_navigation.dart
- oidc_launcher.dart
- sync_test.go
- tempfile
- app/db.py
- Budget
- SessionController
- Channel
- Settings
- update_job
- upgrader.py

## God Nodes (most connected - your core abstractions)
1. `CurrentUser` - 82 edges
2. `get_pool()` - 78 edges
3. `sessionProvider` - 68 edges
4. `_` - 52 edges
5. `get_redis()` - 51 edges
6. `create_pool()` - 50 edges
7. `close_pool()` - 49 edges
8. `Engine` - 41 edges
9. `PlayRequest` - 40 edges
10. `User` - 40 edges

## Surprising Connections (you probably didn't know these)
- `🗄️ Modelo de dados` --references--> `summary()`  [INFERRED]
  docs/legado/stacks/berga-news.md → 03-apps/bergastream/backend/app/playlists/service.py
- `Backup` --references--> `docker()`  [INFERRED]
  docs/02-armazenamento.md → 00-infrastructure/bergakup/agent/docker.go
- `🗄️ Modelo de dados` --references--> `timestamp()`  [INFERRED]
  docs/legado/stacks/transcriptor.md → 03-apps/transcriptor/app/formats.py
- `8. Exposições conhecidas (rotacionar) 🔴` --references--> `disabled()`  [INFERRED]
  docs/legado/01-arquitetura-rede-seguranca.md → 03-apps/bergastream/backend/app/accounts/notices.py
- `🛡️ Gestao de segredos` --references--> `disabled()`  [INFERRED]
  docs/legado/stacks/wazuh.md → 03-apps/bergastream/backend/app/accounts/notices.py

## Import Cycles
- None detected.

## Communities (429 total, 54 thin omitted)

### Community 0 - "player_controller.dart"
Cohesion: 0.01
Nodes (143): act, addAllToQueue, addToQueue, _advance, applyRemoteState, applySession, _applyVolume, attachGroup (+135 more)

### Community 1 - "database.dart"
Cohesion: 0.02
Nodes (92): addNotice, addPendingPlay, addPlaylistOp, asResult, bytes, clearNotices, collaborators, _countQualities (+84 more)

### Community 2 - "test_subtitle_refine.py"
Cohesion: 0.07
Nodes (42): clean_text(), fit_reading_time(), _normalize(), OllamaEmbedder, read_subtitle(), reading_cps(), refine_cues(), refine_file() (+34 more)

### Community 3 - "create_pool"
Cohesion: 0.06
Nodes (41): main(), _main(), _read_password(), create_user(), create_access_token(), hash_password(), _now(), close_pool() (+33 more)

### Community 4 - "lyrics.dart"
Cohesion: 0.05
Nodes (41): build, DesktopShell, _trackList, build, build, createState, of, openFullPlayer (+33 more)

### Community 5 - "Engine"
Cohesion: 0.10
Nodes (15): Activity, Counts, Dav, DavEntry, Engine, EngineStatus, localFile, LocalProject (+7 more)

### Community 6 - "desktop_shell.dart"
Cohesion: 0.06
Nodes (19): AppShell, build, currentIndex, goToTab, miniPlayerBottom, MobileShell, _NavBar, navigationShell (+11 more)

### Community 7 - "package:flutter_riverpod/flutter_riverpod.dart"
Cohesion: 0.02
Nodes (81): AppFrame, build, child, contentKey, framedFrom, platform, NotFoundScreen, title (+73 more)

### Community 8 - "database.g.dart"
Cohesion: 0.02
Nodes (97): addedAt, addedBy, album, artist, attempts, audioPath, coverPath, coverUrl (+89 more)

### Community 9 - "playlist_store.dart"
Cohesion: 0.03
Nodes (95): localDatabaseProvider, historyRepositoryProvider, playlistRepositoryProvider, downloadManagerProvider, _set, addAliases, addTracks, _again (+87 more)

### Community 10 - "sessionProvider"
Cohesion: 0.04
Nodes (60): BergastreamApp, _BergastreamAppState, build, createState, dispose, initState, _lifecycle, _onResume (+52 more)

### Community 11 - "app/static/assets/js/app.js"
Cohesion: 0.12
Nodes (30): actions, addFileItem(), addInboxItem(), addTextItem(), app, applyTheme(), clearInbox(), CLOSE_MESSAGES (+22 more)

### Community 12 - "sessions/service.py"
Cohesion: 0.06
Nodes (53): Ainda não testado / limitações conhecidas, add(), broadcast(), close_user(), Connection, forget(), online_users(), open_rooms() (+45 more)

### Community 13 - "download_manager.dart"
Cohesion: 0.04
Nodes (59): setCover, playbackRepositoryProvider, active, appDocuments, audio, available, changes, count (+51 more)

### Community 14 - "CurrentUser"
Cohesion: 0.08
Nodes (31): admin_cleanup(), _get_pool(), _loudness(), play(), QualitiesRequest, stream_token(), track_loudness(), track_qualities() (+23 more)

### Community 15 - "session_repository.dart"
Cohesion: 0.03
Nodes (68): act, actions, addedBy, anchorAt, apiValue, base, calls, _channel (+60 more)

### Community 16 - "session_sheet.dart"
Cohesion: 0.05
Nodes (44): PauseMode, SessionMember, sync, transfer, groupSessionProvider, build, _busy, c (+36 more)

### Community 17 - "Pipeline"
Cohesion: 0.05
Nodes (6): Pipeline, TranslationQueue, TranslationStats, Legendarr-worker (legenda + validação), Optimizer (reencode), 📐 Regras de negocio

### Community 18 - "downloads/service.py"
Cohesion: 0.06
Nodes (25): redownload(), deemix_into(), deezer_id_for(), _do_download_deezer(), _do_download_spotify(), _do_download_youtube_fallback(), _fallback_after_deemix(), _is_expected() (+17 more)

### Community 19 - "settings_screen.dart"
Cohesion: 0.05
Nodes (41): build, _buildPage, _chips, createState, _dark, _row, _shuffle, _source (+33 more)

### Community 20 - "api/static/assets/js/app.js"
Cohesion: 0.09
Nodes (65): api(), ApiError, onUnauthorized(), putChunk(), setUnauthorizedHandler(), sleep(), uploadFile(), actions() (+57 more)

### Community 21 - "server.py"
Cohesion: 0.05
Nodes (17): client_address(), expire_rooms(), lifespan(), other(), Peer, read_join(), relay(), Room (+9 more)

### Community 22 - "api/main.py"
Cohesion: 0.09
Nodes (45): admin_status(), audio(), callback(), cancel_job(), check_capacity(), check_options(), complete_upload(), config() (+37 more)

### Community 23 - "auth/routes.py"
Cohesion: 0.06
Nodes (40): create_reset(), AuthConfig, Credentials, OIDCExchange, RefreshRequest, RegisterRequest, StreamToken, TokenPair (+32 more)

### Community 24 - "CurrentUser"
Cohesion: 0.08
Nodes (21): album_page(), artist_page(), artist_tracks(), _catalog(), download_track(), list_playlists(), list_users(), _own_playlist() (+13 more)

### Community 25 - "jsQR.js"
Cohesion: 0.05
Nodes (38): binarize(), BitMatrix(), BitStream(), buildFunctionPatternMask(), computeDimension(), countBlackWhiteRun(), countBlackWhiteRunTowardsPoint(), decode() (+30 more)

### Community 26 - "accounts/routes.py"
Cohesion: 0.06
Nodes (51): _app(), custom(), disabled(), email_changed_new(), email_changed_old(), enabled(), _hello(), invite() (+43 more)

### Community 27 - "group_session.dart"
Cohesion: 0.03
Nodes (54): act, active, _apply, _attached, _attempt, _bestRtt, _closeConnection, connected (+46 more)

### Community 28 - "ConsumerWidget"
Cohesion: 0.05
Nodes (49): _SidebarPlaylists, localPlaylistsProvider, DeviceInfo, devicesProvider, alone, build, c, compact (+41 more)

### Community 29 - "sync_test.dart"
Cohesion: 0.04
Nodes (36): AppDatabase, db, main, markDone, playlist, t, db, dir (+28 more)

### Community 30 - "App"
Cohesion: 0.07
Nodes (27): App, AppStatus, Config, loginState, webServer, appDir(), defaultConfig(), normalizeRemoteDir() (+19 more)

### Community 31 - "worker/core/scanner.py"
Cohesion: 0.06
Nodes (21): _has_subtitle(), _is_generated_subtitle(), _is_on_cooldown(), _is_pt_subtitle_path(), _is_resolved(), _load_audio_verified(), _load_json_file(), _load_stats_index() (+13 more)

### Community 32 - "helpers.dart"
Cohesion: 0.07
Nodes (18): AuthException, ana, main, settings, users, field, fill, main (+10 more)

### Community 33 - "session.dart"
Cohesion: 0.04
Nodes (53): _access, _accessToken, base, build, canUseServer, checkServer, clearLogin, clearLoginError (+45 more)

### Community 34 - "device_controller.dart"
Cohesion: 0.03
Nodes (58): activeHere, activeId, _applyRemote, _attached, _attempt, base, canPlayHere, claim (+50 more)

### Community 35 - "fake_player.dart"
Cohesion: 0.04
Nodes (52): complete, _completed, completedStream, currentPosition, dispose, downloadQualities, downloadUrl, _duration (+44 more)

### Community 36 - "server_status_repository.dart"
Cohesion: 0.04
Nodes (53): artist, bytes, bytesCache, bytesPermanent, cache, calls, checkedAt, deemixAvailable (+45 more)

### Community 37 - "OIDCClient"
Cohesion: 0.09
Nodes (16): begin(), _clean_username(), client(), finish(), Identity, issue_code(), link_user(), OIDCClient (+8 more)

### Community 38 - "arr.py"
Cohesion: 0.08
Nodes (31): _delete(), find_movie_by_path(), _get(), get_movie_original_language(), get_movie_runtime(), get_series_original_language(), get_series_runtime(), _grabbed_id_by_download() (+23 more)

### Community 39 - "queue_panel.dart"
Cohesion: 0.05
Nodes (35): build, child, ContextMenuRegion, onMenu, build, child, DownloadNotices, QueueItem (+27 more)

### Community 40 - "CurrentUser"
Cohesion: 0.10
Nodes (21): notify_users(), audience(), changed(), add_many(), add_track(), _add_tracks_in_background(), apply_ops(), BulkTracks (+13 more)

### Community 41 - "asyncio"
Cohesion: 0.11
Nodes (15): check_and_heal(), install_and_verify(), latest_pypi_version(), library_version(), _main(), _run(), run_canary(), run_isrc_check() (+7 more)

### Community 42 - "package:flutter/material.dart"
Cohesion: 0.07
Nodes (11): background, main, button, main, main, main, openSheet, main (+3 more)

### Community 43 - "group_session_test.dart"
Cohesion: 0.05
Nodes (37): connect, container, devices, devicesState, engine, main, me, phone (+29 more)

### Community 44 - "Store"
Cohesion: 0.09
Nodes (25): dataBlob, FileState, State, Store, deleteSecret(), loadSecret(), saveSecret(), deleteSecret() (+17 more)

### Community 45 - "web/main.py"
Cohesion: 0.07
Nodes (23): arr_webhook(), bazarr_search(), find_poster(), get_external_subtitles(), get_image(), get_logs(), get_subtitle_status(), get_subtitles() (+15 more)

### Community 46 - "test_auth.py"
Cohesion: 0.26
Nodes (11): create_stream_token(), main(), ok(), okv(), t1_security(), t2_api(), t3_refresh(), t4_rate_limit() (+3 more)

### Community 47 - "_"
Cohesion: 0.05
Nodes (43): _, add, after, base, baseUpdatedAt, before, cover, create (+35 more)

### Community 48 - "Storages.tsx"
Cohesion: 0.06
Nodes (108): dependencies, blakejs@1.2.1, react@18.3.1, react-dom@18.3.1, react-router-dom@6.28.0, tweetnacl@1.0.3, devDependencies, @types/react@18.3.12 (+100 more)

### Community 49 - "protocol.js"
Cohesion: 0.08
Nodes (40): associatedData(), CHUNK_BYTES, chunkCount(), CODE_ALPHABET, CODE_LENGTH, CODE_PATTERN, codeFromText(), decodeMessage() (+32 more)

### Community 50 - "app"
Cohesion: 0.05
Nodes (41): container_name, depends_on, environment, image, labels, networks, restart, security_opt (+33 more)

### Community 51 - "bergakup/main.py"
Cohesion: 0.14
Nodes (7): allowed(), fetch_allowed_image(), image(), ImageError, live(), ok(), fake_fetch()

### Community 52 - "admin_users_screen.dart"
Cohesion: 0.07
Nodes (27): Account, accountRepositoryProvider, AccountCard, build, externalLinkProvider, myAccountProvider, online, read (+19 more)

### Community 53 - "json"
Cohesion: 0.09
Nodes (23): align(), rvec(), tvec(), Anchor, _combine(), _contains_neighbor(), _dot(), estimate_coarse_offset() (+15 more)

### Community 54 - "playlist_models.dart"
Cohesion: 0.05
Nodes (34): addedAt, addedBy, album, artist, asResult, canEdit, coverUrl, description (+26 more)

### Community 55 - "playlist_repository.dart"
Cohesion: 0.05
Nodes (36): PlaylistRole, added, addTrack, addTracks, ana, applyOps, batches, covers (+28 more)

### Community 56 - "play_queue.dart"
Cohesion: 0.05
Nodes (34): add, clearManual, _current, _fillUpNextAfter, _history, _item, jumpTo, loadShared (+26 more)

### Community 57 - "access_redirect_test.dart"
Cohesion: 0.17
Nodes (10): expired, home, local, logged, loggedOut, logging, login, main (+2 more)

### Community 58 - "accounts/service.py"
Cohesion: 0.10
Nodes (23): AccountError, _active_admins(), admin_managed(), can_change_password(), _check_free(), clean_email(), clean_name(), clean_password() (+15 more)

### Community 59 - "downloads/youtube.py"
Cohesion: 0.09
Nodes (17): clean_title(), _cookie_file(), download_video(), _downloaded(), duration_penalty(), find_best_candidate(), find_candidates(), _is_restricted() (+9 more)

### Community 61 - "core/bazarr.py"
Cohesion: 0.11
Nodes (19): _download_episode_subtitle(), _download_movie_subtitle(), _find_episode_by_path(), _find_movie_by_path(), _headers(), search_subtitle(), _download_episode_subtitle(), _download_movie_subtitle() (+11 more)

### Community 62 - "subprocess"
Cohesion: 0.05
Nodes (24): backfill(), measure(), measure_and_store(), measure_later(), 8.1 O que é salvo no aparelho, por faixa, 8.2 Estados, 8.3 Regra de permanência local (espelha a do servidor), 8.4 Botão de download na playlist (detalhe da playlist, na linha de ações) (+16 more)

### Community 63 - "catalog/service.py"
Cohesion: 0.11
Nodes (32): cached(), AlbumPage, ArtistPage, TrackPage, album(), artist(), artist_tracks(), dedupe() (+24 more)

### Community 64 - "Lidarr"
Cohesion: 0.11
Nodes (6): Lidarr, check_lidarr(), ensure_monitored(), finish_album(), request_lidarr(), get_track_by_id()

### Community 65 - "sync_service.dart"
Cohesion: 0.05
Nodes (33): cached, _cacheKey, formatListening, fromJson, key, online, playRecorderServiceProvider, store (+25 more)

### Community 66 - "test_integration.py"
Cohesion: 0.10
Nodes (23): Result, client(), login(), oidc(), run(), sql(), test_admin_group(), test_cancel_retry_delete() (+15 more)

### Community 67 - "internal_users.yml"
Cohesion: 0.05
Nodes (36): admin, backend_roles, description, hash, reserved, attribute1, attribute2, attribute3 (+28 more)

### Community 68 - "berga_sizes.dart"
Cohesion: 0.06
Nodes (35): BergaSizes, buttonPadding, cardMarginTop, cardPadding, cardRadius, chipGap, chipPadding, coverRadius (+27 more)

### Community 69 - "auth.py"
Cohesion: 0.11
Nodes (18): admin_user(), begin_login(), client(), create_token(), current_user(), end_session(), finish_login(), Identity (+10 more)

### Community 70 - "wazuh.dashboard"
Cohesion: 0.06
Nodes (35): external, hard, soft, networks, bergatrix-proxy, hard, soft, services (+27 more)

### Community 71 - "restic.go"
Cohesion: 0.08
Nodes (23): cmdEnroll(), cmdImportDumps(), cmdRun(), main(), requireRoot(), usage(), statOwner(), guessRepoRoot() (+15 more)

### Community 72 - "my_application.cc"
Cohesion: 0.07
Nodes (14): fl_register_plugins(), main(), first_frame_cb(), my_application_activate(), my_application_class_init(), my_application_dispose(), my_application_init(), my_application_local_command_line() (+6 more)

### Community 73 - "form_dialog.dart"
Cohesion: 0.07
Nodes (24): build, checkbox, checkboxInitial, _checked, confirmLabel, _controllers, createState, dispose (+16 more)

### Community 74 - "dart:async"
Cohesion: 0.13
Nodes (12): bytes, configureDownloadNotifications, _dio, expectedBytes, fetch, FetchResult, format, message (+4 more)

### Community 75 - "update_service.dart"
Cohesion: 0.07
Nodes (27): asset, check, current, currentVersion, _dio, download, folderFor, installsDirectly (+19 more)

### Community 76 - "app_harness.dart"
Cohesion: 0.04
Nodes (34): changes, container, fetch, initialLocation, loggedIn, _memoryDb, noDeviceTimers, noGroupTimers (+26 more)

### Community 77 - "lyrics.dart"
Cohesion: 0.05
Nodes (35): appLinkFor, isLink, linkSource, null, u, accessRedirect, canUseApp, null (+27 more)

### Community 78 - "track_row.dart"
Cohesion: 0.07
Nodes (27): build, DownloadState, DownloadStateIcon, progress, size, state, addedBy, _armed (+19 more)

### Community 79 - "account_repository.dart"
Cohesion: 0.07
Nodes (29): AccountRepository, accounts, changeMyPassword, createUser, _dio, FakeAccountRepository, _fields, _get (+21 more)

### Community 80 - "playlists.py"
Cohesion: 0.12
Nodes (12): PlaylistResult, _deezer(), _radio(), search_playlists(), FakeSpotify, item(), main(), dz() (+4 more)

### Community 81 - "search_full.dart"
Cohesion: 0.07
Nodes (28): albums, artist, artists, coverUrl, description, externalId, externalUrl, fromJson (+20 more)

### Community 82 - "playlist_sync_test.dart"
Cohesion: 0.04
Nodes (32): main, t, main, openDetail, tracks, main, p, apply (+24 more)

### Community 83 - "track_menu.dart"
Cohesion: 0.06
Nodes (28): build, _copiesOf, coverFetcherProvider, coverUrl, id, initialSize, local, localPlaylistImage (+20 more)

### Community 84 - "jobs.py"
Cohesion: 0.10
Nodes (14): add_segments(), cancel(), delete(), edit_segment(), finish(), playback_path(), public(), rebuild_transcript() (+6 more)

### Community 85 - "bouncer"
Cohesion: 0.07
Nodes (28): stripPrefix, forwardAuth, crowdsecLapiHost, crowdsecLapiKey, crowdsecMode, enabled, updateIntervalSeconds, updateMaxFailure (+20 more)

### Community 86 - "history/routes.py"
Cohesion: 0.25
Nodes (8): Play, PlayBatch, record(), StatAlbum, StatArtist, Stats, stats(), StatTrack

### Community 87 - "app_harness.dart"
Cohesion: 0.06
Nodes (20): field, main, main, goTo, main, pumpApp, calls, lyrics (+12 more)

### Community 88 - "test_oidc.py"
Cohesion: 0.18
Nodes (8): cleanup(), FakeAuthentik, login(), main(), ok(), one_time_code(), pkce(), setup()

### Community 89 - "update_prompt.dart"
Cohesion: 0.09
Nodes (26): build, checkForUpdatesManually, _checkOnStart, child, choice, createState, delay, dialog (+18 more)

### Community 90 - "web_api.py"
Cohesion: 0.22
Nodes (31): User, agent_public(), delete_agent(), delete_dataset(), delete_job(), delete_repository(), delete_storage(), discovery() (+23 more)

### Community 91 - "spotify.py"
Cohesion: 0.14
Nodes (9): _spotify(), album_result(), best_image(), client(), entity_id(), reset_client(), search(), search_full() (+1 more)

### Community 92 - "SearchResult"
Cohesion: 0.11
Nodes (18): _yt_artist_raw(), ytmusic_artist(), load(), AlbumResult, ArtistResult, FullSearch, SearchResult, _ytmusic() (+10 more)

### Community 93 - "package:dio/dio.dart"
Cohesion: 0.12
Nodes (10): AuthInterceptor, createDio, dio, onError, onRequest, _retried, apiDioProvider, dio (+2 more)

### Community 94 - "context.Context"
Cohesion: 0.08
Nodes (14): asSlice(), newAgent(), readStacksOrder(), importDumps(), sqliteBackup(), underAny(), planPath(), cmdRecover() (+6 more)

### Community 95 - "test_units.py"
Cohesion: 0.10
Nodes (10): 2. Provider e aplicação, Versão 0.4.0 — login pelo Authentik, sincronização com a nuvem e capas, check_url(), LoginOIDC, FakeOIDC, id_token(), test_check_url_accepts_public(), test_check_url_rejects_internal() (+2 more)

### Community 96 - "3. Passos 6 a 13"
Cohesion: 0.07
Nodes (27): 3. Passos 6 a 13, Correção de concorrência no download (relatada no uso), Melhoria das playlists: filas separadas e orçamento do Lidarr (servidor), Passo 10 — Histórico e métricas, Passo 11 — Offline-first e sincronização, Passo 12 — Web, Passo 13 — Release e desktop, Passo 6 — Início com métricas (+19 more)

### Community 97 - "StatelessWidget"
Cohesion: 0.09
Nodes (25): _LyricsSidePanel, _QueueSidePanel, _Sidebar, _SidebarItem, AlbumTile, ArtistCircle, build, caption (+17 more)

### Community 98 - "Segment"
Cohesion: 0.13
Nodes (14): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🚧 Notas de evolucao / pendencias (+6 more)

### Community 99 - "wazuh.indexer.yml"
Cohesion: 0.07
Nodes (27): cluster.name, cluster.routing.allocation.disk.threshold_enabled, compatibility.override_main_response_version, discovery.type, network.host, node.name, path.data, path.logs (+19 more)

### Community 100 - "dependencies"
Cohesion: 0.07
Nodes (27): dependencies, app_links, audio_service, audio_session, background_downloader, connectivity_plus, crypto, device_info_plus (+19 more)

### Community 101 - "drop"
Cohesion: 0.07
Nodes (26): external, context, build, cap_drop, container_name, cpus, labels, logging (+18 more)

### Community 102 - "environment"
Cohesion: 0.10
Nodes (27): environment, DENO_DIR, HF_HOME, HOME, HTTP_PROXY, HTTPS_PROXY, NO_PROXY, NVIDIA_DRIVER_CAPABILITIES (+19 more)

### Community 103 - "account.dart"
Cohesion: 0.08
Nodes (25): accountUrl, adminManagedByAuthentik, authentikAdminUrl, canChangePassword, disabled, email, fromJson, hasPassword (+17 more)

### Community 104 - "auth.dart"
Cohesion: 0.08
Nodes (23): accessToken, address, AuthError, AuthTokens, error, expiresIn, fromJson, id (+15 more)

### Community 105 - "ops.py"
Cohesion: 0.22
Nodes (16): _add(), apply_batch(), _apply_one(), BatchResult, _cover(), _create(), _delete(), _Fail (+8 more)

### Community 106 - "List"
Cohesion: 0.09
Nodes (19): albums, artist, artistId, ArtistPage, externalId, followers, followersText, fromJson (+11 more)

### Community 107 - "audio_engine.dart"
Cohesion: 0.10
Nodes (18): AudioEngine, completedStream, dispose, durationStream, engine, errorStream, JustAudioEngine, pause (+10 more)

### Community 108 - "networks"
Cohesion: 0.08
Nodes (23): name, internal, name, internal, name, name, internal, name (+15 more)

### Community 109 - "catalog_repository.dart"
Cohesion: 0.13
Nodes (13): album, artist, artistTracks, CatalogRepository, catalogRepositoryProvider, _dio, failPageAt, FakeCatalogRepository (+5 more)

### Community 110 - "lidarr.py"
Cohesion: 0.13
Nodes (10): local_path(), names_match(), normalize(), pick_album(), pick_medley(), pick_parts(), pick_track(), _plain() (+2 more)

### Community 111 - "key_value_store.dart"
Cohesion: 0.20
Nodes (8): delete, KeyValueStore, MemoryKeyValueStore, read, SecureKeyValueStore, _storage, values, write

### Community 112 - "../theme/berga_colors.dart"
Cohesion: 0.08
Nodes (22): c, showChoiceDialog, actionLabel, build, message, OfflineBanner, onAction, build (+14 more)

### Community 113 - "Worker"
Cohesion: 0.17
Nodes (5): main(), Worker, emit(), scenario(), scenario()

### Community 114 - "utils.cpp"
Cohesion: 0.12
Nodes (4): wWinMain(), CreateAndAttachConsole(), GetCommandLineArguments(), Utf8FromUtf16()

### Community 115 - "traefik"
Cohesion: 0.10
Nodes (22): external, aliases, external, external, name, networks, bergatrix-drop, bergatrix-office (+14 more)

### Community 116 - "lyrics/service.py"
Cohesion: 0.22
Nodes (8): clean_title(), fetch_lrclib(), LyricLine, Lyrics, lyrics_for(), parse_lrc(), _pick(), _to_lyrics()

### Community 117 - "traefik — Reverse proxy / ingress central do homelab Bergatrix (Traefik v3.6.2) com TLS wildcard automatico via Let's Encrypt e DNS-01 challenge no deSEC."
Cohesion: 0.18
Nodes (12): auth(), 🗂️ Estrutura de codigo, 🚧 Notas de evolucao / pendencias, Decisões em aberto, Decisões tomadas (outubro de 2026), Mapa por serviço, O que falta, O que precisa existir no Authentik (+4 more)

### Community 118 - "auth_interceptor_test.dart"
Cohesion: 0.11
Nodes (10): auth, container, dioWith, main, server, store, main, of (+2 more)

### Community 119 - "fake_auth_repository.dart"
Cohesion: 0.09
Nodes (22): AuthOptions, authOptions, _checkServer, _counter, delay, discovered, discoverServer, exchangeOidc (+14 more)

### Community 120 - "playback_repository.dart"
Cohesion: 0.09
Nodes (22): _dio, downloadUrl, fromJson, label, loudness, lufs, peak, prepare (+14 more)

### Community 121 - "qrcode.mjs"
Cohesion: 0.11
Nodes (14): base64EncodeOutputStream(), _this, byteArrayOutputStream(), createDataURL(), gifImage(), _this, QRErrorCorrectionLevel, qrKanji() (+6 more)

### Community 122 - "Settings"
Cohesion: 0.12
Nodes (3): _origin(), Settings, Settings

### Community 123 - "server/routes.py"
Cohesion: 0.10
Nodes (22): get_redis(), pop_error(), active_count(), _note_deemix_failure(), enabled(), read_health(), _deemix(), DeemixFailure (+14 more)

### Community 124 - "devices/routes.py"
Cohesion: 0.14
Nodes (19): lifespan(), watchdog(), admin_user(), current_user(), stream_user(), decode_token(), TokenError, _broadcast() (+11 more)

### Community 125 - "stats.dart"
Cohesion: 0.09
Nodes (19): artist, coverUrl, distinctTracksMonth, fromJson, imageUrl, isEmpty, month, name (+11 more)

### Community 126 - "player_controller_test.dart"
Cohesion: 0.09
Nodes (20): HttpPlaybackRepository, PlaybackRepository, ConnectivityNetworkCheck, NetworkCheck, _AlwaysWifi, FakePlaybackRepository, FakeNetwork, changes (+12 more)

### Community 127 - "playlist_screen.dart"
Cohesion: 0.05
Nodes (37): trackDownloadStatesProvider, playlistSortProvider, build, build, tracks, build, _changePhoto, _ChangesBadge (+29 more)

### Community 128 - "app_release.dart"
Cohesion: 0.08
Nodes (21): androidAsset, AppVersion, assets, compareTo, fromGitHub, hashCode, latestOf, linuxAsset (+13 more)

### Community 129 - "variants.py"
Cohesion: 0.10
Nodes (13): _file_for(), AudioInfo, _int(), parse_ffprobe(), probe(), cleanup(), delivered(), Delivery (+5 more)

### Community 130 - "00-visao-geral.md"
Cohesion: 0.10
Nodes (9): Como o dono deve usar o Projeto, 🤖 Instruções do Projeto Claude — Bergatrix, Persona / System prompt (colar nas instruções do Projeto), Prompts iniciais sugeridos, Resumo de contexto (denso, para o Claude já saber o essencial), Automação, Bergalink, Estado atual (+1 more)

### Community 131 - "📐 Bergatrix — Convenções & Padrões de Desenvolvimento"
Cohesion: 0.18
Nodes (11): 1. Organização em camadas, 2. Estrutura padrão de uma stack, 3. Nomenclatura, 4. Padrão de roteamento (labels Traefik), 5. Padrão de SSO (Authentik), 6. Gestão de segredos, 7. Versionamento (git), 8. Persistência (+3 more)

### Community 132 - "test_quality.py"
Cohesion: 0.09
Nodes (16): delete_expired_refresh_tokens(), clear_failed(), clear_stale(), download_best(), download_track(), emit_download(), _get_queue(), _literal() (+8 more)

### Community 133 - "app_text_field.dart"
Cohesion: 0.10
Nodes (16): AppTextField, autofillHints, autofocus, build, controller, _field, hint, keyboardType (+8 more)

### Community 134 - "Processor"
Cohesion: 0.10
Nodes (4): Processor, MediaEventHandler, Scanner, StatsManager

### Community 135 - "agent_api.py"
Cohesion: 0.17
Nodes (21): current_agent(), enroll(), Enroll, _existing(), get_plan(), heartbeat(), Heartbeat, LogLine (+13 more)

### Community 136 - "login.go"
Cohesion: 0.10
Nodes (21): newClient(), checkSource(), jobStatePath(), loadJobStates(), ping(), short(), updateJobState(), Client (+13 more)

### Community 137 - "DataClass"
Cohesion: 0.17
Nodes (18): LocalTrackResult, AppStateCompanion, AppStateEntry, DataClass, LocalCollaborator, LocalCollaboratorsCompanion, LocalPlaylistItem, LocalPlaylistItemsCompanion (+10 more)

### Community 138 - "history_repository.dart"
Cohesion: 0.11
Nodes (18): ListeningStats, clientId, _dio, failing, FakeHistoryRepository, fromJson, HistoryRepository, HttpHistoryRepository (+10 more)

### Community 139 - "sync_notices.dart"
Cohesion: 0.05
Nodes (42): AppToast, build, colors, createState, _current, dispose, _fade, initState (+34 more)

### Community 140 - "lyrics_repository.dart"
Cohesion: 0.11
Nodes (19): calls, _dio, FakeLyricsRepository, found, fromJson, HttpLyricsRepository, isSynced, LyricLine (+11 more)

### Community 141 - "oidc_launcher_io.dart"
Cohesion: 0.11
Nodes (16): _AppLinkLauncher, cancel, clearInitialCode, _codeOf, createOidcLauncher, initialCode, _links, _LoopbackLauncher (+8 more)

### Community 142 - "FlutterWindow"
Cohesion: 0.11
Nodes (4): FlutterWindow, flutter_controller_, FlutterWindow::FlutterWindow(), project_

### Community 143 - "win32_window.cpp"
Cohesion: 0.15
Nodes (8): EnableNonClientDpiScaling, Scale(), Win32Window::Win32Window(), WindowClassRegistrar, class_registered_, WindowClassRegistrar::GetWindowClass(), instance_, WindowClassRegistrar::UnregisterWindowClass()

### Community 144 - "homeassistant"
Cohesion: 0.10
Nodes (19): external, interval, retries, start_period, test, timeout, container_name, environment (+11 more)

### Community 145 - "dataclasses"
Cohesion: 0.11
Nodes (9): available(), ModelSpec, Engine, OutOfMemory, ensure(), is_ready(), model_dir(), ModelError (+1 more)

### Community 146 - "environment"
Cohesion: 0.19
Nodes (20): environment, environment, environment, APACHE_DISABLE_REWRITE_IP, NEXTCLOUD_ADMIN_PASSWORD, NEXTCLOUD_ADMIN_USER, NEXTCLOUD_DATA_DIR, NEXTCLOUD_TRUSTED_DOMAINS (+12 more)

### Community 147 - "re"
Cohesion: 0.16
Nodes (14): parse_ts(), shift_ts(), align_by_ordinal_map(), alignment_confidence(), alignment_metrics(), build_ordinal_time_map(), Cue, format_timestamp() (+6 more)

### Community 149 - "make_icons.py"
Cohesion: 0.25
Nodes (8): android(), desktop(), full_icon(), gradient(), hsl(), letter(), rounded(), save()

### Community 150 - "authentik — Provedor de identidade (IdP) e SSO self-hosted que centraliza autenticacao e fornece ForwardAuth ao Traefik"
Cohesion: 0.11
Nodes (18): worker(), Serviços, 3. Identidade & SSO — Authentik, authentik — Provedor de identidade (IdP) e SSO self-hosted que centraliza autenticacao e fornece ForwardAuth ao Traefik, 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo (+10 more)

### Community 151 - "app.go"
Cohesion: 0.13
Nodes (14): projectMap, Settings, copyFileMissing(), copyMissing(), isSyncedSettings(), migrateClaudeDir(), baseName(), encodeProjectDir() (+6 more)

### Community 152 - "cover.dart"
Cohesion: 0.11
Nodes (17): build, circle, Cover, gradientFor, hueFor, image, initialOf, initialSize (+9 more)

### Community 153 - "search_result.dart"
Cohesion: 0.11
Nodes (15): album, albumId, artist, artistId, coverUrl, durationSeconds, externalId, fromJson (+7 more)

### Community 154 - "search_repository.dart"
Cohesion: 0.12
Nodes (15): apiValue, calls, _dio, FakeSearchRepository, HttpSearchRepository, label, resolve, resolveCalls (+7 more)

### Community 155 - "resolve.py"
Cohesion: 0.19
Nodes (12): clean_description(), _follow_redirects(), LinkNotFound, parse_link(), ParsedLink, resolve(), _resolve_deezer(), get() (+4 more)

### Community 156 - "crowdsec"
Cohesion: 0.12
Nodes (16): external, name, container_name, environment, image, networks, restart, volumes (+8 more)

### Community 157 - "test_quality.py"
Cohesion: 0.10
Nodes (3): search_interval(), FakeLidarr, FakePool

### Community 158 - "routes.dart"
Cohesion: 0.07
Nodes (23): adminUsers, albumOf, AppRoutes, artistOf, gallery, home, importedLink, library (+15 more)

### Community 159 - "docker.go"
Cohesion: 0.13
Nodes (17): docker(), listContainers(), newQuiesce(), orderedStacks(), 1. Authentik, 2. DNS e stack, 3. Agente (no host), 4. Configuração inicial (na interface) (+9 more)

### Community 160 - "track_actions_sheet.dart"
Cohesion: 0.06
Nodes (15): artist, build, cover, disabledMessage, id, _item, onAddToPlaylist, onAddToQueue (+7 more)

### Community 161 - "@JsonSerializable"
Cohesion: 0.12
Nodes (15): AuthUser, TokenResponse, AlbumPage, TrackPage, Person, PlaylistDetail, PlaylistMember, PlaylistTrack (+7 more)

### Community 162 - "auth_repository.dart"
Cohesion: 0.12
Nodes (14): AuthRepository, bypassPrefix, discoverServer, exchangeOidc, forgotPassword, login, logout, me (+6 more)

### Community 163 - "text_input_dialog.dart"
Cohesion: 0.08
Nodes (23): GalleryScreen, _GalleryScreenState, _ToastView, _ToastViewState, _FormDialog, _FormDialogState, build, confirmLabel (+15 more)

### Community 164 - "bergakup/auth.py"
Cohesion: 0.16
Nodes (10): begin_login(), client(), current_user(), finish_login(), Identity, LoginError, OIDCClient, s256() (+2 more)

### Community 165 - "fake_update.dart"
Cohesion: 0.10
Nodes (18): AppRelease, GitHubUpdateRepository, UpdateRepository, current, currentVersion, download, downloads, fail (+10 more)

### Community 166 - "qrcode"
Cohesion: 0.15
Nodes (6): renderQr(), base64DecodeInputStream(), _this, qrcode(), image(), jsQR

### Community 167 - "Subir"
Cohesion: 0.12
Nodes (17): 1. Export `userdata` no OMV, 2. Pastas, 3. Traefik: timeout de upload, 4. Authentik, 5. Subir a stack, 6. Primeiro acesso: crie o admin na hora, 7. Configurar o Immich, 8. Vincular, testar e desligar a senha (+9 more)

### Community 169 - "search_screen.dart"
Cohesion: 0.07
Nodes (33): searchHistoryProvider, build, localSearchProvider, playlistSearchProvider, resolvedLinkProvider, searchResultsProvider, build, _controller (+25 more)

### Community 170 - "berga_text.dart"
Cohesion: 0.12
Nodes (14): _base, BergaText, body, button, chip, chipActive, fontFamily, h1 (+6 more)

### Community 171 - "buttons.dart"
Cohesion: 0.12
Nodes (14): active, AppChip, build, expanded, icon, iconColor, label, leading (+6 more)

### Community 172 - ".addData"
Cohesion: 0.12
Nodes (6): qr8BitByte(), _this, qrAlphaNum(), _this, qrNumber(), _this

### Community 174 - "ollama"
Cohesion: 0.12
Nodes (15): external, resources, networks, bergatrix-ai, container_name, deploy, environment, image (+7 more)

### Community 175 - "worker"
Cohesion: 0.12
Nodes (16): resources, devices, reservations, worker, cap_drop, container_name, deploy, mem_limit (+8 more)

### Community 176 - "opensearch_dashboards.yml"
Cohesion: 0.12
Nodes (15): opensearch.hosts, opensearch.requestHeadersWhitelist, opensearch_security.cookie.ttl, opensearch_security.multitenancy.enabled, opensearch_security.readonly_mode.roles, opensearch_security.session.keepalive, opensearch_security.session.ttl, opensearch.ssl.certificateAuthorities (+7 more)

### Community 177 - "Modelos de Labels do Traefik — Bergatrix"
Cohesion: 0.17
Nodes (12): Bloquear navegador no bypass, ⚠️ Bugs que já nos morderam, Checklist ao adicionar um serviço novo, 📌 Dispositivos de confiança, Modelo A — Público, só navegador, Modelo B — Público, com app/API própria, Modelo C2 — Rede local inteira, Modelo C — Só dispositivos de confiança (+4 more)

### Community 178 - "homeassistant — Plataforma de automação residencial (Home Assistant Core em container) exposta via Traefik no Modelo B (Authentik de fora, direto para dispositivos de confiança, bypass para o app Companion)"
Cohesion: 0.12
Nodes (16): 🧩 Dependências internas (Bergatrix), 🌐 Domínios / Roteamento, 🗂️ Estrutura de código, 🎯 Finalidade, 🛡️ Gestão de segredos, homeassistant — Plataforma de automação residencial (Home Assistant Core em container) exposta via Traefik no Modelo B (Authentik de fora, direto para dispositivos de confiança, bypass para o app Companion), 🔗 Integrações externas, 🗄️ Modelo de dados (+8 more)

### Community 179 - "jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC"
Cohesion: 0.11
Nodes (14): JobProcessor, 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API (legendarr-web), 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas (+6 more)

### Community 180 - "n8n — Plataforma de automação de workflows self-hosted, com imagem customizada (Python/yt-dlp) e execução de comandos habilitada"
Cohesion: 0.13
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🗄️ Modelo de dados (+7 more)

### Community 181 - "networks — Runbook de bootstrap que cria as duas redes Docker externas compartilhadas (bergatrix-proxy e bergatrix-backend) das quais todo o homelab depende"
Cohesion: 0.12
Nodes (16): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🚨 Infraestrutura critica: DNS do servidor para o cert wildcard, 🔗 Integracoes externas (+8 more)

### Community 182 - "rss — Leitor de feeds RSS auto-hospedado (FreshRSS) com PostgreSQL dedicado, exposto via Traefik em freshrss.${DOMAIN}"
Cohesion: 0.13
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🗄️ Modelo de dados (+7 more)

### Community 183 - "Segment"
Cohesion: 0.26
Nodes (11): paragraphs(), Segment, timestamp(), to_json(), to_srt(), to_text(), to_vtt(), segments() (+3 more)

### Community 184 - "artist_screen.dart"
Cohesion: 0.06
Nodes (38): ApiException, build, _albums, _allTracks, ArtistScreen, _ArtistScreenState, ArtistTab, _BackLink (+30 more)

### Community 185 - "local_playlists.dart"
Cohesion: 0.04
Nodes (49): changes, current, SafeConnectivity, app, AppPlatform, desktop, detect, isApp (+41 more)

### Community 186 - "http_auth_repository.dart"
Cohesion: 0.13
Nodes (12): _dio, discoverServer, exchangeOidc, forgotPassword, login, _loginError, logout, me (+4 more)

### Community 187 - "media_notification.dart"
Cohesion: 0.13
Nodes (11): BergaAudioHandler, idle, initMediaNotification, pause, play, seek, showState, showTrack (+3 more)

### Community 188 - "Armazenamento"
Cohesion: 0.13
Nodes (15): `APPDATA_PATH` e `CACHE_PATH`: uma pasta por stack, Armazenamento, As quatro raízes, Backup, Como decidir onde um volume vai, Disco local (HD de 1 TB), Layout das pastas, Mapa atual por stack (+7 more)

### Community 189 - "berga-news — Agregador de RSS auto-hospedado que agrupa artigos por tópico com IA e gera digests resumidos em português"
Cohesion: 0.12
Nodes (15): berga-news — Agregador de RSS auto-hospedado que agrupa artigos por tópico com IA e gera digests resumidos em português, 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas (+7 more)

### Community 190 - "bitwarden — Gerenciador de senhas auto-hospedado (Vaultwarden) exposto via Traefik com o wildcard TLS compartilhado *.daberga.com"
Cohesion: 0.13
Nodes (15): bitwarden — Gerenciador de senhas auto-hospedado (Vaultwarden) exposto via Traefik com o wildcard TLS compartilhado *.daberga.com, 🧩 Dependências internas (Bergatrix), 🌐 Domínios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de código, 🎯 Finalidade, 🛡️ Gestão de segredos, 🔗 Integrações externas (+7 more)

### Community 191 - "cloudbeaver — Console web de administracao de banco de dados (CloudBeaver) para o Postgres global do homelab, protegido por Tailscale + Authentik SSO via Traefik"
Cohesion: 0.13
Nodes (15): cloudbeaver — Console web de administracao de banco de dados (CloudBeaver) para o Postgres global do homelab, protegido por Tailscale + Authentik SSO via Traefik, 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas (+7 more)

### Community 192 - "drop — Transferência segura e efêmera de mensagens/segredos entre dois dispositivos, com criptografia ponta-a-ponta no navegador e servidor como relay zero-knowledge."
Cohesion: 0.13
Nodes (15): 🧩 Dependências internas (Bergatrix), 🌐 Domínios / Roteamento, drop — Transferência segura e efêmera de mensagens/segredos entre dois dispositivos, com criptografia ponta-a-ponta no navegador e servidor como relay zero-knowledge., 🔌 Endpoints / API, 🗂️ Estrutura de código, 🎯 Finalidade, 🛡️ Gestão de segredos, 🔗 Integrações externas (+7 more)

### Community 193 - "litellm — Proxy/gateway LiteLLM auto-hospedado que expoe uma API unica compativel com OpenAI, roteando para modelos da OpenRouter (free e pagos), com um sidecar que sincroniza o catalogo e gerencia virtual keys"
Cohesion: 0.13
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, litellm — Proxy/gateway LiteLLM auto-hospedado que expoe uma API unica compativel com OpenAI, roteando para modelos da OpenRouter (free e pagos), com um sidecar que sincroniza o catalogo e gerencia virtual keys (+7 more)

### Community 194 - "openuiweb — Open WebUI (interface estilo ChatGPT) auto-hospedada como "Bergatrix AI", conectada ao LiteLLM e a um Ollama local com GPU NVIDIA, exposta em chat.${DOMAIN} mas restrita a LAN"
Cohesion: 0.13
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🗄️ Modelo de dados (+7 more)

### Community 195 - "transcriptor — Serviço de transcrição de áudio/vídeo com Whisper (faster-whisper) acelerado por GPU, com UI web, fila e API REST v1"
Cohesion: 0.12
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🗄️ Modelo de dados (+7 more)

### Community 196 - "wazuh — Plataforma SIEM/XDR (Wazuh 4.7.2) auto-hospedada para monitoramento de segurança, detecção de intrusão e conformidade"
Cohesion: 0.13
Nodes (15): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, 🔗 Integracoes externas, 🗄️ Modelo de dados (+7 more)

### Community 197 - "vaultwarden"
Cohesion: 0.14
Nodes (13): external, name, networks, bergatrix-proxy, services, vaultwarden, container_name, environment (+5 more)

### Community 198 - "test_catalog.py"
Cohesion: 0.16
Nodes (9): album_result(), DeezerError, get(), search_full(), track_from(), dz_track(), fake_get(), fake_search() (+1 more)

### Community 199 - "dumps.go"
Cohesion: 0.27
Nodes (10): copyFile(), discoverDumps(), dumpsSummary(), importOne(), pgCommand(), pgDump(), pgIdentity(), waitHealthy() (+2 more)

### Community 200 - "optimizer"
Cohesion: 0.14
Nodes (14): resources, deploy, deploy, build, container_name, deploy, dns, environment (+6 more)

### Community 201 - "Nextcloud"
Cohesion: 0.14
Nodes (14): 1. Authentik, 2. Pastas no servidor, 3. Primeira subida, 4. Teste do NFS (antes de qualquer arquivo), 5. Configuração inicial (`occ`), 6. Login pelo Authentik (OIDC), 7. Fechar o login local, 8. Clientes (+6 more)

### Community 202 - "bergastream — Streaming de música multiusuário, auto-hospedado (substituto do Spotify)"
Cohesion: 0.14
Nodes (13): bergastream — Streaming de música multiusuário, auto-hospedado (substituto do Spotify), 🧩 Dependências internas (Bergatrix), 🌐 Domínios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de código, 🎯 Finalidade, 🛡️ Gestão de segredos, 🔗 Integrações externas (+5 more)

### Community 203 - "ghostmap — Geocodificador privacy-first via Whoogle + Nominatim, com UI/PWA Flask que gera links geo:/OpenStreetMap"
Cohesion: 0.13
Nodes (14): 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🗂️ Estrutura de codigo, 🎯 Finalidade, 🛡️ Gestao de segredos, ghostmap — Geocodificador privacy-first via Whoogle + Nominatim, com UI/PWA Flask que gera links geo:/OpenStreetMap, 🔗 Integracoes externas (+6 more)

### Community 204 - "jobs"
Cohesion: 0.14
Nodes (13): env, FLUTTER_VERSION, jobs, linux, needs, runs-on, timeout-minutes, name (+5 more)

### Community 205 - "api"
Cohesion: 0.29
Nodes (7): build, container_name, env_file, networks, restart, volumes, api

### Community 206 - "immich-machine-learning"
Cohesion: 0.15
Nodes (13): resources, cap_drop, container_name, deploy, image, networks, restart, security_opt (+5 more)

### Community 207 - "collabora"
Cohesion: 0.15
Nodes (13): cap_add, container_name, environment, image, labels, networks, restart, aliasgroup1 (+5 more)

### Community 208 - "egress"
Cohesion: 0.17
Nodes (13): build, context, dockerfile, build, cap_drop, container_name, mem_limit, networks (+5 more)

### Community 209 - "Padrão de stacks"
Cohesion: 0.15
Nodes (13): Acesso (Traefik e autenticação), Bloco base, Checklist de stack nova, Containers, Dívidas conhecidas, Estrutura do repositório, No compose, Padrão de stacks (+5 more)

### Community 210 - "cloudbeaver"
Cohesion: 0.17
Nodes (11): external, container_name, image, labels, networks, restart, volumes, networks (+3 more)

### Community 211 - "logging"
Cohesion: 0.12
Nodes (5): pick_release_group(), studio_album(), main(), main(), wait_for_bazarr()

### Community 212 - "services"
Cohesion: 0.17
Nodes (11): name, internal, name, external, external, networks, bergastream-egress, bergastream-internal (+3 more)

### Community 213 - "deemix"
Cohesion: 0.18
Nodes (12): container_name, environment, image, networks, restart, volumes, ARL, PGID (+4 more)

### Community 214 - "bool get"
Cohesion: 0.17
Nodes (10): ApiErrorKind, detail, fromDio, isHostNotFound, isTransient, kind, message, serverMessage (+2 more)

### Community 215 - "Migração para o novo armazenamento"
Cohesion: 0.14
Nodes (10): 1. Criar as raízes, 2. Mover os dados de cada stack, 3. Atualizar os `.env`, 4. Pontos de atenção, 5. Conferir depois de subir, Antes de começar, Dois cenários para o HD de 1 TB, Mapa antigo → novo (+2 more)

### Community 216 - "Win32Window"
Cohesion: 0.21
Nodes (4): Win32Window, child_content_, quit_on_close_, window_handle_

### Community 217 - "Drop"
Cohesion: 0.15
Nodes (10): Bibliotecas de terceiros, Atualizar dependências, Como funciona, Drop, Inverter, Limites, Segurança, Subir (+2 more)

### Community 218 - "download_manager_test.dart"
Cohesion: 0.07
Nodes (28): c, change, _changes, concurrent, db, dir, failures, fetch (+20 more)

### Community 219 - "migrate"
Cohesion: 0.17
Nodes (12): condition, db, DATABASE_URL, command, container_name, depends_on, environment, image (+4 more)

### Community 220 - "db"
Cohesion: 0.14
Nodes (14): container_name, healthcheck, image, labels, networks, restart, security_opt, volumes (+6 more)

### Community 221 - "with"
Cohesion: 0.17
Nodes (12): with, body, cache, distribution, fail_on_unmatched_files, files, flutter-version, java-version (+4 more)

### Community 222 - "postgresql"
Cohesion: 0.17
Nodes (12): POSTGRES_DB, POSTGRES_PASSWORD, POSTGRES_USER, container_name, env_file, environment, image, labels (+4 more)

### Community 223 - "migrate"
Cohesion: 0.18
Nodes (11): condition, db, PGSSLMODE, command, container_name, depends_on, environment, image (+3 more)

### Community 224 - "Bergastream — usuários"
Cohesion: 0.18
Nodes (11): Bergastream — usuários, Criar, Criar sem terminal interativo (script), Dados pessoais (LGPD), E-mail (SMTP), Ligação com o Authentik, Listar, Login bloqueado (+3 more)

### Community 225 - "renderRole"
Cohesion: 0.18
Nodes (22): applySwap(), closeMessage(), endSession(), enqueue(), expireSession(), goHome(), onControl(), onReconnecting() (+14 more)

### Community 226 - "worker.py"
Cohesion: 0.14
Nodes (14): dequeue(), enqueue(), get_job(), mark_active(), mark_done(), pending_job(), set_job_status(), track_job_key() (+6 more)

### Community 227 - "web/manifest.json"
Cohesion: 0.18
Nodes (10): background_color, description, display, icons, name, orientation, prefer_related_applications, short_name (+2 more)

### Community 228 - "1. Backend (FastAPI + PostgreSQL + Redis)"
Cohesion: 0.18
Nodes (11): 1.10 Correções no download (feitas no Passo 5), 1.11 Usuário de teste local, 1.1 Infraestrutura, 1.2 Estrutura do Backend, 1.3 Endpoints da API, 1.5 Fluxo de Resolução (anti-duplicação cross-provider), 1.6 Fila Redis (3 prioridades), 1.7 Ciclo de Vida de Permanência (+3 more)

### Community 229 - "assets/manifest.json"
Cohesion: 0.18
Nodes (10): background_color, description, display, icons, lang, name, scope, short_name (+2 more)

### Community 230 - "services"
Cohesion: 0.18
Nodes (10): external, external, external, external, networks, bergatrix-ai, bergatrix-ldap, bergatrix-media (+2 more)

### Community 231 - "audit"
Cohesion: 0.13
Nodes (28): publish(), agent_of(), AgentSettings, audit(), check_path(), check_sealed(), CommandIn, create_command() (+20 more)

### Community 232 - "api"
Cohesion: 0.18
Nodes (11): cap_drop, container_name, labels, mem_limit, networks, read_only, restart, security_opt (+3 more)

### Community 233 - "nodes"
Cohesion: 0.18
Nodes (10): ip, name, ip, name, nodes, dashboard, indexer, server (+2 more)

### Community 234 - "Redes Docker"
Cohesion: 0.18
Nodes (11): As redes, Collabora (editor de documentos do Nextcloud), Compartilhadas (entre stacks), Conferir, Criar uma rede compartilhada nova, Da própria stack, Migração para a `bergatrix-office` (uma vez, out/2026), Migração para estas redes (uma vez, out/2026) (+3 more)

### Community 235 - "🛡️ Bergatrix — Arquitetura de Rede & Segurança"
Cohesion: 0.17
Nodes (12): 1. Topologia de rede (hub-and-spoke), 2. Traefik (ingress / TLS), 4. Segredos — Vaultwarden, 5. SIEM — Wazuh, 6. Admin de banco — CloudBeaver, 7. Estratégia de segredos, 8. Exposições conhecidas (rotacionar) 🔴, 9. Recomendações de hardening (priorizadas) (+4 more)

### Community 236 - "ldap"
Cohesion: 0.20
Nodes (10): AUTHENTIK_HOST, AUTHENTIK_INSECURE, AUTHENTIK_TOKEN, container_name, depends_on, environment, image, networks (+2 more)

### Community 237 - "server"
Cohesion: 0.20
Nodes (10): command, container_name, depends_on, env_file, image, labels, networks, restart (+2 more)

### Community 238 - "Plan"
Cohesion: 0.08
Nodes (13): sendSMTP(), decodeKey(), generateKeys(), newOpener(), Dataset, HostCfg, Job, Opener (+5 more)

### Community 239 - "db"
Cohesion: 0.18
Nodes (11): container_name, environment, image, labels, networks, restart, volumes, POSTGRES_DB (+3 more)

### Community 240 - "Bergastream — subir no servidor"
Cohesion: 0.20
Nodes (10): 0. Antes de começar, 1. Código e pastas, 2. `.env`, 3. Subir, 4. Usuários, 5. Testar, 6. Atualizar o servidor depois, 7. Qualidade: Deezer Premium e FLAC pela Usenet (Lidarr) (+2 more)

### Community 241 - "format.dart"
Cohesion: 0.20
Nodes (9): compactCount, formatBytes, formatDuration, hours, minutes, one, seconds, total (+1 more)

### Community 242 - "@DataClassName"
Cohesion: 0.36
Nodes (8): AppState, LocalCollaborators, LocalPlaylistItems, LocalPlaylists, LocalTracks, PendingPlaylistOps, PendingPlays, SyncNotices

### Community 245 - "services"
Cohesion: 0.20
Nodes (9): external, name, internal, name, networks, bergatrix-proxy, immich-egress, immich-internal (+1 more)

### Community 246 - "database"
Cohesion: 0.18
Nodes (11): cap_drop, container_name, image, labels, networks, restart, security_opt, shm_size (+3 more)

### Community 247 - "immich-server"
Cohesion: 0.20
Nodes (10): cap_drop, container_name, image, labels, networks, restart, security_opt, user (+2 more)

### Community 248 - "catalogo"
Cohesion: 0.20
Nodes (10): container_name, dns, environment, image, init, labels, networks, restart (+2 more)

### Community 249 - "jellyfin"
Cohesion: 0.20
Nodes (10): container_name, dns, environment, image, labels, networks, restart, security_opt (+2 more)

### Community 250 - "networks"
Cohesion: 0.20
Nodes (10): external, external, networks, bergatrix-office, bergatrix-proxy, nextcloud-egress, nextcloud-internal, name (+2 more)

### Community 251 - "services"
Cohesion: 0.20
Nodes (9): external, networks, bergatrix-proxy, transcriptor-egress, transcriptor-internal, services, name, internal (+1 more)

### Community 252 - "x-env"
Cohesion: 0.20
Nodes (10): x-env, TRANSCRIPTOR_AUDIO_DAYS, TRANSCRIPTOR_DATABASE_URL, TRANSCRIPTOR_DEFAULT_MODEL, TRANSCRIPTOR_MAX_DURATION_MINUTES, TRANSCRIPTOR_MAX_UPLOAD_MB, TRANSCRIPTOR_MODELS, TRANSCRIPTOR_PUBLIC_URL (+2 more)

### Community 253 - "Transcriptor"
Cohesion: 0.20
Nodes (10): 1. No Authentik, 2. No servidor, API, Armazenamento, Modelos, Segurança, Subir, Testes (+2 more)

### Community 254 - "Padrão de acesso (Traefik + Authentik)"
Cohesion: 0.20
Nodes (10): A regra, Caminho técnico (só quando necessário), Conferir uma rota, Forward-auth, Forward-auth: uma aplicação para o domínio inteiro, Labels por padrão, No Authentik, para cada app, OIDC ou LDAP (+2 more)

### Community 255 - "steps"
Cohesion: 0.27
Nodes (10): steps, steps, steps, id, name, run, timeout-minutes, uses (+2 more)

### Community 256 - "dashboard"
Cohesion: 0.22
Nodes (8): entryPoints, middlewares, rule, service, tls, http, routers, dashboard

### Community 257 - "traefik.yml"
Cohesion: 0.22
Nodes (8): accessLog, filePath, format, api, dashboard, log, format, level

### Community 258 - "dnsChallenge"
Cohesion: 0.22
Nodes (9): dnsChallenge, storage, certificatesResolvers, letsencrypt, propagation, provider, resolvers, acme (+1 more)

### Community 259 - "docker"
Cohesion: 0.22
Nodes (8): endpoint, exposedByDefault, network, directory, watch, providers, docker, file

### Community 260 - "services"
Cohesion: 0.22
Nodes (8): driver, external, external, networks, authentik-internal, bergatrix-ldap, bergatrix-proxy, services

### Community 261 - "worker"
Cohesion: 0.22
Nodes (9): worker, command, container_name, depends_on, env_file, image, networks, restart (+1 more)

### Community 262 - "healthcheck"
Cohesion: 0.53
Nodes (9): healthcheck, healthcheck, healthcheck, interval, retries, start_period, test, timeout (+1 more)

### Community 263 - "GroupSessionController"
Cohesion: 0.22
Nodes (9): sessionRepositoryProvider, sessionSocketFactoryProvider, SharedPlayback, build, _connect, groupClockProvider, GroupSessionController, GroupState (+1 more)

### Community 264 - "dev_dependencies"
Cohesion: 0.22
Nodes (9): dev_dependencies, build_runner, drift_dev, flutter_lints, flutter_test, integration_test, json_serializable, sdk (+1 more)

### Community 266 - "environment"
Cohesion: 0.14
Nodes (15): environment, DB_DATABASE_NAME, DB_PASSWORD, DB_STORAGE_TYPE, DB_USERNAME, IMMICH_LOG_LEVEL, NVIDIA_DRIVER_CAPABILITIES, NVIDIA_VISIBLE_DEVICES (+7 more)

### Community 267 - "redis"
Cohesion: 0.22
Nodes (9): cap_drop, container_name, image, networks, restart, security_opt, user, volumes (+1 more)

### Community 268 - "bazarr"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, labels, networks, restart, volumes (+1 more)

### Community 269 - "legendarr-web"
Cohesion: 0.22
Nodes (9): build, container_name, dns, environment, labels, networks, restart, volumes (+1 more)

### Community 270 - "prowlarr"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, labels, networks, restart, volumes (+1 more)

### Community 271 - "qbittorrent"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, labels, networks, restart, volumes (+1 more)

### Community 272 - "radarr"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, labels, networks, restart, volumes (+1 more)

### Community 273 - "recyclarr"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, networks, restart, user, volumes (+1 more)

### Community 274 - "sabnzbd"
Cohesion: 0.22
Nodes (9): container_name, dns, environment, image, labels, networks, restart, volumes (+1 more)

### Community 275 - "sonarr"
Cohesion: 0.22
Nodes (9): sonarr, container_name, dns, environment, image, labels, networks, restart (+1 more)

### Community 276 - "redis"
Cohesion: 0.22
Nodes (9): REDISCLI_AUTH, command, container_name, environment, image, networks, restart, security_opt (+1 more)

### Community 277 - "system_unix.go"
Cohesion: 0.29
Nodes (11): autostartEnabled(), autostartFile(), clearUserEnv(), environmentD(), getUserEnv(), profileFiles(), refreshSessionEnv(), rewriteProfile() (+3 more)

### Community 278 - "🍊 Bergatrix — Visão Geral"
Cohesion: 0.22
Nodes (9): 🍊 Bergatrix — Visão Geral, Camadas (ordem de dependência 00 → 04), Como operar (essencial), Fluxo de tráfego e dependências, Mapa de documentos, Maturidade, O que é, Stack tecnológica recorrente (+1 more)

### Community 279 - "1. O que está migrado (no repositório)"
Cohesion: 0.22
Nodes (9): 1. O que está migrado (no repositório), 2. O que ainda referencia `bergaestudio` — e **NÃO deve mudar**, 3. Verificação rápida, 4. Ações manuais (dependem do servidor — **NÃO feitas por este repo**), Documentação atualizada, Domínio, Estratégia de certificado (TLS wildcard), Infraestrutura crítica (DNS) — documentada (+1 more)

### Community 280 - "release"
Cohesion: 0.22
Nodes (9): defaults, run, release, defaults, if, needs, runs-on, timeout-minutes (+1 more)

### Community 281 - "websecure"
Cohesion: 0.25
Nodes (8): websecure, trustedIPs, idleTimeout, readTimeout, respondingTimeouts, address, forwardedHeaders, transport

### Community 282 - "environment"
Cohesion: 0.39
Nodes (8): AUTHENTIK_POSTGRESQL__HOST, AUTHENTIK_POSTGRESQL__NAME, AUTHENTIK_POSTGRESQL__PASSWORD, AUTHENTIK_POSTGRESQL__USER, AUTHENTIK_REDIS__HOST, AUTHENTIK_TRUSTED_PROXY_CIDRS, environment, environment

### Community 283 - "app_layout.dart"
Cohesion: 0.17
Nodes (9): AppLayout, desktopFrom, isDesktop, kind, kindFor, LayoutKind, of, screenPadding (+1 more)

### Community 284 - "environment"
Cohesion: 0.43
Nodes (8): environment, CACHE_TTL_HOURS, DATABASE_URL, DEEMIX_URL, LOG_LEVEL, MUSIC_DIR, REDIS_URL, environment

### Community 285 - "web"
Cohesion: 0.25
Nodes (8): context, web, build, container_name, depends_on, labels, networks, restart

### Community 286 - "worker"
Cohesion: 0.15
Nodes (14): depends_on, migrate, redis, condition, condition, worker, build, command (+6 more)

### Community 287 - "Bergastream — login pelo Authentik"
Cohesion: 0.25
Nodes (8): 1. Grupos, 3. `.env` do Bergastream, 4. Contas que já existem, 5. Apps antigos e o login por senha, 6. Depois de ligada: quem muda o quê, 7. Testar, Bergastream — login pelo Authentik, Problemas comuns

### Community 288 - "11. Passos de implementação"
Cohesion: 0.04
Nodes (47): 0. Regras de trabalho (LEIA ANTES DE QUALQUER CÓDIGO), 11. Passos de implementação, 12. Checklist final de aceite, 13. Fora do escopo agora (não implementar), 1. Visão geral e decisões fixas, 2.1 Matriz de acesso, 2.2 Tela de login (todas as plataformas), 2.3 Estados de sessão (máquina de estados) (+39 more)

### Community 289 - "Point"
Cohesion: 0.21
Nodes (6): Point, x, y, Size, height, width

### Community 290 - "Bergastream — O que já foi implementado"
Cohesion: 0.25
Nodes (8): 2.1 Estrutura (Passos 1 a 3), 2.2 Design System (Seção 5), 2.3 Status da verificação (Passo 1), 2. Frontend Flutter, 4. Pendências conhecidas, 5. Como rodar (desenvolvimento), 6. Código antigo, Bergastream — O que já foi implementado

### Community 292 - "legendarr-worker"
Cohesion: 0.25
Nodes (8): build, container_name, dns, environment, networks, restart, volumes, legendarr-worker

### Community 293 - "torrent-indexer-br"
Cohesion: 0.25
Nodes (8): torrent-indexer-br, container_name, depends_on, dns, environment, image, networks, restart

### Community 294 - "db"
Cohesion: 0.22
Nodes (8): container_name, image, labels, networks, restart, volumes, services, db

### Community 295 - "app"
Cohesion: 0.13
Nodes (16): condition, container_name, depends_on, image, labels, networks, restart, security_opt (+8 more)

### Community 296 - "berga_colors.dart"
Cohesion: 0.10
Nodes (15): ac, BergaColors, bg, card, copyWith, dark, gr, lerp (+7 more)

### Community 297 - "cron"
Cohesion: 0.25
Nodes (8): container_name, entrypoint, image, networks, restart, security_opt, volumes, cron

### Community 298 - "1513629884013"
Cohesion: 0.25
Nodes (7): password, port, run_as, url, username, hosts, 1513629884013

### Community 299 - "Infraestrutura"
Cohesion: 0.25
Nodes (8): Caminho do tráfego, Dependências entre stacks, Infraestrutura, Máquinas e discos, Ordem de subida, Redes Docker, Repositórios, Stacks

### Community 300 - "Documentação da Infraestrutura: Edge Node L4 & Homelab"
Cohesion: 0.25
Nodes (7): 1. Edge Node: VPS Hostinger (São Paulo), 2. A Ponte: Túnel WireGuard, 3. Core: Servidor Físico (Homelab em Casa), 4. Fluxo de Roteamento (Passo a Passo), 5. Resumo das Proteções (Camadas de Segurança), Documentação da Infraestrutura: Edge Node L4 & Homelab, Visão Geral

### Community 301 - "healthcheck"
Cohesion: 0.48
Nodes (7): interval, retries, start_period, test, timeout, healthcheck, healthcheck

### Community 302 - "redis"
Cohesion: 0.29
Nodes (7): command, container_name, image, networks, restart, volumes, redis

### Community 303 - "pathlib"
Cohesion: 0.11
Nodes (8): file_matches(), normalize_title(), read_title(), titles_match(), main(), _activate_pydeps(), _folder_version(), version_tuple()

### Community 304 - "lidarr"
Cohesion: 0.29
Nodes (7): container_name, image, labels, networks, restart, volumes, lidarr

### Community 305 - "redis"
Cohesion: 0.29
Nodes (7): command, container_name, image, networks, restart, volumes, redis

### Community 306 - "track.dart"
Cohesion: 0.29
Nodes (6): album, artist, durationSeconds, id, title, Track

### Community 307 - "playlist_merge.dart"
Cohesion: 0.10
Nodes (19): applyOpsToDetail, applyOpsToList, common, copy, coverUrl, find, index, keep (+11 more)

### Community 308 - "PlayerController"
Cohesion: 0.13
Nodes (15): audioEngineProvider, mediaNotificationProvider, build, _fadeTo, _maybeFadeOut, _maybePrefetch, _onPosition, PlayerController (+7 more)

### Community 309 - "pubspec.yaml"
Cohesion: 0.29
Nodes (6): description, environment, sdk, name, publish_to, version

### Community 310 - "flutter"
Cohesion: 0.29
Nodes (7): flutter, fonts, uses-material-design, asset, family, fonts, weight

### Community 312 - "qrPolynomial"
Cohesion: 0.57
Nodes (3): qrPolynomial(), _this, QRUtil

### Community 313 - "healthcheck"
Cohesion: 0.43
Nodes (7): healthcheck, interval, retries, start_period, test, timeout, healthcheck

### Community 314 - "flaresolverr"
Cohesion: 0.29
Nodes (7): container_name, dns, environment, image, networks, restart, flaresolverr

### Community 315 - "healthcheck"
Cohesion: 0.43
Nodes (7): healthcheck, interval, retries, start_period, test, timeout, healthcheck

### Community 316 - "generator"
Cohesion: 0.29
Nodes (6): environment, hostname, image, volumes, services, generator

### Community 317 - "Login pelo Authentik em apps sem OIDC (LDAP)"
Cohesion: 0.29
Nodes (7): Como funciona, Configuração inicial (uma vez), Jellyfin, Ligar um app novo, Login pelo Authentik em apps sem OIDC (LDAP), Segurança, Uso no dia a dia

### Community 318 - "tls"
Cohesion: 0.33
Nodes (6): main, sans, tls, certResolver, domains, http

### Community 319 - "web"
Cohesion: 0.33
Nodes (6): entryPoints, web, trustedIPs, address, proxyProtocol, proxyProtocol

### Community 320 - "bergatrix.yaml"
Cohesion: 0.33
Nodes (5): description, name, whitelist, expression, reason

### Community 321 - "player_controller_test.dart"
Cohesion: 0.09
Nodes (14): main, search, abc, container, controller, engine, finish, main (+6 more)

### Community 322 - "services"
Cohesion: 0.33
Nodes (5): ports, services, api, web, ports

### Community 323 - "pot-provider"
Cohesion: 0.33
Nodes (6): container_name, image, init, networks, restart, pot-provider

### Community 324 - "Bergastream — versões dos apps (Android, Windows, Linux)"
Cohesion: 0.24
Nodes (5): Assinatura do Android (uma vez), Bergastream — versões dos apps (Android, Windows, Linux), Build local, Publicar uma versão, Requisitos para quem instala

### Community 325 - "analysis_options.yaml"
Cohesion: 0.33
Nodes (5): analyzer, exclude, include, linter, rules

### Community 326 - "playlist.dart"
Cohesion: 0.33
Nodes (5): id, name, peopleCount, PlaylistSummary, trackCount

### Community 328 - "router.dart"
Cohesion: 0.09
Nodes (5): catalog, initialLocationProvider, refresh, router, tab

### Community 329 - "migrate"
Cohesion: 0.33
Nodes (6): depends_on, egress, migrate, condition, condition, depends_on

### Community 330 - "compilerOptions"
Cohesion: 0.12
Nodes (16): compilerOptions, allowSyntheticDefaultImports, esModuleInterop, isolatedModules, jsx, lib, module, moduleResolution (+8 more)

### Community 331 - "version"
Cohesion: 0.33
Nodes (6): version, name, number, outputs, runs-on, timeout-minutes

### Community 332 - "windows"
Cohesion: 0.33
Nodes (6): windows, shell, needs, runs-on, steps, timeout-minutes

### Community 333 - "🍊 BERGATRIX"
Cohesion: 0.33
Nodes (6): 📦 Apps (03-apps), 📂 Arquitetura da Matrix, 🍊 BERGATRIX, 🚀 Como Iniciar, 🛡️ Pilares do Projeto, 👤 Sobre o Autor

### Community 334 - "bouncer"
Cohesion: 0.40
Nodes (5): moduleName, version, experimental, plugins, bouncer

### Community 335 - "entryPoint"
Cohesion: 0.40
Nodes (5): scheme, to, redirections, entryPoint, http

### Community 336 - "auth/repository.py"
Cohesion: 0.17
Nodes (13): insert_refresh_token(), revoke_refresh_token(), set_password(), body(), cleanup(), inbox(), _link(), link_of() (+5 more)

### Community 337 - "web_version_watcher.dart"
Cohesion: 0.08
Nodes (24): AuthTexts, emptyHome, enterToSearch, notDownloaded, serverUnavailable, serverUnavailableWeb, sessionExpired, build (+16 more)

### Community 338 - "depends_on"
Cohesion: 0.40
Nodes (5): condition, database, redis, depends_on, condition

### Community 339 - "Ligar e desligar tudo"
Cohesion: 0.40
Nodes (5): A ordem, Como se comportam, Depois de reiniciar o servidor, Ligar e desligar tudo, Stack nova, removida ou renomeada

### Community 340 - "env"
Cohesion: 0.40
Nodes (5): KEY_ALIAS, KEY_PASSWORD, KEYSTORE_BASE64, KEYSTORE_PASSWORD, env

### Community 341 - "acquis.yaml"
Cohesion: 0.50
Nodes (3): filenames, labels, type

### Community 343 - "Scanner"
Cohesion: 0.16
Nodes (6): startScanner(), CAMERA_ERRORS, cameraAvailable(), cameraErrorMessage(), nativeDetector(), Scanner

### Community 344 - "android"
Cohesion: 0.50
Nodes (4): needs, runs-on, timeout-minutes, android

### Community 345 - "test"
Cohesion: 0.50
Nodes (4): test, runs-on, steps, timeout-minutes

### Community 349 - "logout"
Cohesion: 0.11
Nodes (10): end_session(), create_pool(), _init(), callback(), health(), login(), logout(), robots() (+2 more)

### Community 350 - "playlist_cover_test.dart"
Cohesion: 0.10
Nodes (16): BackgroundFileFetcher, DioFileFetcher, FileFetcher, _NoFetcher, FakeFetcher, _QuickFetcher, cover, _CoverFetcher (+8 more)

### Community 356 - "app"
Cohesion: 0.14
Nodes (14): cap_drop, container_name, depends_on, labels, mem_limit, networks, ports, read_only (+6 more)

### Community 378 - "plan.py"
Cohesion: 0.33
Nodes (3): build(), create_defaults(), repository_url()

### Community 379 - "features_test.go"
Cohesion: 0.15
Nodes (6): TestRemoteDirValidation(), TestTrayIcons(), drawIcon(), icoBytes(), pngBytes(), trayIcon()

### Community 380 - "migrate"
Cohesion: 0.17
Nodes (12): condition, db, DATABASE_URL, command, container_name, depends_on, environment, image (+4 more)

### Community 381 - "local_playlists.dart"
Cohesion: 0.02
Nodes (91): add, build, clear, externalId, fromJson, imageUrl, key, kind (+83 more)

### Community 382 - "secrets"
Cohesion: 0.09
Nodes (20): close_redis(), add_track_to_playlist(), get_track_playlist_count(), release_if_orphan(), remove_track_from_playlist(), in_any_playlist(), reconcile(), sync_permanence() (+12 more)

### Community 383 - "runs.go"
Cohesion: 0.18
Nodes (7): newReporter(), logLine, LsEntry, outMsg, Reporter, Run, SnapshotInfo

### Community 384 - "web/app.js"
Cohesion: 0.40
Nodes (10): actions, api(), browse(), folderButton(), refresh(), render(), renderGlobalItems(), renderProjects() (+2 more)

### Community 385 - "environment"
Cohesion: 0.22
Nodes (9): environment, BERGAKUP_DATABASE_URL, BERGAKUP_OIDC_INTERNAL_URL, BERGAKUP_OIDC_ISSUER, BERGAKUP_PUBLIC_URL, BERGAKUP_SSO_CLIENT_ID, BERGAKUP_SSO_CLIENT_SECRET, BERGAKUP_USERS_GROUP (+1 more)

### Community 386 - "dart:math"
Cohesion: 0.22
Nodes (6): PlayQueue, list, main, q, t, titles

### Community 387 - "🔑 Bergatrix — Guia do `.env` (como construir, o que ter e como manipular)"
Cohesion: 0.22
Nodes (9): 1. Modelo mental — o `.env` tem papel DUPLO, 2. Como construir um `.env` (passo a passo), 3. O que todo `.env` costuma ter (variáveis comuns), 4. Como gerar segredos fortes, 5. Como manipular / manter o `.env`, 6. Armadilhas reais encontradas no repo, 7. Conformidade & segurança (obrigatório), 8. Template canônico de `.env.example` (para padronizar / criar os que faltam) (+1 more)

### Community 388 - "services"
Cohesion: 0.25
Nodes (7): internal, name, external, networks, bergakup-internal, bergatrix-proxy, services

### Community 389 - "db"
Cohesion: 0.25
Nodes (8): container_name, image, labels, networks, restart, security_opt, volumes, db

### Community 390 - "mail.py"
Cohesion: 0.13
Nodes (5): build(), _linkify(), MailError, set_transport(), _smtp_send()

### Community 391 - "claude-sync"
Cohesion: 0.25
Nodes (8): Arquivos, claude-sync, Como funciona, Compilar, Etiqueta do PC, Pasta no Nextcloud, Segurança, Usar

### Community 392 - "main"
Cohesion: 0.12
Nodes (5): FakeRedis, main(), track(), make_audio(), ok()

### Community 393 - "traefik — Reverse proxy / ingress central do homelab Bergatrix (Traefik v3.6.2) com TLS wildcard automatico via Let's Encrypt e DNS-01 challenge no deSEC."
Cohesion: 0.13
Nodes (16): Problemas comuns, web(), 📦 Serviços / Containers, 🧩 Dependencias internas (Bergatrix), 🌐 Dominios / Roteamento, 🔌 Endpoints / API, 🎯 Finalidade, 🛡️ Gestao de segredos (+8 more)

### Community 394 - "healthcheck"
Cohesion: 0.33
Nodes (6): healthcheck, interval, retries, start_period, test, timeout

### Community 395 - "environment"
Cohesion: 0.40
Nodes (5): environment, POSTGRES_DB, POSTGRES_PASSWORD, POSTGRES_USER, TZ

### Community 396 - "Bergastream — Mapa da API (API_MAP.md)"
Cohesion: 0.15
Nodes (12): lyrics(), 2. Tocar uma faixa, 3. Streaming e download, 6. Álbum, 7. Histórico e métricas, 9. Imagens, 9d. Aparelhos ("Tocar em…"), Bergastream — Mapa da API (API_MAP.md) (+4 more)

### Community 397 - "environment"
Cohesion: 0.40
Nodes (5): environment, POSTGRES_DB, POSTGRES_PASSWORD, POSTGRES_USER, TZ

### Community 398 - "build"
Cohesion: 0.67
Nodes (3): build, context, dockerfile

### Community 399 - "oidc_launcher_web.dart"
Cohesion: 0.18
Nodes (7): cancel, clearInitialCode, createOidcLauncher, initialCode, open, redirect, reloadPage

### Community 400 - "fake_oidc.dart"
Cohesion: 0.18
Nodes (9): cancel, cancelled, clearInitialCode, code, initial, initialCode, open, opened (+1 more)

### Community 405 - "FakeSessionRepository"
Cohesion: 0.67
Nodes (3): FakeSessionRepository, HttpSessionRepository, SessionRepository

### Community 407 - "updateSendButton"
Cohesion: 0.23
Nodes (14): activeTab(), addFiles(), addOutItem(), deliver(), renderFileList(), selectTab(), sendFiles(), sendNow() (+6 more)

### Community 408 - "onSwap"
Cohesion: 0.38
Nodes (13): acceptSwap(), canSwap(), commitSwap(), declineSwap(), finishSwap(), onFrame(), onSwap(), renderSwap() (+5 more)

### Community 409 - "SessionSocket"
Cohesion: 0.67
Nodes (3): FakeSessionSocket, SessionSocket, WebSessionSocket

### Community 410 - "playlists/service.py"
Cohesion: 0.15
Nodes (16): access(), cover_url(), delete(), detail(), list_for(), Member, Person, _person() (+8 more)

### Community 411 - "UpdateLauncher"
Cohesion: 0.67
Nodes (3): SystemUpdateLauncher, UpdateLauncher, FakeUpdateLauncher

### Community 416 - "catalog_navigation.dart"
Cohesion: 0.22
Nodes (7): albumPathOf, artistPathOf, currentPath, goToAlbumOf, goToArtistOf, openAlbum, openArtist

### Community 417 - "oidc_launcher.dart"
Cohesion: 0.25
Nodes (5): cancel, clearInitialCode, initialCode, open, redirect

### Community 419 - "sync_test.go"
Cohesion: 0.15
Nodes (21): fakeNextcloud, pc, newApp(), newEngine(), TestMoveRemoteFolderOtherPCsFollow(), TestSettingsSyncCarriesNoTagHook(), jsonl(), md5hex() (+13 more)

### Community 420 - "tempfile"
Cohesion: 0.32
Nodes (3): _join(), test_status_is_green_when_any_subtitle_file_exists(), test_status_is_red_when_no_subtitle_exists()

### Community 421 - "app/db.py"
Cohesion: 0.32
Nodes (3): create_pool(), get_pool(), _init()

### Community 423 - "SessionController"
Cohesion: 0.29
Nodes (7): authRepositoryProvider, oidcLauncherProvider, completePendingOidc, initialSessionProvider, SessionController, SessionState, sessionStorageProvider

### Community 426 - "update_job"
Cohesion: 0.67
Nodes (5): create_job(), job_public(), job_values(), JobIn, update_job()

### Community 428 - "upgrader.py"
Cohesion: 0.15
Nodes (14): current_rank(), by_name(), LidarrError, backfill_quality(), clear_stuck(), _current(), deemix_pass(), _each() (+6 more)

## Knowledge Gaps
- **2370 isolated node(s):** `claude-sync`, `act`, `addAllToQueue`, `addToQueue`, `_advance` (+2365 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 5168 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **54 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC` connect `jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC` to `Pipeline`, `worker/core/scanner.py`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **Are the 69 inferred relationships involving `CurrentUser` (e.g. with `change_my_password()` and `create_user()`) actually correct?**
  _`CurrentUser` has 69 INFERRED edges - model-reasoned connections that need verification._
- **What connects `claude-sync`, `act`, `addAllToQueue` to the rest of the system?**
  _2370 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `player_controller.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.013245033112582781 - nodes in this community are weakly interconnected._
- **Why does `🚧 Notas de evolucao / pendencias` connect `worker/core/scanner.py` to `jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC`, `sessions/service.py`?**
  _High betweenness centrality (0.029) - this node is a cross-community bridge._
- **Should `database.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.017857142857142856 - nodes in this community are weakly interconnected._
- **Why does `id_token()` connect `test_units.py` to `test_integration.py`, `test_auth.py`, `logging`, `auth/routes.py`, `Transcriptor`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._