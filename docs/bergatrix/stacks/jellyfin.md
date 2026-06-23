# jellyfin — Centro de mídia self-hosted (Jellyfin + suite *arr) com automação própria de legendas PT-BR por IA, validação de áudio e reencode HEVC/NVENC

> **Categoria:** app | **Caminho:** `03-apps/jellyfin` | **Status:** Ativo

## 🎯 Finalidade
Stack completa de streaming/automação de mídia. O **Jellyfin** serve o acervo, o **Jellyseerr** (`catalogo`) recebe pedidos e a suite ***arr** (Sonarr/Radarr/Prowlarr/Bazarr/Recyclarr + qBittorrent/SABnzbd/FlareSolverr/torrent-indexer-br) baixa e organiza filmes e séries automaticamente. Em cima disso há **três serviços Python próprios** ("Legendarr"/Optimizer) que:
1. **Garantem legenda PT-BR** para todo item — primeiro via Bazarr (com refino de sincronia via ALASS) e, como fallback, **traduzindo uma faixa de texto via IA 100% local (Ollama)**;
2. **Validam** que cada arquivo tem o **áudio no idioma original** e que não está cortado/truncado — deletando + blocklistando + rebaixando releases ruins via API do Radarr/Sonarr;
3. **Reencodam** vídeos para **HEVC 10-bit via NVENC** (GPU NVIDIA) para economizar espaço; e
4. **Removem** downloads travados/falhos da fila do *arr.

Um **dashboard web** (FastAPI) expõe o acervo, status de legenda/otimização, logs do worker e ações manuais.

## 🧱 Stack tecnologica
- **Orquestração:** Docker Compose (13 serviços)
- **Mídia:** Jellyfin, Jellyseerr, Sonarr, Radarr, Prowlarr, Bazarr, Recyclarr, qBittorrent, SABnzbd, FlareSolverr, torrent-indexer (felipemarinho97)
- **Apps próprios (Python 3.10/3.11):** FastAPI + Uvicorn + Jinja2 + httpx + watchdog + python-dotenv
- **Mídia/encode:** FFmpeg/ffprobe, **NVENC (`hevc_nvenc`) / libx265**, **ALASS** (alinhamento de legenda)
- **IA local:** **Ollama** (`translategemma:4b`) para tradução de legendas
- **Frontend dashboard:** Tailwind CSS (CDN) + HTMX + Alpine.js
- **GPU:** NVIDIA runtime (GTX 1060, 1 chip NVENC, compartilhada com Ollama)

## 📦 Servicos / Containers
> Convenção: serviços **PÚBLICOS** = `websecure` + `tls=true` (servem o wildcard `*.daberga.com` compartilhado do Traefik, sem `certresolver` próprio); **LOCAIS** = middleware `internal-only@docker` (só Tailscale/rede interna). Todos usam `restart: unless-stopped` e a rede `media-network` (nome real `media-internal`); os expostos também entram em `bergatrix-proxy`.

| Serviço | Imagem/Build | Domínio (porta) | Acesso | GPU | Papel |
|---|---|---|---|---|---|
| jellyfin | `jellyfin/jellyfin` | `jellyflix.${DOMAIN}` (8096) | **Público** | ✅ | Servidor de mídia (transcode HW) |
| catalogo | `fallenbagel/jellyseerr` | `catalogo.${DOMAIN}` (5055) | **Público** | — | Portal de pedidos |
| legendarr-web | build `./app/web` (py3.11+ffmpeg) | `legendarr.${DOMAIN}` (8000) | Local | — | Dashboard custom |
| legendarr-worker | build `./app/worker` (py3.11+ffmpeg+alass) | — | — | ✅ | **Cérebro** da automação de legenda/validação |
| optimizer | build `./app/optimizer` (py3.10+ffmpeg) | — | — | ✅ | Reencode HEVC/NVENC |
| sonarr | `lscr.io/linuxserver/sonarr` | `sonarr.${DOMAIN}` (8989) | Local | — | Séries |
| radarr | `lscr.io/linuxserver/radarr` | `radarr.${DOMAIN}` (7878) | Local | — | Filmes |
| prowlarr | `lscr.io/linuxserver/prowlarr` | `prowlarr.${DOMAIN}` (9696) | Local | — | Indexers |
| bazarr | `lscr.io/linuxserver/bazarr` | `bazarr.${DOMAIN}` (6767) | Local | — | Legendas (etapa 1 do pipeline) |
| qbittorrent | `lscr.io/.../qbittorrent:version-4.6.0-r0` | `qbittorrent.${DOMAIN}` (8080) | Local | — | Cliente torrent (versão fixada) |
| sabnzbd | `lscr.io/linuxserver/sabnzbd` | `sabnzbd.${DOMAIN}` (8080) | Local | — | Cliente Usenet |
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr` | `flaresolverr.${DOMAIN}` (8191) | Local | — | Bypass de Cloudflare |
| torrent-indexer-br | `ghcr.io/felipemarinho97/torrent-indexer` | `torrent-indexer-br.${DOMAIN}` (7006) | Local | — | Indexer BR (depende de flaresolverr) |
| recyclarr | `ghcr.io/recyclarr/recyclarr` | — (background) | — | — | Sync de custom formats (TRaSH) |

Volumes: tudo ancorado em `${STORAGE_PATH}` (configs em `…/config/<serviço>`, mídia em `…/filmes`, `…/series`, downloads em `…/downloads`/`…/incomplete`). Os apps próprios compartilham `${STORAGE_PATH}/config/legendarr/{jobs,stats}`. `jellyfin` usa `security_opt: no-new-privileges` e DNS 8.8.8.8/1.1.1.1.

## 🌐 Dominios / Roteamento
- **Públicos (websecure + `tls=true`, wildcard `*.daberga.com`):** `jellyflix.${DOMAIN}`, `catalogo.${DOMAIN}`
- **Locais (middleware `internal-only@docker`):** `legendarr`, `sonarr`, `radarr`, `prowlarr`, `bazarr`, `qbittorrent`, `sabnzbd`, `flaresolverr`, `torrent-indexer-br`
- O webhook do *arr aponta para `legendarr.${DOMAIN}/api/webhook/arr`

## 📐 Regras de negocio

### Optimizer (reencode)
- **Pula** reencode se o vídeo já é HEVC (ffprobe).
- **Pré-filtro por bitrate** (tiering por LARGURA do vídeo): 2160p<12000kbps, 1080p<4000kbps, SD<1800kbps → pula (reencodar não encolheria).
- **Encode:** NVENC HEVC `main10`/`p010le`, preset `p6`, tune `hq`, `cq 28`, `spatial_aq`; B-frames e 10-bit só se a sondagem do `hevc_nvenc` suportar; fallback em cascata **NVENC 8-bit → libx265 software** (`crf 28`, preset `slow`).
- **Salvaguarda de integridade:** descarta o resultado se a duração do encode diferir do original em **>2s** (fonte truncada) → adiciona à *skiplist* + marca para re-download.
- **Só substitui in-place** se o arquivo novo for **menor**; senão mantém o original.
- **Skip-list persistente** (chaveada por tamanho do arquivo — rebaixar zera) para não queimar GPU repetindo falhas.
- **Recuperação de apagão de GPU** (`CUDA_ERROR_NO_DEVICE`): espera a GPU voltar (poll 15s até 600s) e refaz o NVENC; senão entra em cooldown global de 5min e adia.
- **Fila com deduplicação** (`DedupQueue`) + janela de supressão de 300s pós-conclusão para não reprocessar a própria saída; `MAX_WORKERS=1` (1 chip NVENC).
- **Scanner:** confirma que o arquivo parou de crescer (tamanho estável por 10s, debounce 60s) antes de processar — evita truncar imports em andamento.

### Legendarr-worker (legenda + validação)
- **Legenda:** pula se já há PT-BR interna/externa; se externa existe, ainda refina sincronia com ALASS. Pipeline **Bazarr** (`PATCH …/subtitles`, idioma `BAZARR_LANGUAGE=pb`, aguarda até 120s) → **ALASS** contra a legenda de texto embutida em inglês → se Bazarr falha, **tradução por IA**.
- **Tradução IA:** 100% local via Ollama (`translategemma:4b`), serializada (1 por vez na GPU via `TranslationQueue` + lock); formato numerado `[N]` com revisão por bloco (até 3 rodadas) e fallback posicional; descarta se cobertura < 90%; reusa timestamps originais ao remontar o SRT.
- **Rotulagem:** legendas de IA recebem `.AI.por.srt` (Jellyfin mostra "Português - AI"); as do Bazarr são normalizadas para `.por.srt`.
- **Validação de áudio:** garante áudio no idioma **original** (`originalLanguage` do *arr → ISO via `LANG_NAME_TO_CODES`); se ausente, **deleta o arquivo, blocklista o release (history/failed) e dispara nova busca**; modo seguro dá benefício da dúvida a faixas `und` (a menos que `AUDIO_CHECK_STRICT=true`).
- **Validação de duração:** arquivo com duração < `MIN_DURATION_PERCENT` (80%) do runtime do *arr → cortado/truncado → rejeitado e rebaixado.
- **Tag de exceção** `AUDIO_KEEP_TAG` (keep-audio) isenta um item da validação de áudio (mantém dublagem de propósito).
- **Guard anti-loop:** no máximo `MAX_REDOWNLOAD_ATTEMPTS` (5) re-downloads por mídia.
- **Cooldown progressivo:** revisita falhas a cada `RETRY_INTERVAL_HOURS` (1h) nas primeiras `MAX_FAST_RETRIES` (6); depois recua para `COOLDOWN_HOURS` (72h).
- **Auditoria no boot:** legenda PT-BR com cobertura (último timestamp ÷ duração) < `SUBTITLE_MIN_COVERAGE` (0.85) é apagada e refeita (forced é ignorada).
- **StalledMonitor:** remove da fila do *arr downloads `failed` imediatamente e `stalled`/`warning` após `STALLED_TIMEOUT_MINUTES` (5), sempre blocklistando e rebaixando outro release; ignora itens em import.
- **Arquitetura sem watchdog em tempo real no worker:** novos arquivos chegam via **webhook** do *arr (valida áudio/duração/tag ANTES de mexer na legenda) + varredura periódica (`SCAN_INTERVAL=3600s`), eliminando corrida com o validador.

## 🗄️ Modelo de dados
**Sem banco relacional próprio.** Estado em arquivos JSON/log no volume `${STORAGE_PATH}/config/legendarr` (montado como `/app/stats` e `/app/jobs`):
- `stats.json` (optimizer: por arquivo → `original_size`, `optimized_size`, `saved_bytes`, timestamp)
- `translation_stats.json` (entradas dedupe por filepath: status `success|failed|skipped|bazarr_alass|bazarr_raw|skipped_internal|skipped_external|success_alass_refine|aligned`, attempts, source_lang, source_codec, stream_index, model, timestamp)
- `audio_rejections.json` (contador de re-downloads por chave `movie:`/`episode:`/`path:`)
- `audio_verified.json` / `subtitle_verified.json` (caches `{path: mtime}`)
- `skiplist.json` (optimizer: `{filepath: {reason, size}}`)
- `requires_redownload.txt` (log append) e `worker.log` (RotatingFileHandler ~1MB×2)
- **Jobs:** arquivos JSON em `/app/jobs` (criados pela web, consumidos por polling de 5s pelo worker `JobProcessor`): `{id, type[translate|validate_and_translate|scan], filepath, force, stream_index, arr_event, status}`

Os demais serviços (Jellyfin, *arr) mantêm seus próprios SQLite internos sob `${STORAGE_PATH}/config/<serviço>`.

## 🔌 Endpoints / API (legendarr-web)
- `GET /` — dashboard HTML
- `GET /api/image?path=` — serve poster (restrito a `/media`)
- `GET /api/subtitles?filepath=` — lista streams de legenda (ffprobe)
- `GET /api/translation-stats` — resumo + últimas 50 traduções
- `POST /api/translate` — cria job de tradução (`filepath`, `stream_index`, `force`)
- `POST /api/bazarr-search` — aciona busca no Bazarr (`filepath`)
- `POST /api/scan` — agenda varredura completa
- `POST /api/webhook/arr` — recebe webhook On Download/On Import do *arr → job `validate_and_translate`
- `POST /api/refresh-cache` — força rescan do cache de mídia
- `GET /api/logs?lines=` — tail do `worker.log` (máx 2000 linhas)

## 🔗 Integracoes externas
- **Ollama** (LLM local em `http://ollama:11434`, `translategemma:4b`) — na rede `bergatrix-proxy`
- **TMDB/indexers** via Prowlarr e **providers de legenda** via Bazarr (configurados nas UIs)
- **Wildcard `*.daberga.com`** compartilhado do Traefik via `tls=true` (sem `certresolver`) — os domínios públicos consomem esse cert, não emitem o próprio; a CA continua sendo o Let's Encrypt
- **Usenet/torrents** via SABnzbd e qBittorrent
- **FlareSolverr** (bypass Cloudflare) usado pelo torrent-indexer-br e indexers do Prowlarr

## 🧩 Dependencias internas (Bergatrix)
- **Rede `bergatrix-proxy`** (Traefik/ingress) — compartilhada com toda a Bergatrix
- **Stack Ollama/OpenWebUI** (serviço `ollama` na `bergatrix-proxy`) — **dependência da tradução de legendas** do legendarr-worker
- **Middleware `internal-only@docker`** e o **wildcard `*.daberga.com`** (servido via `tls=true`, sem `certresolver` próprio — definidos na stack do Traefik)
- **Rede interna `media-network`** (driver bridge, nome real `media-internal`) conectando todos os serviços de mídia

## 🔑 Variaveis de ambiente necessarias
- **Infra/host:** `DOMAIN`, `STORAGE_PATH`, `PUID`, `PGID`, `TZ`, `LOG_LEVEL`, `NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES`
- **IA/tradução:** `LOCAL_AI_URL`, `TRANSLATOR_MODEL`, `OLLAMA_NUM_CTX`, `OLLAMA_TIMEOUT`, `TRANSLATOR_TEMPERATURE`, `BLOCK_RETRANSLATE_ROUNDS`, `TRANSLATE_BATCH_BLOCKS`, `TRANSLATION_MIN_BLOCK_COVERAGE`, `AI_SUBTITLE_LABEL`
- **Legenda/validação:** `SCAN_INTERVAL`, `RETRY_INTERVAL_HOURS`, `MAX_FAST_RETRIES`, `COOLDOWN_HOURS`, `BAZARR_URL`, `BAZARR_API_KEY`, `BAZARR_LANGUAGE`, `BAZARR_WAIT_SECONDS`, `RADARR_URL`, `RADARR_API_KEY`, `SONARR_URL`, `SONARR_API_KEY`, `AUDIO_CHECK_STRICT`, `MAX_REDOWNLOAD_ATTEMPTS`, `AUDIO_KEEP_TAG`, `MIN_DURATION_PERCENT`, `SUBTITLE_MIN_COVERAGE`, `STALLED_TIMEOUT_MINUTES`, `STALLED_CHECK_INTERVAL`
- **Optimizer:** `MAX_WORKERS`, `RESCAN_INTERVAL`, `OPTIMIZER_SKIP_BITRATE_2160P/1080P/SD`, `OPTIMIZER_SKIPLIST_FILE`, `OPTIMIZER_GPU_POLL`, `OPTIMIZER_GPU_TIMEOUT`, `OPTIMIZER_GPU_COOLDOWN`
- **torrent-indexer-br:** `FLARESOLVERR_ADDRESS`, `LONG_LIVED_CACHE_EXPIRATION`, `CACHE_EXPIRATION`, `REDIS_URI` (vazio = cache em memória), `PORT`

(Apenas nomes — nenhum valor é exibido.)

## 🗂️ Estrutura de codigo
`docker-compose.yml` define os 13 serviços. `app/` contém 3 imagens custom buildadas localmente:
- **`app/web`** (`legendarr-web`): `main.py` (rotas + cache de mídia), `bazarr.py` (cliente Bazarr), `templates/index.html` (Tailwind/HTMX/Alpine), `static/style.css`.
- **`app/worker`** (`legendarr-worker`): `main.py` (orquestra); `core/pipeline.py` (**cérebro** do fluxo legenda+validação); `core/scanner.py` (varredura + auditorias); `core/translator.py` (tradução por chunks/blocos via Ollama); `core/translation_queue.py` (fila serializada de IA); `core/translation_stats.py`; `core/bazarr.py` e `core/arr.py` (clientes de API); `core/job_processor.py`; `core/stalled_monitor.py`; `core/utils.py` (ffprobe/ffmpeg/SRT).
- **`app/optimizer`**: `main.py` (threads de worker + rescan periódico); `core/processor.py` (pipeline NVENC/x265 com heal + recuperação de GPU); `core/scanner.py` (watchdog com estabilização); `core/job_queue.py` (`DedupQueue`); `core/skiplist.py`; `core/stats_manager.py`.

Dockerfiles: optimizer `python:3.10-slim`, worker/web `python:3.11-slim`, todos com ffmpeg (worker também baixa o binário ALASS).

## 🛡️ Gestao de segredos
- Segredos via `.env` (não versionado); o repo versiona só `.env.example` com **placeholders** (`your_bazarr_api_key_here`, etc). API keys (`BAZARR/RADARR/SONARR_API_KEY`) passadas a legendarr-web/worker via `environment`.
- Os demais serviços guardam suas chaves nos configs sob `${STORAGE_PATH}/config` (fora do repo). **Nenhum segredo real encontrado commitado.**
- Recomendação: manter o `.env` real fora do versionamento e rotacionar qualquer chave exposta em logs.

## 🚧 Notas de evolucao / pendencias
- **Refatoração em andamento (git status):** `processor.py`, `scanner.py`, `main.py`, `docker-compose.yml` modificados + novos `core/job_queue.py` e `core/skiplist.py` não rastreados (DedupQueue + SkipList + recuperação de apagão de GPU). Commits recentes focam em estabilidade NVENC (probe, fallbacks, preferência por GPU 0, retry após apagão, logging de stderr do ffmpeg).
- Comentário no `worker/main.py` cita `OPENROUTER_API_KEY`, mas o Translator atual usa **apenas Ollama local** — comentário desatualizado.
- `watchdog` ainda no `requirements.txt` do worker apesar de não ser mais usado em tempo real (substituído por webhook + scan).
- `utils.check_existing_subtitle()` parece legado (`find_pt_subtitle` é a função canônica).
- `.pyc` cpython-314 no host vs Dockerfiles 3.10/3.11 — pycache de execução local.
- `torrent-indexer-br` com `REDIS_URI` vazio (cache em memória) — possível evolução para cache persistente.
- **Optimizer reescreve arquivos in-place** (`os.remove` + `shutil.move`) — destrutivo; depende do check de duração/tamanho como única salvaguarda.

## ❓ Perguntas em aberto
- Onde está definido o serviço `ollama` (qual stack) e o `translategemma:4b` já está pré-puxado? A tradução depende dele online na `bergatrix-proxy`.
- O middleware `internal-only@docker` e o wildcard `*.daberga.com` (consumido via `tls=true`, sem `certresolver` próprio) são definidos no Traefik? (não estão neste compose).
- O webhook do *arr (`POST /api/webhook/arr`) precisa ser configurado manualmente nas UIs — está documentado em algum lugar?
- Não há README documentando setup/ordem de subida dos serviços.
- Política real de contenção da GPU GTX 1060 (1 chip NVENC) compartilhada entre optimizer, worker, Jellyfin e Ollama — além de `MAX_WORKERS=1`?
- O volume `./temp` do optimizer é relativo ao diretório do compose no host — confirmar que existe/é apropriado em produção.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
