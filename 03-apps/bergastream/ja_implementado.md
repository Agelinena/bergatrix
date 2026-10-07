# Bergastream — O que já foi implementado

> Documento atualizado em 07/10/2026 (revisado contra o código).
> Backend completo para os Passos 0–13 e frontend Flutter (web, Android, Windows, Linux) com os
> Passos 0 a 13. Deploy: [docs/DEPLOY.md](docs/DEPLOY.md) · usuários: [docs/USUARIOS.md](docs/USUARIOS.md) ·
> versões dos apps: [docs/RELEASE.md](docs/RELEASE.md).

---

## 1. Backend (FastAPI + PostgreSQL + Redis)

### 1.1 Infraestrutura

| Componente | Imagem / Versão | Porta |
|---|---|---|
| **db** (PostgreSQL) | `postgres:16-alpine` | 5432 |
| **redis** (Cache/Fila) | `redis:7-alpine` | 6379 |
| **migrate** (dbmate) | `ghcr.io/amacneil/dbmate:2` | — |
| **deemix** (Sidecar Deezer) | `registry.gitlab.com/bockiii/deemix-docker` | 6595 |
| **api** (FastAPI) | `python:3.12-slim` (build local) | 8000 |
| **worker** (Download em background) | `python:3.12-slim` (build local) | — |
| **web** (Flutter) | `ghcr.io/cirruslabs/flutter:stable` (build) | 8080 |

### 1.2 Estrutura do Backend

```
backend/
├── Dockerfile
├── requirements.txt
├── worker.py                    ← Processo isolado para downloads via Redis
├── app/
│   ├── main.py                  ← FastAPI lifespan (pool DB + Redis + cleanup task)
│   ├── config.py                ← pydantic-settings (lê .env)
│   ├── core/
│   │   ├── db.py                ← Pool asyncpg (singleton global)
│   │   └── redis.py             ← Conexão redis.asyncio
│   ├── api/
│   │   └── routes.py            ← Rotas da API (todas exigem login; stream aceita ?t=)
│   ├── auth/                    ← Autenticação (ver 1.9)
│   │   ├── security.py          ← Argon2, JWT de acesso e de stream, refresh opaco
│   │   ├── repository.py        ← SQL de usuários e refresh tokens
│   │   ├── service.py           ← Login, renovação com rotação/reuso, logout
│   │   ├── rate_limit.py        ← 5 falhas por usuário+IP → bloqueio de 15 min (Redis)
│   │   ├── dependencies.py      ← current_user, admin_user, stream_user
│   │   ├── routes.py            ← /api/auth/config|login|register|refresh|logout|me
│   │   └── cli.py               ← create-user, set-password, list-users
│   ├── search/
│   │   ├── models.py            ← SearchResult (provider, external_id, title, artist...)
│   │   ├── spotify.py           ← Busca via Spotify Client Credentials
│   │   ├── youtube.py           ← Busca via yt-dlp (ytsearch)
│   │   └── ytmusic.py           ← Busca via yt-dlp (music.youtube.com/search)
│   ├── tracks/
│   │   ├── models.py            ← Track, PlayRequest, PlayResponse
│   │   ├── repository.py        ← SQL puro (get, create, link, fuzzy match)
│   │   └── service.py           ← Resolução 5-passos (exato→ISRC→fuzzy→yt-dlp ISRC→cria)
│   ├── downloads/
│   │   ├── state.py             ← Estado em memória (fallback para Redis)
│   │   ├── queue.py             ← Fila Redis com 3 prioridades (alta/média/baixa)
│   │   ├── deemix.py            ← Cliente HTTP para sidecar Deemix
│   │   ├── youtube.py           ← yt-dlp download + scoring de candidatos ±3s
│   │   └── service.py           ← Orquestrador Spotify→Deemix→fallback YouTube
│   ├── storage/
│   │   └── service.py           ← Limpeza de cache (TTL configurável, loop 1h)
│   ├── users/
│   │   ├── models.py            ← User, Playlist (Pydantic)
│   │   └── repository.py        ← SQL puro (get_users, get_playlists)
│   └── playlists/
│       └── repository.py        ← Adicionar/remover tracks + transição permanent/cache
├── db/
│   └── migrations/
│       ├── 0001_create_tracks.sql
│       ├── 0002_create_external_ids.sql
│       ├── 0003_create_files.sql
│       ├── 0004_create_users_playlists.sql ← + seed 2 users + playlists
│       └── 0005_auth.sql        ← username/senha/admin nos usuários + refresh_tokens
├── static/
│   └── index.html               ← Página web com 4 abas + playlists + status kind
└── tests/
    ├── test_auth.py              ← 38 verificações (login, rotação, reuso, logout, limite, stream, admin)
    ├── test_permanence.py        ← 8 asserts (ciclo de vida permanência)
    └── test_all.py               ← script próprio, 21 verificações (dedup, permanência, fila, scoring)
```

### 1.3 Endpoints da API

Detalhes em `docs/API_MAP.md`.

| Método | Rota | Descrição | Autenticação |
|---|---|---|---|
| GET | `/health` | Healthcheck | Pública |
| GET | `/api/auth/config` | Se o cadastro está aberto | Pública |
| POST | `/api/auth/login` · `/register` · `/refresh` · `/logout` | Sessão | Pública |
| GET | `/api/auth/me` | Usuário do token | Bearer |
| GET | `/api/search?q=&source=` | Busca (spotify, ytmusic, youtube, all) | Bearer |
| POST | `/api/play` | Resolver faixa + enfileirar download | Bearer |
| GET | `/api/tracks/{id}/status` | Estado do download | Bearer |
| POST | `/api/tracks/{id}/stream-token` | Token curto para tocar na web | Bearer |
| GET | `/api/tracks/{id}/stream` | Streaming com HTTP Range | Bearer ou `?t=` |
| GET | `/api/me/playlists` | Playlists do usuário logado | Bearer |
| GET | `/api/users` | Listar usuários | Admin |
| GET | `/api/users/{id}/playlists` | Playlists de um usuário | O próprio ou admin |
| POST/DELETE | `/api/playlists/{id}/tracks[/{tid}]` | Adicionar/remover faixa | Dono ou admin |
| POST | `/api/admin/cleanup` | Forçar limpeza de cache (antes era GET) | Admin |

### 1.4 Banco de Dados (7 tabelas)

| Tabela | Colunas principais |
|---|---|
| **tracks** | `id` (UUID PK), `title`, `artist`, `album`, `duration_seconds`, `isrc` (UNIQUE), `cover_url` |
| **external_ids** | `track_id` (FK), `provider`, `external_id` — PK composta `(provider, external_id)` |
| **files** | `id` (UUID PK), `track_id` (FK UNIQUE), `path`, `size_bytes`, `format`, `kind` (cache/permanent), `last_played_at` |
| **users** | `id` (UUID PK), `name`, `username` (único, sem diferenciar maiúsculas), `password_hash`, `is_admin`, `created_at` — seed: User A/B viram `usera`/`userb`, sem senha |
| **refresh_tokens** | `id`, `user_id`, `family_id`, `token_hash` (SHA-256), `expires_at`, `revoked_at`, `user_agent` |
| **playlists** | `id` (UUID PK), `user_id` (FK), `name` — seed: Favoritas para cada user |
| **playlist_tracks** | `playlist_id`, `track_id`, `added_at` — PK composta |

### 1.5 Fluxo de Resolução (anti-duplicação cross-provider)

```
POST /api/play (SearchResult)
  │
  ├─ 1. Busca exata por (provider, external_id)
  ├─ 2. Se tem ISRC, busca por ISRC
  ├─ 3. Busca heurística (fuzzy): artista ILIKE + título ILIKE + duração ±3s
  ├─ 4. Se YouTube, extrai ISRC do vídeo via yt-dlp (--dump-json)
  ├─ 5. Se match → vincula novo external_id + retorna track existente
  └─ 6. Se nada → cria nova faixa + enfileira download no Redis
```

### 1.6 Fila Redis (3 prioridades)

| Fila | Prioridade | Uso |
|---|---|---|
| `bergastream:q:high` | 1 (Alta) | Clique direto do usuário |
| `bergastream:q:medium` | 2 (Média) | Rádio (reservado) |
| `bergastream:q:low` | 3 (Baixa) | Playlists / Background |

Worker: 2 downloads concorrentes, consome via `BRPOP` (alta primeiro).

### 1.7 Ciclo de Vida de Permanência

```
Adicionar à playlist → kind = 'permanent'
Remover da última playlist → kind = 'cache' + last_played_at = now()
Re-adicionar durante TTL → kind = 'permanent'
Cleanup (a cada 1h) → apaga se kind='cache' E (last_played_at + TTL < now())
```

### 1.8 Testes Automatizados (último resultado relatado: 21/21; não reexecutado nesta revisão)

| Teste | O que cobre |
|---|---|
| Deduplicação Cruzada | Spotify→YouTube fuzzy match + link external_id |
| Permanência | Adicionar/remover User A/B, transição cache↔permanent |
| Concorrência da Fila | Prioridade 1 sai antes de 3, BRPOP respeita ordem |
| Scoring de Fallback | ±3s tolerância, penalidade -30 para live/cover/karaoke |

### 1.10 Correções no download (feitas no Passo 5)

O player não tocava nada porque as duas fontes de download falhavam:
- **`NameError: db_pool`** em `downloads/service.py`: toda faixa do Spotify quebrava no worker. Corrigido.
- **Deemix esperava 180 s** mesmo quando já tinha falhado. Agora consulta a fila do Deemix e desiste na hora (`downloads/deemix.py`). O Deemix em si continua falhando (`Cannot read properties of undefined (reading 'HREF')`, provavelmente ARL expirado ou `deemix-docker` desatualizado) → cai no YouTube.
- **yt-dlp travava o worker** (rodava síncrono dentro de `async`), derrubando a conexão com o Redis. Agora roda em thread.
- **yt-dlp sem runtime JavaScript** (403 em parte dos vídeos): imagem ganhou o **Deno** e o pacote `yt-dlp[default]`.
- Resultado: faixa do Spotify fica pronta em ~15 s (antes: falha após 3+ min).

### 1.11 Usuário de teste local

`demo` / `demo` existe **só no banco local** (inserido direto, não está em migração nem em código). Ao subir num servidor novo ele não existe; crie os usuários com o CLI (seção 1.9).

### 1.9 Autenticação

- Senhas com Argon2; access token JWT HS256 de 15 min; refresh token opaco de 30 dias guardado só como hash.
- Rotação: cada renovação troca o refresh; reusar um antigo revoga a família (sinal de roubo).
- Limite: 5 falhas de login por usuário+IP → 429 por 15 min.
- Stream na web: `POST /api/tracks/{id}/stream-token` → `/stream?t=<token>` (só aquela faixa, 6 h).
- Segredo em `JWT_SECRET` (adicionado ao `.env`; sem ele a API gera um aleatório e as sessões caem a cada reinício). Cadastro público: `ALLOW_REGISTRATION=false` por padrão.
- Criar usuário: `docker compose exec api python -m app.auth.cli create-user <nome> --admin` (pede a senha). Também `set-password <nome>` (encerra as sessões abertas) e `list-users`.
- ⚠️ A página de teste `backend/static/index.html` chama a API sem token e parou de funcionar; usar o app.

---

## 2. Frontend Flutter

### 2.1 Estrutura (Passos 1 a 3)

```
frontend/
├── Dockerfile                    ← Multi-stage (flutter build web → nginx)
├── nginx.conf                    ← Proxy reverso /api/ → api:8000
├── pubspec.yaml                  ← go_router, flutter_riverpod, flutter_secure_storage, dio, json_annotation (+ json_serializable/build_runner)
├── analysis_options.yaml         ← flutter_lints + aspas simples, const, vírgulas finais
├── assets/fonts/                 ← Bricolage Grotesque 400/600/800 (TTF estáticas) + OFL.txt
├── android/                      ← com.bergastream.app, minSdk 24, permissões da Seção 3,
│                                    cleartext só em debug
├── lib/
│   ├── main.dart                 ← Detecta plataforma/visualização, carrega a sessão salva, ProviderScope
│   ├── app/
│   │   ├── app.dart              ← MaterialApp.router, tema claro/escuro (ThemeMode.system)
│   │   ├── routes.dart           ← /entrar, /inicio, /buscar, /biblioteca, /ajustes, /dev/gallery
│   │   ├── router.dart           ← go_router (provider): shell com 4 abas + redirecionamento por sessão
│   │   ├── app_frame.dart        ← Escolhe layout: web ≥ 900 px → navegador; app/simulação → coluna 430
│   │   ├── app_shell.dart        ← Layout de celular: conteúdo + mini player + barra inferior
│   │   ├── desktop_shell.dart    ← Layout de navegador: barra lateral + conteúdo + barra do player
│   │   └── dev/gallery_screen.dart ← Galeria de componentes (dados fictícios do protótipo)
│   ├── core/
│   │   ├── theme/
│   │   │   ├── berga_colors.dart ← Tokens (ThemeExtension): bg, card, tx, mu, ac, gr, on, scrim
│   │   │   ├── berga_text.dart   ← Tipografia da Seção 5.2
│   │   │   ├── berga_sizes.dart  ← Medidas da Seção 5.3
│   │   │   └── berga_theme.dart  ← ThemeData claro/escuro (sem ripple, como o protótipo)
│   │   ├── platform/             ← AppPlatform (web / app / simulação ?modo=android), AppLayout
│   │   ├── storage/              ← KeyValueStore (armazenamento seguro; memória nos testes)
│   │   ├── network/              ← createDio, AuthInterceptor (token + renovação única), ApiException
│   │   ├── utils/format.dart     ← Duração "3:05"
│   │   └── widgets/              ← Seção 5.4 (exportados por widgets.dart):
│   │                                Cover, TrackRow, SectionTitle/ScreenTitle, HorizontalShelf,
│   │                                ArtistCircle, AlbumTile, StatCard, AppCard, AppChip,
│   │                                PrimaryButton, PlayButton, AppTextField, AppToast,
│   │                                TrackActionsSheet, ProgressBarThin, OfflineBanner,
│   │                                DownloadStateIcon
│   ├── features/
│   │   ├── home/                 ← Início (saudação por horário, métricas, carrosséis)
│   │   ├── search/               ← Buscar (recentes, filtro nos dados fictícios, link colado)
│   │   ├── library/              ← Biblioteca (lista de playlists; detalhe no Passo 8)
│   │   ├── settings/             ← Ajustes (cartões do protótipo)
│   │   ├── player/               ← Player (Passo 5): fila dupla, controlador, motor just_audio,
│   │   │                            notificação (audio_service), mini/grande/barra, painel da fila
│   │   ├── auth/                 ← Sessão (máquina de estados), login, aviso de sessão, redirecionamento
│   │   └── artist, album, downloads ← Vazias (próximos passos)
│   └── data/
│       ├── api/api_dio.dart      ← Cliente autenticado do servidor da sessão
│       ├── models/               ← Track, PlaylistSummary, AuthUser/TokenResponse, SearchResult (json_serializable)
│       └── repositories/         ← Auth, Search, Playback (Http + Fake), fake_catalog
├── test/
│   ├── flutter_test_config.dart  ← Carrega Bricolage + Material Icons nos testes
│   ├── core/widgets/             ← Cover, TrackRow, AppChip, AppToast, TrackActionsSheet
│   ├── app/gallery_golden_test.dart + goldens/ ← Galeria nos temas escuro e claro
│   ├── app_harness.dart          ← Monta o app com plataforma, sessão e auth fictícios
│   ├── app/shell_test.dart       ← Abas, estado/rolagem preservados, 360 e 1200 px
│   ├── app/layout_test.dart      ← Web larga/estreita, simulação Android, modo local
│   ├── features/auth/            ← Transições da sessão, redirecionamento web/app, tela de login
│   ├── data/                     ← Repositórios HTTP com respostas reais do backend (test/fixtures)
│   ├── features/player/          ← Fila (17), controlador (14) e interface do player (6)
│   ├── core/network/             ← Interceptor: 401 → renova uma vez, chamadas simultâneas → 1 renovação
│   ├── features/                 ← Saudação, busca, legenda da playlist
│   └── widget_test.dart          ← App abre no Início; galeria em /dev/gallery
├── linux/, windows/              ← Gerados pelo flutter create; só entram no Passo 13
└── web/                          ← index.html e manifest com nome/cor do Bergastream
```

### 2.2 Design System (Seção 5)

| Token | Escuro | Claro |
|---|---|---|
| bg (fundo) | `#0B0B0A` | `#F5F4EF` |
| card (cartões) | `#191917` | `#E8E6DC` |
| tx (texto) | `#F2F1EC` | `#14130F` |
| mu (texto secundário) | `#8E8D84` | `#6A685C` |
| ac (laranja/ações) | `#FF7A1A` | `#D95F00` |
| gr (verde/ativo) | `#3FCF6E` | `#1F9A4A` |
| on (texto sobre ac/gr) | `#1A0B00` | `#FFFFFF` |

Decisões tomadas no Passo 1 (já refletidas na Documentação e no Preview):
- Matiz da capa via hash FNV-1a, sempre entre 18 e 150. A multiplicação é feita em partes para não passar de 2^53 (na web os inteiros são doubles); um teste fixa os valores de referência.
- O caractere ♫ não existe na Bricolage → capas de playlist e capas sem título usam o ícone `music_note`.
- `TrackActionsSheet`: ação sem callback aparece em `mu` e, ao tocar, mostra a explicação em toast.
- `DownloadStateIcon`: ícones de `naFila` (`schedule`) e `falhou` (`error_outline`) definidos aqui, pois a spec não dizia.
- Arrastar-para-fila do `TrackRow` fica para o Passo 6 (onde está o teste do gesto).
- Texto com `height: 1.2` (altura natural da Bricolage, igual ao `line-height: normal`); sem isso herda o 1.43 do Material 3.
- `VisualDensity.standard` em todas as plataformas (o padrão compacto do web/desktop encolhia o campo de 42 para 34 px).
- Onde o CSS do protótipo colapsa margens (h1 + cartão em Ajustes; chips + conteúdo na Busca), o app replica o espaçamento resultante.

Decisões do Passo 5 (player):
- Fluxo de tocar: `POST /api/play` → consulta `/status` a cada 1,5 s ("Baixando…" no mini player e na barra) → `POST /stream-token` → toca `/stream?t=`. O token na URL é usado em **todas** as plataformas (um caminho só).
- Trocar de faixa durante o preparo descarta a anterior. Erro ou mais de 3 min sem ficar pronta → aviso "Não foi possível tocar esta música."
- Fila (Seção 7): sua fila (FIFO) antes da automática; aleatório só na automática; anterior > 3 s recomeça; repetir desligado → tudo → uma faixa (com aviso); tocar lista nova preserva a sua fila; acabou tudo → para.
- "Adicionar à fila" com nada tocando começa a tocar. Reordenar arrastando pela alça; remover no ✕; "Limpar fila"; "Ver todas" depois de 4.
- O título de "a seguir" é "A seguir" quando a origem é a Busca ou a sua fila, e "A seguir da playlist" nas playlists.
- Notificação de mídia e tela de bloqueio via `audio_service` (Android); na web vira a Media Session do navegador (controles de mídia do sistema). Foco de áudio via `audio_session` (pausa em ligação).
- Histórico: conta a reprodução ao passar de 30 s ou da metade, mas o backend ainda não tem histórico (pendência nº 7) — por enquanto só vai para o log.
- Layout de navegador: botão Fila abre um painel à direita. Sem player grande no navegador (a barra substitui).
- Faixas fictícias (Início, Biblioteca) ainda não tocam (não existem no servidor).
- Ainda não testado em aparelho Android real (segundo plano, notificação, tela de bloqueio).

Decisões do Passo 4:
- Login e busca reais. O `FakeAuthRepository` ficou só para testes.
- Renovação automática: o interceptor pega o 401, renova uma vez (chamadas simultâneas compartilham a mesma renovação) e repete a chamada. Renovação recusada → sessão expirada; sem rede → modo offline (não expira).
- Ao abrir o app, `/api/auth/me` confere a sessão salva.
- Erros do login: 400/401/403/422 → "Usuário ou senha incorretos."; 404 ou resposta que não é JSON → "Servidor não encontrado."; host inexistente → idem; 429 → "Muitas tentativas…"; demais → "Não foi possível conectar…".
- A Buscar usa o backend: só a seção Músicas (artistas/álbuns são pendência nº 9), espera de 400 ms, "Buscando…", erro com "Tentar de novo". YT Music vem sem artista/capa (limitação do backend).
- Layout de navegador agora ocupa toda a largura (tirado o limite de 1100 px).

Decisões do layout de navegador e do Passo 3:
- Web a partir de 900 px usa o layout de navegador (Seção 6.8 da Documentação); abaixo disso, layout de celular. O pedido do usuário mudou a regra anterior (coluna de 430 px na web).
- `/?modo=android` simula o Android no navegador (regras do app + layout de celular). Sessões da web e da simulação são salvas com chaves separadas.
- (Substituído no Passo 4 pelo login real.) Login fictício `demo`/`demo` só nos testes.
- Sem servidor (modo local, sessão expirada ou servidor indisponível): Início mostra o estado vazio, Busca é local com o convite "Entre para buscar…", Biblioteca mostra "Nenhuma playlist neste aparelho." e o mini player/barra do player somem (a faixa fictícia é do servidor).
- Erros do login em `ac` (laranja), abaixo do campo; "Sem conexão" fica abaixo da senha.
- "Sair" no app pergunta "Manter as músicas baixadas neste aparelho?" (Apagar tudo / Manter); por enquanto as duas só saem (downloads no Passo 9). Na web sai direto.
- O interceptor de renovação de token fica para o Passo 4 (com o `dio`); a renovação e o estado `sessaoExpirada` já estão no controlador.
- Em debug, Ajustes tem o cartão "Desenvolvimento": simular servidor indisponível e sessão expirada.
- Os avisos de sessão só aparecem no app (na web, sessão expirada volta ao login; servidor indisponível na web fica para o Passo 11).

Decisões do Passo 2:
- Saudação: 5h–11h59 "Bom dia", 12h–17h59 "Boa tarde", demais "Boa noite" (a spec não definia os horários).
- Ações do ⋮ aparecem desabilitadas, com o aviso "Disponível nos próximos passos" (fila no Passo 5, demais no Passo 6).
- Tocar numa playlist ainda não abre o detalhe (Passo 8); tocar no mini player ainda não abre o player grande (Passo 5).
- A Busca filtra os dados fictícios na hora (sem debounce), só para reproduzir o protótipo; busca real no Passo 6.
- Capas usam o matiz derivado do id (Documentação), não as cores fixas do protótipo; iniciais com ~40% do tamanho (o protótipo herdava 15 px).

### 2.3 Status da verificação (Passo 1)

Rodado na imagem `ghcr.io/cirruslabs/flutter:stable` (Flutter 3.44.0 / Dart 3.12.0):

| Verificação | Resultado |
|---|---|
| `flutter pub get` | ✅ |
| `flutter analyze` (projeto inteiro, inclui `test/`) | ✅ No issues found |
| `flutter test` | ✅ 133 testes passando (incluindo 2 golden) |
| `flutter build web --release` | ✅ Built build/web |
| `flutter build apk --debug` (com.bergastream.app) | ✅ Built app-debug.apk |
| Comparação lado a lado com o protótipo (Chrome, 430 px, 4 abas) | ✅ Iguais, exceto cores/iniciais das capas (ver decisões) |
| Comparação visual no emulador Android | ⏳ Falta (critério de aceite manual) |

## 3. Passos 6 a 13

### Passo 6 — Início com métricas
- `GET /api/me/stats` (ouvidas no mês, horas, artistas e faixas mais tocadas) e `POST /api/history`
  idempotente por `client_id` (migração `0007_history.sql`).
- Início com dados reais; cache local (`home.stats`) para abrir sem rede; reproduções offline
  ficam em `pending_plays` e são enviadas ao reconectar.

### Passo 7 — Busca completa e links
- `GET /api/search/full` (faixas, artistas, álbuns; Spotify e YouTube Music via ytmusicapi).
- `GET /api/resolve?url=` para links do Spotify, Deezer e YouTube (faixa, álbum, playlist; até 10.000 faixas).
- Busca com seções, histórico de buscas, busca local (biblioteca/baixadas) e tela de link importado.

### Passo 8 — Artista, álbum e playlist
- `GET /api/artists/{p}/{id}` + `/tracks` paginado (mais de 100 faixas), `GET /api/albums/{p}/{id}`,
  cache de 10 min (`app/catalog`).
- Playlists completas (`0006_playlists_full.sql`): CRUD, capa (upload multipart), ordem manual,
  "adicionado por", membros leitor/editor, diretório de pessoas, compartilhar.
- Rotas de artista/álbum abertas dentro de cada aba (mantém navegação e player).

### Passo 9 — Download para o aparelho
- `GET /api/tracks/{id}/download` (arquivo completo); banco local Drift (faixas, playlists baixadas,
  referências); background_downloader; "Baixar só no Wi-Fi"; Gerenciar downloads em Ajustes.
- Player local-first: toca o arquivo baixado sem servidor (modo avião).

### Passo 10 — Histórico e métricas
- Registro de reprodução no player (servidor ou pendente), qualidade de streaming e
  "baixar novas músicas automaticamente" em Ajustes.

### Passo 11 — Offline-first e sincronização
- `ServerMonitor` (confere `/api/auth/config` a cada 30 s e ao mudar a rede), aviso de servidor
  indisponível, envio das reproduções pendentes, atualização das playlists baixadas e selo de
  mudanças, oferta de enviar playlists locais ao entrar.

### Passo 12 — Web
- Login obrigatório; layout de navegador ≥ 900 px; stream autenticado por `?t=`.
- `GET /api/images?url=` (proxy de capas com lista de hosts, cache em disco) — na web todas as
  capas externas passam por ele (CORS).
- `Dockerfile` com `flutter build web --release --no-web-resources-cdn` (CanvasKit local) e
  `.dockerignore`; nginx com fallback de SPA, resolver dinâmico do Docker e IP real atrás do Traefik.
- `/` e `#/` abrem o Início; endereço inexistente mostra "Página não encontrada".
- `integration_test/app_flow_test.dart` (fluxo do app e da web).

### Passo 13 — Release e desktop
- Ícone próprio (gradiente laranja→verde com "B"; `frontend/tool/make_icons.py` gera Android,
  adaptativo/monocromático, notificação, web, Windows e Linux), nome "Bergastream".
- Assinatura de release por `android/key.properties` (fora do git); APK universal e AAB.
- Windows/Linux: `just_audio_media_kit`, layout de navegador em janela ≥ 900 px (com as regras do
  app: uso sem login, downloads), tamanho mínimo 360×600, título "Bergastream".
- Linux sem D-Bus do sistema não derruba mais o app (`SafeConnectivity`).
- **Atualização pelo app** (Android/Windows/Linux): consulta as releases do GitHub; "Baixar e
  instalar" (Android), "Baixar" (desktop, abre a pasta), "Ver no GitHub", "Agora não".
- **Login dos apps atrás do Traefik (modelo B):** o app testa `…/api-access-bypass` antes do
  endereço digitado.
- CI: `.github/workflows/bergastream-release.yml` (tag `bergastream-vX.Y.Z`).
- Deploy de produção: compose com `${STORAGE_PATH}`, `container_name`, redes
  `bergastream-internal` (sem internet) e `bergastream-egress`, labels do modelo B.

### Versão 0.1.6 — playlists na busca
- Seção **Playlists** na Busca: YouTube Music (editoriais e da comunidade), Deezer e Spotify,
  intercaladas, com capa, origem e número de músicas. Tocar abre a tela de link importado
  ("Importar tudo" / "Só as músicas").
- **"rádio <artista>"** (ou "radio …") traz a rádio do artista do YouTube Music em primeiro lugar;
  ela abre como lista (`get_watch_playlist`, ~50–150 faixas).
- Spotify: apps novos não leem playlists do próprio Spotify (mudança de 27/11/2024); a busca as
  omite e o servidor descarta as de dono "spotify". Alternativas: copiar a playlist para a conta
  e colar o link, ou usar as equivalentes do YouTube Music/Deezer.
- Servidor: `GET /api/search/playlists`, `app/search/playlists.py`; origem fora do ar não derruba
  as outras. Workflow com limite de tempo por job e novas tentativas no `apt`.

### Versão 0.1.5 — player, aleatório e falhas do Deemix
- **Arrastar para a fila** menos sensível: precisa puxar a linha 35% da largura (mínimo 110 px) e
  soltar depois do ponto; "petelecos" na rolagem não contam mais. Vibra ao passar do ponto.
- **Mini player**: arrastar para a esquerda pula a música; para a direita volta para a anterior.
- **Busca**: "x" no campo apaga o texto; "x" em cada busca recente apaga o termo.
- **Continua de onde parou**: fila, música atual, posição, aleatório e repetição são guardados; ao
  reabrir o app (mesmo fechado de vez) o player aparece pausado e tocar retoma do mesmo ponto.
- **Aleatório**: tocar de uma playlist sempre usa a playlist inteira (mesmo com a busca filtrando
  ou começando pela última faixa). No player, desligar segue a ordem depois da atual; religar
  sorteia de novo todas as faixas que ainda não tocaram nesta sessão ("sessão" = tocar a
  playlist). O estado do aleatório fica guardado por playlist.
- **Falhas do Deemix**: o item com falha sai da fila do Deemix (e os antigos são limpos ao subir a
  API); o servidor guarda as falhas recentes com o motivo e se o YouTube baixou no lugar
  (Ajustes → No servidor).

### Versão 0.1.4 — Biblioteca pela última tocada, Ajustes do servidor
- **"Ordenar por" guardado**: a ordenação de cada playlist fica salva no aparelho (sair, voltar e
  reabrir o app mantém).
- **Biblioteca pela última tocada**: o app manda, com cada reprodução, de qual playlist ela veio
  (`play_history.playlist_id`, migração `0010_history_playlist.sql`); `GET /api/me/playlists`
  ordena por `last_played_at` (de qualquer aparelho) e o app reordena na hora ao tocar, mesmo
  offline.
- **Ajustes → Aparência**: Sistema, Claro ou Escuro.
- **Ajustes → No servidor** (`GET /api/server/status`): músicas baixadas e espaço (total,
  permanentes, cache), disco livre, downloads do servidor (baixando/na fila) e fila do Deemix com
  os itens (baixando, na fila, com falha). Atualiza a cada 10 s enquanto aberto.

### Versão 0.1.3 — importar playlist com todos os dados
- Botão "Importar" no link de playlist/álbum pergunta: **Importar tudo** (playlist nova com o nome,
  a descrição e a foto de capa da original, e todas as músicas) ou **Só as músicas** (escolhe a
  playlist de destino, como antes).
- Servidor: `GET /api/resolve` devolve `description` (Spotify, Deezer, YouTube; HTML vira texto);
  operação `cover` em `POST /api/playlists/ops` baixa a capa da origem (mesmos hosts permitidos do
  proxy de imagens) e `create` aceita `description`. Sem servidor, tudo entra na fila.
- A descrição aparece na tela da playlist.

### Versão 0.1.2 — importação grande e ordenação
- Importar link de playlist com mais de 500 músicas: o limite passou a 10.000 (máximo do Spotify)
  na leitura do link e no envio em lote; o envio continua num pedido só para manter a ordem.
  Tempos de espera maiores no app e no nginx (5 min para ler o link) e corpo até 16 MB.
- "Ordenar por" dentro da playlist: ordem da playlist, adicionadas por último/primeiro, título,
  artista e álbum (A–Z/Z–A), mais curtas/mais longas. A escolha vale por playlist enquanto o app
  está aberto; tocar segue a ordem mostrada.

### Versão 0.1.1 — edição offline de playlists e correções de uso
- **Playlists sempre sincronizadas, também offline:** toda alteração (criar, renomear, adicionar,
  remover, mover, apagar) vira uma *intenção* numa fila no aparelho (Drift, esquema v2), aparece na
  hora e vai para o servidor em `POST /api/playlists/ops` quando ele estiver disponível. O servidor
  aplica as intenções sobre o estado atual, então mudanças feitas na web nesse meio-tempo se
  combinam. Conflitos reais viram avisos na Biblioteca: nome mudado nos dois lados ("Manter" /
  "Usar o meu"), playlist apagada aqui mas alterada lá ("Apagar mesmo assim") e alterações numa
  playlist apagada lá ("Recriar com minhas mudanças"). Reenvio seguro por `op_id`
  (`0008_playlist_ops.sql`). Ao sair da conta com alterações pendentes, o app avisa.
- **App fechava ao tocar (Android):** o ícone da notificação de reprodução era removido pela redução
  de recursos do build de release; `res/raw/keep.xml` mantém. Testado no emulador: tocar, trocar de
  música no meio, notificação com controles, tela de bloqueio e segundo plano.
- **Músicas de playlist ficavam como cache:** o arquivo baixado depois de a faixa entrar na playlist
  nascia como cache (e seria apagado em 48 h). Agora marcação e pasta (`music/cache` ↔
  `music/permanent`) mudam juntas (`app/storage/permanence.py`), e a API conserta o que estiver
  inconsistente ao subir.
- Usuários fictícios "User A/B" da migração 0004 removidos (`0009_remove_seed_users.sql`).

### Correção de concorrência no download (relatada no uso)
Dois cliques rápidos faziam o backend pegar o arquivo da faixa anterior e salvar com o id errado.
Agora o arquivo vem do item da fila do Deemix daquela faixa, a fila é limpa e as tags são
conferidas com ffprobe (título diferente → descarta e baixa do YouTube).
`python -m app.downloads.verify [--fix]` audita a base (reparou 7 arquivos trocados).

### Testes (último resultado)

| Suíte | Resultado |
|---|---|
| Flutter `flutter analyze` | ✅ sem problemas |
| Flutter `flutter test` | ✅ 242 |
| Flutter `integration_test` (flutter-tester) | ✅ 2 |
| Backend auth / playlists / history / resolve / catalog / downloads / images | ✅ 38 / 32 / 12 / 17 / 11 / 13 / 12 |
| E2E no Chrome (8080): sem sessão → login; busca; capas pelo proxy; recarregar mantém sessão | ✅ |
| APK release, AAB, Linux release | ✅ compilam |
| Windows | ⏳ compila só no CI (windows-latest) |
| Aparelho Android físico | ⏳ não testado |

---

## 4. Pendências conhecidas

| # | Pendência |
|---|---|
| 1 | Deemix falha em algumas faixas (ARL/versão); o YouTube cobre. |
| 2 | Qualidade de streaming escolhida no app não converte o bitrate no servidor. |
| 3 | Horas ouvidas são aproximadas (duração das faixas, não tempo real tocado). |
| 4 | Teste em aparelho Android físico (segundo plano, bateria, notificação, tela de bloqueio). |
| 5 | Proposta 8.7 da Documentação adotada em parte: Drift só nos apps; a web não guarda dados locais. |
| 6 | Apps Windows/Linux sem assinatura de código; Linux precisa de `libmpv` instalado. |
| 7 | Sem comando para remover usuário. |
| 8 | `backend/static/index.html` (página de teste antiga, não versionada) ainda é servida na porta interna da API. |
| 9 | Fonte reserva Roboto vem de fonts.gstatic.com (títulos com caracteres fora da Bricolage). |

---

## 5. Como rodar (desenvolvimento)

```bash
cd /home/lucas_amaral/Documentos/bergatrix/03-apps/bergastream
docker network create bergatrix-proxy        # uma vez
# .env local: STORAGE_PATH=./.data e COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml
docker compose up --build -d

# Web:  http://localhost:8080   API: http://localhost:8000   Health: http://localhost:8000/health
# Login local: demo / demo (só neste ambiente)

# Testes do backend (exemplo):
docker compose exec -T api python tests/test_auth.py

# Flutter (não há Flutter local; usar a imagem e devolver a posse dos arquivos):
cd frontend
docker run --rm -v "$PWD:/app" -v bergastream_pubcache:/root/.pub-cache -w /app \
  ghcr.io/cirruslabs/flutter:stable bash -c \
  "flutter pub get && flutter analyze && flutter test && \
   flutter test integration_test -d flutter-tester; chown -R $(id -u):$(id -g) /app"

# Regerar goldens (só quando a mudança visual for intencional):
#   ... flutter test --update-goldens test/app/gallery_golden_test.dart

# Regerar ícones:
docker run --rm -v "$PWD:/app" -w /app python:3.12-slim \
  sh -c "pip install -q pillow && python tool/make_icons.py"

# Build de debug da web (galeria em /#/dev/gallery; Android simulado em /?modo=android).
# Obs.: `flutter run -d web-server` NÃO serve: ele espera um depurador e fica em branco.
docker run --rm -v "$PWD:/src:ro" -v /tmp/bergastream_gallery:/out \
  -v bergastream_pubcache:/root/.pub-cache ghcr.io/cirruslabs/flutter:stable bash -c \
  "cp -r /src /app && cd /app && rm -rf build .dart_tool && flutter pub get && \
   flutter build web --debug && cp -r build/web/. /out && chown -R $(id -u):$(id -g) /out"
docker run -d --name bergastream-gallery -p 8081:80 \
  -v /tmp/bergastream_gallery:/usr/share/nginx/html:ro nginx:alpine
```

---

## 6. Código antigo

A versão anterior (backend com Alembic/routers, app Flutter antigo) foi removida deste stack no
commit da reescrita. Ela continua no histórico do git (`git show 8428d18:03-apps/bergastream/<caminho>`)
e na pasta `03-apps/bergastream02/` (fora do git).
