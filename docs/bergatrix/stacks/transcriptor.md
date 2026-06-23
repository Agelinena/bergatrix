# transcriptor — Serviço de transcrição de áudio/vídeo com Whisper (faster-whisper) acelerado por GPU, com UI web, fila e API REST v1

> **Categoria:** app | **Caminho:** `03-apps/transcriptor` | **Status:** Ativo (produção) — `transcriptor.${DOMAIN}`

## 🎯 Finalidade
Transcrever áudio e vídeo para texto em **português do Brasil**. O usuário pode enviar um arquivo (upload), colar uma **URL** (baixada via `yt-dlp`, ex. YouTube) ou apontar um **caminho local** (apenas via API). O backend FastAPI enfileira os jobs, fragmenta o áudio em blocos de 10 minutos com ffmpeg (PCM 16-bit, 16 kHz, mono) e transcreve com modelos **Whisper** (`small`, `medium`, `large-v3`) na GPU com quantização **int8**. Gera dois formatos: texto simples (`.txt` em parágrafos de ~300 chars) e legenda com timestamps (**WebVTT** `.vtt`). A UI mostra histórico por sessão (cookie assinado), progresso em tempo real via **WebSocket** e cronômetro por job. Há também uma **API autenticada por `X-API-Key`** para integração programática.

## 🧱 Stack tecnologica
- **Linguagem:** Python 3.10
- **API:** FastAPI + Uvicorn (`uvicorn[standard]`)
- **ASR:** **faster-whisper 1.2.1** + **CTranslate2 4.4.0** (Whisper small/medium/large-v3)
- **Agendamento:** APScheduler (cleanup + update do yt-dlp)
- **UI:** Jinja2 + Pico CSS (CDN) + JS vanilla
- **Segurança/limites:** `itsdangerous` (cookie assinado), `slowapi` (rate limiting), `aiofiles`, `python-multipart`
- **Mídia:** ffmpeg, yt-dlp
- **Base/GPU:** `nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04` (CUDA 12.1 / cuDNN8), runtime `nvidia`

## 📦 Servicos / Containers

| Aspecto | transcriptor |
|---|---|
| Build | context `.` (Dockerfile na raiz), `network: host` no build; base `nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04`; instala py3.10, ffmpeg, upgrade do yt-dlp; `PYTHONPATH=/app`; tz America/Sao_Paulo |
| Imagem | build local (sem imagem publicada) |
| Comando | `uvicorn main:app --host 0.0.0.0 --port 8000` |
| Portas | 8000 (interno, só via Traefik — sem mapeamento no host) |
| Volumes | `${TRANSCRIPTOR_DATA_DIR}transcriptor:/app/data` + 3 volumes de modelos (`models/whisper-small\|medium\|large-v3`) |
| Redes | `bergatrix-proxy` (external) |
| restart | unless-stopped |
| Healthcheck | **nenhum** definido |
| deploy/limites | GPU nvidia `count 1` (capabilities gpu) + `runtime: nvidia` + `NVIDIA_VISIBLE_DEVICES=all`; `shm_size 8gb`, `mem_limit 4g`, `memswap_limit 6g`; DNS 8.8.8.8/1.1.1.1 |
| Traefik | `Host(transcriptor.${DOMAIN})`, websecure, `tls=true` (serve o wildcard `*.daberga.com`, sem `certresolver`); middleware `transcriptor-buffering` (`maxRequestBodyBytes`/`memRequestBodyBytes` ~200MB para uploads grandes); service `:8000` |

Nota: apenas **um modelo Whisper fica carregado por vez** na VRAM (`ModelManager` singleton) para respeitar o limite da GPU (comentários citam **GTX 1060 6GB**). Variáveis `*_NUM_THREADS=1` e `cpu_threads=1`/`num_workers=1` limitam RAM/CPU.

## 🌐 Dominios / Roteamento
- `transcriptor.${DOMAIN}` → `:8000`, entrypoint `websecure`, `tls=true` (sem `certresolver`) — serve o **wildcard `*.daberga.com`** compartilhado do Traefik, não emite certificado individual (igual às demais stacks)
- Middleware de buffering próprio (`transcriptor-buffering`) para permitir uploads de até ~200MB
- Não há referência a Authentik — proteção apenas por sessão/cookie + rate limit

## 📐 Regras de negocio
- **Só PT-BR:** `language='pt'`, `task='transcribe'` (sem tradução); `initial_prompt` instrui transcrição fiel mantendo pontuação.
- **Um modelo por vez na VRAM:** `ModelManager` descarrega o anterior antes de carregar outro.
- **Transcrição serializada:** lock global de GPU (`transcription_lock`) — um job por vez.
- **Fragmentação:** áudio em blocos de **600s (10 min)** com ffmpeg; offset de tempo recalculado por chunk para timestamps lineares no VTT.
- **Quantização:** `int8` por padrão (forçado) para caber em ~6GB; VRAM estimada small 1GB / medium 2.5GB / large-v3 6GB.
- **Parâmetros adaptados:** large-v3 usa `beam_size=1`/`best_of=1`; demais `2`/`2`; `vad_filter` ativo (min_silence 400ms, speech_pad 100ms), `condition_on_previous_text=False`, `no_speech_threshold=0.6`, `temperature=0`.
- **Texto simples:** parágrafos de até ~300 chars.
- **Upload:** limite 500MB (`MAX_UPLOAD_BYTES`), validado por leitura em chunks de 1MB (HTTP 413 se exceder).
- **Rate limiting:** `/transcribe` 5/min, `/api/v1/submit*` 10/min (por IP via slowapi).
- **Modelo padrão** `small`; inválido → 400.
- **Retenção:** cleanup a cada 1h remove jobs/arquivos com timestamp > 30 dias; `/history` mostra só as últimas 24h.
- **yt-dlp** atualizado automaticamente todo dia às 03:00 (cron) e no build.
- **Isolamento por sessão (anti-IDOR):** usuário só acessa/baixa/deleta jobs cujo `user_id` (cookie assinado) seja o seu.
- **`submit-local` restrito:** caminho deve estar sob `ROOT_DIR` (`/media`) usando `os.sep` (evita bypass tipo `/mediaevil`); arquivo local não é removido após processar.
- **Anti-SSRF:** URLs só http/https; bloqueia localhost, 127., 0.0.0.0, 169.254., ::1, metadata.google/aws. `yt-dlp` com `--force-ipv4 --no-playlist -x --audio-format mp3`.
- **Erros sanitizados:** regex remove paths internos e trunca a 400 chars antes de expor.
- **Path traversal mitigado** com `os.path.basename` no nome enviado.
- **Secrets obrigatórios:** app aborta no startup (`RuntimeError`) se `API_KEY` ou `SECRET_KEY` não estiverem definidos.

## 🗄️ Modelo de dados
Persistência em **arquivo JSON** (sem banco relacional). `DB_FILE = /app/data/transcriptions.json`, dict `{job_id (UUID): {...}}`. Campos por job: `user_id` (dono assinado ou `api_user`), `original_filename` (≤200 chars), `model_name`, `status` (`queued → processing → transcribing → completed | failed | archived`), `timestamp`, `completed_at`, `timestamp_path` (`…_timestamp.vtt`), `simple_path` (`…_simple.txt`), `error` (sanitizado). Uploads temporários em `/app/data/uploads/`, chunks em `…/{job_id}/chunk_%03d.wav` (removidos após processar). Concorrência: `asyncio.Lock` (`db_lock` p/ escrita JSON, `transcription_lock` como lock global de GPU). Cache `DB_STATE_CACHE` + `LAST_DB_MTIME` para detectar mudanças e emitir updates via WebSocket.

## 🔌 Endpoints / API
**UI/Web:**
- `GET /` — página HTML (injeta `valid_models`)
- `GET /init-session` — cria/reutiliza `user_id` (UUID) em cookie assinado (httponly/secure/samesite=lax, 1 ano)
- `POST /transcribe` (202, 5/min) — `file` (≤500MB) OU `url`; valida sessão + modelo + URL anti-SSRF; enfileira
- `GET /history/{user_id}` — histórico das últimas 24h do próprio usuário (verifica cookie == user_id)
- `DELETE /job/{job_id}` (204) — remove job/arquivos do próprio usuário
- `GET /download/{job_id}/simple` e `/timestamp` — baixa `.txt`/`.vtt` (valida autoria + status `completed`)
- `WS /ws/{user_id}` — push de status; valida cookie contra `user_id` do path

**API v1 (`X-API-Key`):**
- `POST /api/v1/submit` (10/min) — job por URL
- `POST /api/v1/submit-file` (10/min) — job por upload (≤500MB)
- `POST /api/v1/submit-local` (10/min) — job por caminho local restrito a `ROOT_DIR`
- `GET /api/v1/result/{job_id}` — resultado (`timestamp_type=simple|timestamp`)

## 🔗 Integracoes externas
- **YouTube** e demais sites suportados pelo yt-dlp (download de áudio por URL)
- **Hugging Face** — `HF_TOKEN` no ambiente (provável para popular os volumes de modelos; em runtime carrega com `local_files_only=True`)
- **GPU NVIDIA** via runtime nvidia / CUDA 12.1 + cuDNN8
- **DNS** Google/Cloudflare no container; **CDN jsdelivr** (Pico CSS) no frontend

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (`01-network/traefik`): roteamento, TLS via wildcard `*.daberga.com` (`tls=true`, sem `certresolver`), entrypoint `websecure` e middleware de buffering
- **Rede `bergatrix-proxy`** (external)
- **`${TRANSCRIPTOR_DATA_DIR}`** (convenção de storage da Bergatrix), incluindo as pastas de modelos Whisper pré-baixados montadas como volumes

## 🔑 Variaveis de ambiente necessarias
- **Auth/segredos:** `API_KEY`, `SECRET_KEY`, `HF_TOKEN`
- **Domínio/dados:** `DOMAIN`, `TRANSCRIPTOR_DATA_DIR`
- **Modelo/recursos:** `COMPUTE_TYPE`, `ROOT_DIR`, `NVIDIA_VISIBLE_DEVICES`
- **Threads (limite de RAM/CPU):** `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS`, `NUMEXPR_NUM_THREADS`, `KMP_DUPLICATE_LIB_OK`

(Apenas nomes — nenhum valor é exibido. **Não há `.env.example` versionado** nesta stack.)

## 🗂️ Estrutura de codigo
Stack pequena e bem delimitada. Raiz: `docker-compose.yml`, `Dockerfile`, `requirements.txt`. Código em `app/`:
- `main.py` — FastAPI: lifespan/startup, validação de secrets, fila asyncio + worker `process_transcription`, `ConnectionManager` (WebSocket), `status_updater` (polling de mtime), scheduler APScheduler (cleanup + update yt-dlp), todos os endpoints; helpers de segurança (`sanitize_error`, `validate_url` anti-SSRF, cookie assinado).
- `model_manager.py` — `ModelManager` singleton (carrega/descarrega modelos na GPU), `VALID_MODELS`, `MODEL_PATHS`.
- `app/static` (`css/style.css`, `js/app.js` — sessão via `/init-session`, WebSocket com reconexão, render de histórico/progresso/cronômetro, abas simple/timestamp, copiar/baixar) e `app/templates/index.html` (Jinja2 + Pico CSS).
- Sem testes, sem migrations, sem banco relacional.

## 🛡️ Gestao de segredos
- Secrets só via env no compose (interpolados de `.env` não versionado: `API_KEY`, `SECRET_KEY`, `HF_TOKEN`). O app **aborta no startup** se faltar `API_KEY`/`SECRET_KEY`.
- `SECRET_KEY` usado pelo `itsdangerous` URLSafeSerializer (salt `transcriptor-user-id`) para assinar o cookie. `API_KEY` autentica `/api/v1/*` via `X-API-Key`.
- **Nenhum segredo hardcoded** nos arquivos analisados — só referências `${VAR}`. **Não há `.env.example`** documentando as variáveis.

## 🚧 Notas de evolucao / pendencias
- **Persistência em JSON único** com lock de processo único — não escala horizontalmente; há warning se o DB > 1000 itens (modelo de dados provisório).
- `status_updater` faz polling do mtime do DB a cada 2s — simples mas acoplado ao arquivo.
- Progresso por chunk só vai para o log de console (a UI reage só ao status `transcribing` estático, sem barra por chunk).
- `update_ytdlp` roda `pip install --upgrade yt-dlp` em runtime (cron 03:00) — muta o ambiente do container e não persiste após restart (já há upgrade no Dockerfile).
- `HF_TOKEN` no ambiente, mas runtime carrega `local_files_only=True` — token possivelmente residual/usado só para popular os volumes.
- **Sem healthcheck** no compose; **sem `.env.example`** versionado.
- `VALID_MODELS` fixos com paths fixos — adicionar modelo exige editar código, compose e baixar pesos.

## ❓ Perguntas em aberto
- Como/onde os pesos Whisper são baixados/populados nos volumes? `HF_TOKEN` sugere Hugging Face, mas não há script no repo.
- ~~Por que o `certresolver` é `production` aqui e `letsencrypt` nas demais stacks?~~ **Resolvido:** o app não usa mais `certresolver` — agora consome o **wildcard `*.daberga.com`** via `tls=true` (sem `certresolver`), igual às demais stacks. O wildcard é emitido uma única vez pela stack `01-network/traefik` (CA: Let's Encrypt).
- Qual GPU real? Comentários citam GTX 1060 6GB, mas o compose só reserva `count: 1` genérico.
- A API usa chave única compartilhada (`API_KEY`) sem usuários/escopos; jobs de API usam `user_id` fixo `api_user` — intencional para uso interno?
- Há intenção de proteger a UI com Authentik/SSO? Hoje o acesso é aberto (só sessão/cookie + rate limit).

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
