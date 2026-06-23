# berga-news — Agregador de RSS auto-hospedado que agrupa artigos por tópico com IA e gera digests resumidos em português

> **Categoria:** app | **Caminho:** `03-apps/berga-news` | **Status:** Ativo (`news.daberga.com`)

## 🎯 Finalidade
Leitor/digest de notícias pessoal e multiusuário. Um **worker** coleta periodicamente artigos de feeds RSS (globais e por usuário), faz *prefetch* do conteúdo completo dos artigos para leitura quase instantânea e, **duas vezes ao dia (07:00 e 18:00 America/Sao_Paulo)**, executa um pipeline de *digest*: agrupa artigos não-clusterizados por evento/assunto via chamada a um LLM (clustering em JSON) e gera, para cada cluster, um resumo de 2–3 frases em português brasileiro. A **API FastAPI** serve uma interface web/PWA (Jinja2 + Tailwind via CDN) onde o usuário vê o digest mais recente, navega artigos por feed, marca lidos/não-lidos, lê o artigo em *reader mode* (extração com trafilatura/readability) e gerencia seus feeds. O **admin** gerencia usuários, feeds globais e pode disparar um digest manualmente. Acessível em `news.${DOMAIN}` atrás do Traefik com middleware `internal-only@docker`.

## 🧱 Stack tecnologica
- **Linguagem:** Python 3.12 (`python:3.12-slim`)
- **API:** FastAPI 0.115.6 + Uvicorn 0.32.1 (`uvicorn[standard]`), `python-multipart` 0.0.20
- **Persistência:** PostgreSQL 16 (`postgres:16-alpine`) via SQLAlchemy 2.0.36 **síncrono** (`psycopg2-binary` 2.9.10) — sem Alembic
- **Agendamento:** APScheduler 3.10.4 (`BackgroundScheduler`) — **apenas no worker**
- **UI:** Jinja2 3.1.4 (server-side) + Tailwind CSS via CDN + PWA (`manifest.json` + service worker network-first)
- **Coleta/extração:** feedparser 6.0.11, trafilatura 2.0.0, readability-lxml 0.8.1 (`lxml[html_clean]` 5.3.0), httpx 0.28.1
- **Auth:** bcrypt 4.2.1 (hash de senha), sessão por cookie persistida em Postgres
- **IA:** OpenAI SDK 1.58.1 como cliente OpenAI-compatible (Gemini/OpenAI/OpenRouter)

## 📦 Servicos / Containers

| Aspecto | berganews-api | berganews-worker | berganews-db |
|---|---|---|---|
| Build/Imagem | build `./api` (uvicorn `:8000`) | build `./worker` (`python main.py`) | `postgres:16-alpine` |
| Portas | 8000 (interno, via Traefik) | nenhuma | nenhuma |
| Volumes | — | — | `${BERGANEWS_DATA_DIR}postgres:/var/lib/postgresql/data` |
| Redes | `berganews-internal`, `bergatrix-proxy` | `berganews-internal`, `bergatrix-proxy` | `berganews-internal` |
| depends_on | `berganews-db` (service_healthy) | `berganews-db` (service_healthy) | — |
| restart | unless-stopped | unless-stopped | unless-stopped |
| Healthcheck | `urlopen /health` (30s/5s/3, start 15s) | existência de `/tmp/.worker_alive` (60s/5s/3, start 30s) | `pg_isready -U berganews` (10s/5s/5, start 30s) |
| Traefik | `Host(news.${DOMAIN})`, websecure, TLS letsencrypt, lb `:8000`, mw `internal-only@docker` | — | — |

Notas: a **API** é um web app FastAPI/Jinja servindo UI/PWA (`docs_url`/`redoc_url` desabilitados). O **worker** é um processo de scheduler sem servidor HTTP nem labels Traefik; está na `bergatrix-proxy` presumivelmente apenas para *egress* às APIs de IA externas. O `berganews-db` fica só na rede interna (sem portas publicadas).

## 🌐 Dominios / Roteamento
- `news.${DOMAIN}` (`news.daberga.com`) → `berganews-api:8000`
- Entrypoint `websecure`, `tls=true`, `certresolver=letsencrypt`
- Middleware: `internal-only@docker` (definido na stack do Traefik) — restringe à rede interna/Tailscale
- O cookie de sessão usa `secure=True`, exigindo HTTPS

## 📐 Regras de negocio
- **Escopos de feed:** pessoais (`owner_id` = usuário) e globais (`owner_id NULL`, geridos por admin); unicidade por índice `UNIQUE (COALESCE(owner_id,-1), url)`.
- **Visão do usuário:** sempre feeds próprios + globais ativos; estado de leitura (`article_reads`) é **por usuário**.
- **Coleta (worker):** todos os feeds ativos a cada `FETCH_INTERVAL_MINUTES` (default 30) usando ETag/`If-None-Match` e `Last-Modified`/`If-Modified-Since`; trata 304 (não modificado), status fora de 200/301/302 como erro, e feed vazio sem inserir. Um fetch inicial roda no startup do worker.
- **Deduplicação de artigos** por `(feed_id, guid)`, onde `guid = entry.id || entry.link || entry.title`; guid/título vazios são ignorados; descrição limpa de HTML (regex) e truncada em 500 chars; título 500, autor 200.
- **Prefetch de conteúdo:** após cada fetch, baixa via httpx e extrai (trafilatura → fallback readability) o HTML de até `PREFETCH_LIMIT=30` artigos das últimas `PREFETCH_AGE_HOURS=48h` ainda sem cache; commit por artigo; falhas gravadas em `article_contents.fetch_error`.
- **Digest:** cron **07:00 e 18:00 America/Sao_Paulo** (dois jobs) + trigger manual via admin (verificado a cada 60s lendo o setting `pending_digest_trigger`); cada execução cria um `DigestRun`.
- **Janela do digest:** filtra artigos não-clusterizados por `fetched_at >= now - DIGEST_WINDOW_HOURS` (default 12) e `Feed.active`; usa `fetched_at` (não `published_at`) de propósito (datas de RSS podem ser antigas).
- **Fallback do digest:** se a janela estiver vazia mas houver não-clusterizados, processa até 80 artigos mais recentes por `published_at` (2 chunks de 40) para conservar cota de IA. Sem artigos → run termina `done` com 0 clusters.
- **Clustering (LLM):** chunks de `CHUNK_SIZE=40` com `INTER_CHUNK_DELAY=5s` (anti-RPM); até 3 tentativas de parse de JSON por chunk (strip de cercas ```); artigos isolados vão para o cluster "Outros"; com múltiplos chunks, segunda chamada ao LLM (`_merge_labels`) mescla labels quase-duplicadas.
- **Resumo:** 2–3 frases em PT-BR por cluster (temperatura 0.2 no worker), preservando atribuição de fonte entre parênteses; falha grava string vazia.
- **Cleanup diário 03:00 America/Sao_Paulo:** apaga artigos órfãos (`cluster_id NULL`) com `fetched_at > 7 dias` e `digest_runs` com `started_at > 30 dias`.
- **Sessão:** 30 dias (cookie httponly/secure/samesite=lax), validada contra `sessions` (`expires_at > now`) a cada request.
- **Seed automático:** no startup da API, sem usuários → cria admin a partir de `ADMIN_USERNAME`/`ADMIN_PASSWORD` (defaults `admin`/`changeme`).
- **Admin de usuários:** se senha em branco, gera `secrets.token_urlsafe(12)`; a senha (gerada ou informada) é exibida na URL de redirect (`?msg=...senha:...`) — ⚠️ ver Notas de evolução.
- **Troca de credenciais:** senha exige senha atual + nova ≥8 chars + confirmação; username ≥3 chars e único; `logout-all` revoga todas as sessões exceto a atual.
- **Coordenação API↔worker** por flags na tabela `settings` (`pending_digest_trigger` é lido pelo worker; `refresh_feed_ids` é escrito pela API mas **não** lido por nenhum job) — não há fila/mensageria.
- **Abstração de LLM:** cliente único compatível com OpenAI SDK; provider selecionável (`gemini` default | `openai` | `openrouter`) via `LLM_PROVIDER`/`LLM_MODEL` (default `gemini-2.0-flash`); `worker/llm.py` trata rate-limit 429 (até 5 tentativas, lê `retryDelay`+3s, aborta cedo se a cota diária do Gemini esgotar); `api/llm.py` **não** trata 429.

## 🗄️ Modelo de dados
PostgreSQL 16 via SQLAlchemy `DeclarativeBase` (síncrono). Schema criado por `Base.metadata.create_all` + `CREATE INDEX/UNIQUE INDEX IF NOT EXISTS` no `init_db` — **sem Alembic/migrations**.

- **users** — `id`, `username` único NOT NULL, `password_hash` (bcrypt) NOT NULL, `email`, `role` default `user`, `created_at`.
- **sessions** — `id` (token uuid4 texto) PK, `user_id` FK CASCADE, `expires_at`, `created_at` — sessão de 30 dias.
- **feeds** — `id`, `owner_id` FK users CASCADE *nullable* (NULL = global), `url` NOT NULL, `title`, `site_url`, `category`, `active` default true, `last_fetched_at`, `last_fetch_status`, `last_etag`, `last_modified`, `created_at`.
- **articles** — `id`, `feed_id` FK feeds CASCADE NOT NULL, `guid` NOT NULL, `title` NOT NULL, `description`, `url` NOT NULL, `author`, `published_at`, `fetched_at` default utcnow, `cluster_id` FK clusters SET NULL.
- **digest_runs** — `id`, `window_start/window_end` NOT NULL, `started_at`, `finished_at`, `articles_processed`, `clusters_created`, `status` default `running` → `done|error`, `error_msg`.
- **clusters** — `id`, `digest_run_id` FK CASCADE NOT NULL, `label` NOT NULL, `summary`, `article_count`, `created_at`.
- **article_contents** — `article_id` PK/FK CASCADE, `html` NOT NULL, `fetch_error`, `fetched_at` (cache do reader mode).
- **article_reads** — `user_id`+`article_id` PK composto (ambos FK CASCADE), `read_at` (estado lido por usuário).
- **settings** — `key` PK, `value` (flags de coordenação API→worker).
- **Índices:** `UNIQUE idx_feeds_unique (COALESCE(owner_id,-1), url)`, `idx_articles_published (published_at DESC)`, `idx_articles_cluster`, `idx_articles_feed`, `idx_article_reads_user`.

## 🔌 Endpoints / API
- `GET /health` (sem auth, healthcheck)
- **Auth:** `GET /login`, `POST /login` (bcrypt; cookie `session_id` 30 dias), `POST /logout`
- **Digest:** `GET /` (→ 303 `/digest/latest`), `GET /digest/latest?category=`, `GET /digest/{run_id}?category=`, `GET /digest/{run_id}/cluster/{cluster_id}`
- **Artigos:** `GET /articles?feed_id=&show=all|unread&page=` (PAGE_SIZE=50), `POST /articles/{id}/toggle-read` (JSON `{read}`), `POST /articles/mark-all-read?feed_id=`
- **Reader:** `GET /reader/{id}` (auto-marca lido), `GET /reader/{id}/fetch?force=` (extrai+cacheia, retorna `{html, error}`)
- **Feeds:** `GET /feeds`, `POST /feeds` (pessoal), `POST /feeds/{id}/delete` (só dono), `POST /feeds/{id}/refresh` (escreve `refresh_feed_ids`; dono ou admin)
- **Settings** (prefix `/settings`): `GET /settings`, `POST /settings/username` (≥3, único), `POST /settings/password` (≥8 + confirmação + atual), `POST /settings/logout-all`
- **Admin** (prefix `/admin`, `require_admin`): `GET /admin`, `POST /admin/users`, `POST /admin/users/{id}/delete` (bloqueia auto-deleção), `POST /admin/feeds` (global), `POST /admin/feeds/{id}/delete` (só globais), `POST /admin/digest/trigger`

## 🔗 Integracoes externas
- **Google Gemini API** (default, `…/v1beta/openai/`, `gemini-2.0-flash`) via OpenAI-compatible SDK — clustering e resumo
- **OpenAI API** (`api.openai.com/v1`) e **OpenRouter** (`openrouter.ai/api/v1`) — providers alternativos
- **Feeds RSS/Atom externos** (feedparser) e **sites de notícias** (httpx) para prefetch/reader mode
- **Tailwind CSS via CDN** (`cdn.tailwindcss.com`) no `base.html`

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (`01-network/traefik`): TLS Let's Encrypt (`certresolver=letsencrypt`), rede externa `bergatrix-proxy`
- **Middleware `internal-only@docker`** (definido na stack do Traefik) — restringe acesso à `berganews-api`
- **Rede `bergatrix-proxy`** (`external: true`)
- **Postgres próprio** (`berganews-db`) na rede interna `berganews-internal` (`internal: true`) — **não** usa banco compartilhado
- **Não** integra Authentik (auth própria por sessão+cookie em DB); **não** usa LiteLLM (vai direto ao provedor de IA)

## 🔑 Variaveis de ambiente necessarias
- **Domínio/dados:** `DOMAIN`, `BERGANEWS_DATA_DIR`
- **Banco:** `POSTGRES_PASSWORD` (`POSTGRES_USER`/`POSTGRES_DB` fixos como `berganews` no compose; `DATABASE_URL` derivada no compose)
- **Auth/seed:** `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `SECRET_KEY` (passada mas **sem uso no código**)
- **IA:** `LLM_PROVIDER`, `LLM_MODEL`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`
- **Coleta/digest:** `FETCH_INTERVAL_MINUTES`, `DIGEST_WINDOW_HOURS`
- **Definidas no compose:** `TZ` (`America/Sao_Paulo`)

(Apenas nomes — nenhum valor é exibido.)

## 🗂️ Estrutura de codigo
Dois serviços Python (build local `api/` e `worker/`) + Postgres.

- **`api/`** (FastAPI): `main.py` (app com docs desabilitados, exception handlers `LoginRequired`→redirect `/login` e `AdminRequired`→403, mount `/static`, 7 routers, `GET /health`, startup `init_db` + `seed_admin`); `auth.py` (sessões por cookie em Postgres, bcrypt, `require_login`/`require_admin`, `seed_admin`); `db.py` (modelos + `init_db` + `get_db`); `llm.py` (cliente LLM síncrono **sem** tratamento de 429); `routers/` (auth, digests, articles, reader, feeds, settings, admin); `templates/` (Jinja2); `static/` (`manifest.json`, `sw.js`, ícones 192/512).
- **`worker/`** (processo standalone): `main.py` (APScheduler tz America/Sao_Paulo: fetch/digest×2/check_trigger/cleanup/alive + `_run_digest`; loop infinito); `fetcher.py` (RSS com ETag/Last-Modified); `content_prefetch.py` (prefetch via httpx + trafilatura/readability); `clusterer.py` (clustering por LLM em chunks de 40 + merge de labels); `summarizer.py` (resumo por cluster); `llm.py` (cliente LLM **com** tratamento de 429); `db.py` (`get_session()`, `pool_size=3`).
- ⚠️ `db.py` e `llm.py` são **duplicados** entre `api/` e `worker/` (sem pacote compartilhado).

## 🛡️ Gestao de segredos
- Segredos injetados via `env_file: .env` (o `.env` real **não** é versionado — só `.env.example` com placeholders). `DATABASE_URL` é construída no compose interpolando `${POSTGRES_PASSWORD}`.
- Senhas de usuário com hash **bcrypt**; sessões com tokens uuid4 em Postgres. Chaves de IA ficam só em env.
- O `.env.example` traz placeholders fracos (`POSTGRES_PASSWORD`, `ADMIN_PASSWORD`, `SECRET_KEY`) que **devem** ser trocados em produção. Cookie de sessão `secure=True`.
- ⚠️ **Risco:** `POST /admin/users` expõe a senha (gerada/informada) na querystring do redirect, podendo vazá-la em logs de proxy/histórico. **Nenhum segredo real encontrado commitado.**

## 🚧 Notas de evolucao / pendencias
- **Sem migrations:** schema só por `create_all` + `CREATE INDEX IF NOT EXISTS` — mudanças de coluna em produção seriam manuais.
- **Código duplicado:** `api/db.py` vs `worker/db.py` e `api/llm.py` vs `worker/llm.py` quase idênticos (o próprio comentário admite "identical to api/db.py") — risco de divergência.
- **Tratamento de IA inconsistente:** worker trata 429 com backoff; api não (mas a api não chama IA hoje).
- **`SECRET_KEY`** consta no `.env.example` e vai ao container, mas **não é referenciada no código** — vestigial ou reservada (sessões usam uuid4).
- **`refresh_feed_ids`** é escrito pela API mas nenhum job do worker consome — funcionalidade incompleta.
- **Senha em querystring** no redirect de criação de usuário — corrigir.
- **PWA:** `sw.js` é network-first sem cache pré-populado — offline só funciona para recursos já visitados.
- **Tailwind via CDN** em runtime — dependência externa não recomendada para produção.
- **Dívida leve:** `@app.on_event('startup')` (deprecado) e `datetime.utcnow()` (deprecado no 3.12).

## ❓ Perguntas em aberto
- Onde/como o middleware `internal-only@docker` é definido e qual o escopo de acesso (VPN? IP allowlist?).
- O worker realmente precisa da rede `bergatrix-proxy` ou bastaria a interna? (presumivelmente egress a APIs de IA).
- A flag `refresh_feed_ids` será implementada no worker ou removida da UI?
- Qual o destino pretendido de `SECRET_KEY` (CSRF, assinatura de cookie, criptografia)?
- Extrair `db.py`/`llm.py` para um pacote compartilhado para eliminar a duplicação?
- Não há README na stack — falta documentação de operação (backup do volume Postgres, rotação de chaves de IA, troca de provider).
- A exposição da senha de novo usuário na URL é aceitável ou deve ser corrigida?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
