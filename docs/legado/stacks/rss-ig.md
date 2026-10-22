# rss-ig — Scraper de Instagram auto-hospedado que converte perfis monitorados em feeds RSS 2.0 com mídia local

> **Categoria:** app | **Caminho:** `03-apps/rss-ig` | **Status:** running

## 🎯 Finalidade
Permite acompanhar perfis públicos do Instagram através de um leitor de RSS, sem precisar usar o app oficial. Um worker em background faz login com uma conta secundária dedicada, busca periodicamente os posts novos dos perfis cadastrados, baixa a mídia (imagens, vídeos e carrosséis) para o disco local e grava os metadados em SQLite. Um gerador de RSS produz um arquivo XML por perfil (cobrindo os últimos 30 dias) cujas URLs de mídia apontam de volta para o próprio FastAPI, que serve os feeds e os arquivos como estáticos. Há ainda um dashboard web simples para gerenciar perfis, disparar coletas manuais e ver estatísticas. O objetivo é centralizar o consumo de conteúdo de Instagram em um leitor RSS dentro do homelab, com retenção e limpeza automáticas.

## 🧱 Stack tecnologica
- **Linguagem:** Python 3.12 (imagem base `python:3.12-slim`)
- **API:** FastAPI (>=0.111) + Uvicorn[standard] (>=0.30); `python-multipart` (>=0.0.9) consta no requirements mas não é usado pelos endpoints atuais
- **Scraping:** instaloader (>=4.13) para autenticação e leitura de perfis/posts; download de mídia feito manualmente com httpx (>=0.27)
- **Agendamento:** APScheduler (>=3.10,<4.0), `BackgroundScheduler`
- **Geração de RSS:** feedgen (>=0.9.0), saída RSS 2.0
- **Persistência:** SQLite em modo WAL (`foreign_keys=ON`, `busy_timeout=5000`, conexões thread-local)
- **Dashboard:** HTML/CSS/JavaScript vanilla (SPA simples, sem framework)
- **Infra:** Docker / docker-compose; Traefik como reverse proxy servindo o wildcard compartilhado `*.daberga.com` (CA Let's Encrypt)

## 📦 Servicos / Containers

| Aspecto | instaloader-worker | instaloader-api |
|---|---|---|
| Build | `./worker` (slim + ca-certificates; `CMD python main.py`) | `./api` (slim + ca-certificates; `CMD uvicorn main:app --host 0.0.0.0 --port 8000`) |
| Portas | nenhuma | 8000 (interno; sem publish no host, só via Traefik) |
| Volumes | `${INSTALOADER_DATA_DIR}:/data` | `${INSTALOADER_DATA_DIR}:/data` (mesmo volume) |
| Redes | `instaloader-internal` (internal), `instaloader-egress` (bridge) | `instaloader-internal` (internal), `bergatrix-proxy` (external) |
| depends_on | — | `instaloader-worker` (condition: service_healthy) |
| restart | unless-stopped | unless-stopped |
| Healthcheck | verifica `/data/.worker_alive` (interval 60s, timeout 5s, retries 3, start_period 30s) | `urlopen http://localhost:8000/health` (interval 30s, timeout 5s, retries 3, start_period 15s) |
| deploy (GPU/limites) | nenhum | nenhum |
| Traefik | não exposto (sem labels) | `Host(\`rssig.${DOMAIN}\`)`, websecure, `tls=true` (wildcard `*.daberga.com`), lb port 8000, middleware `internal-only@docker` |

Notas: o worker está na rede de egress (bridge) para alcançar a internet/Instagram; a API **não** está na egress (só internal + proxy). Ambos compartilham o mesmo volume `/data` e o mesmo arquivo SQLite. O marcador `.worker_alive` usado no healthcheck do worker é tocado a cada 1 minuto por um job do APScheduler.

## 🌐 Dominios / Roteamento
- Host efetivo (compose): `rssig.${DOMAIN}` — entrypoint `websecure`, `tls=true` (sem `certresolver`; consome o wildcard `*.daberga.com` compartilhado do Traefik, não emite cert individual), balanceado para a porta 8000 do container.
- Middleware aplicado: `internal-only@docker` (definido na stack do Traefik) — restringe o acesso à rede interna.
- Rede de exposição: `bergatrix-proxy` (`external: true`), declarada via `traefik.docker.network`.
- **Divergência:** o `.env.example` documenta o feed em `rss-ig.${DOMAIN}` (com traço) e define `RSS_BASE_URL=https://rss-ig.example.com`, enquanto o roteamento real é `rssig.` (sem traço). `RSS_BASE_URL` precisa ser corrigido para o host real, senão as URLs de mídia nos feeds quebram.

## 📐 Regras de negocio
- **Autenticação:** login com conta secundária dedicada (`IG_USERNAME`/`IG_PASSWORD`). A sessão é carregada de `${DATA_DIR}/session/session-<IG_USERNAME>`; se ausente ou em erro de conexão, faz login e salva o arquivo. Em `LoginRequiredException` durante um fetch, o arquivo de sessão é deletado para reautenticar no próximo run. O worker encerra com `exit(1)` no startup se faltar usuário/senha.
- **Janela de coleta:** `SCRAPE_DAYS` (default 7). Itera `get_posts()` e dá `break` no primeiro post mais antigo que o cutoff; posts já existentes (por shortcode) são pulados.
- **Anti-bloqueio:** no job agendado os perfis são embaralhados e processados sequencialmente, com delay aleatório de 30–180s entre eles; o intervalo entre execuções é `SCHEDULE_INTERVAL_HOURS` (default 2h), com `misfire_grace_time=600` e `max_instances=1`.
- **Zero-overlap:** cada perfil tem um `threading.Lock` individual; `fetch_profile` faz `acquire(blocking=False)` e pula se já houver coleta em andamento (agendada ou manual) para o mesmo usuário.
- **Fetch manual:** a API insere uma linha em `manual_fetch_queue` (status `pending`); o worker faz polling a cada 30s, marca `running`, dispara o fetch em thread daemon e marca `done`/`error`. Itens `running` órfãos são resetados para `pending` no startup do worker.
- **Download de mídia:** feito manualmente via `httpx.stream` (instaloader com todos os `download_*` desativados), com headers `Referer` do Instagram e `User-Agent` (de `IG_USER_AGENT` ou fallback Chrome). Suporta carrossel (`GraphSidecar`), vídeo e imagem; arquivos já presentes não são rebaixados (idempotência por shortcode); arquivos parciais são removidos em falha.
- **post_type:** `GraphSidecar` → `carousel`; `is_video` → `reel`; senão → `post`.
- **Retenção:** job de cleanup diário às 03:00 (`America/Sao_Paulo`) remove a mídia e as linhas de posts com mais de 30 dias e reconstrói os feeds afetados. Os feeds RSS cobrem sempre os últimos 30 dias, independentemente de `SCRAPE_DAYS`.
- **RSS:** RSS 2.0 via feedgen, `language=pt-BR`. Título do item = primeira linha não vazia da legenda truncada em 120 chars (fallback `<Tipo> by @user`); `description` é HTML com `<img>`/`<video>` apontando para `RSS_BASE_URL/media/...` e a legenda escapada; `enclosure` aponta para a primeira mídia com `length=0`; usa `published`/`updated` (semântica Atom em feed RSS).
- **Estatísticas:** `storage_bytes` por perfil é recalculado somando o tamanho de todos os arquivos sob `media/<username>` após cada fetch; `post_count` reflete os posts dos últimos 30 dias.

## 🗄️ Modelo de dados
SQLite em `${DATA_DIR}/instaloader.db` (WAL). Schema criado via `CREATE TABLE IF NOT EXISTS` (sem migrações).

- **profiles** — `id` PK, `username` UNIQUE NOT NULL, `added_at`, `last_fetch_at`, `last_fetch_status`, `post_count` (default 0), `storage_bytes` (default 0).
- **posts** — `id` PK, `profile_username` NOT NULL (FK → `profiles.username` ON DELETE CASCADE), `post_shortcode` UNIQUE NOT NULL, `post_type` NOT NULL (`post|reel|carousel`), `caption`, `timestamp` NOT NULL, `media_paths` TEXT default `'[]'` (JSON de caminhos de container), `fetched_at`.
- **manual_fetch_queue** — `id` PK, `username` NOT NULL, `requested_at`, `status` default `'pending'` (`pending|running|done|error`).
- **Índices:** `idx_posts_profile (profile_username)`, `idx_posts_timestamp (timestamp)`, `idx_queue_status (status, requested_at)`.

Layout em disco: mídia em `${DATA_DIR}/media/<username>/<shortcode>[_idx].jpg|mp4`; feeds em `${DATA_DIR}/feeds/<username>.xml`; sessão em `${DATA_DIR}/session/session-<IG_USERNAME>`.

## 🔌 Endpoints / API
- `GET /health` — liveness probe.
- `GET /` — redirect para `/ui/`.
- `GET /ui/` — dashboard web estático (`StaticFiles`, `html=True`).
- `GET /feeds/{username}.xml` — feed RSS (arquivo estático).
- `GET /media/{path}` — arquivos de mídia (estáticos).
- `GET /api/profiles` — lista perfis.
- `POST /api/profiles` — adiciona perfil (normaliza strip/`@`/lower; 201; 409 se já existe; 422 se vazio).
- `GET /api/profiles/{username}` — detalhe + `recent_posts` (30 dias); 404 se não existe.
- `DELETE /api/profiles/{username}` — remove perfil, mídia (`rmtree`) e feed XML; 204; 404 se não existe.
- `POST /api/profiles/{username}/fetch` — enfileira fetch manual; 202 com `queue_id`; 404 se perfil não existe.
- `GET /api/stats` — `profile_count`, `post_count`, `total_storage_bytes`, `last_fetch_at`.

`docs_url` e `redoc_url` estão desativados.

## 🔗 Integracoes externas
- **Instagram (via instaloader):** login com conta secundária, leitura de perfis/posts e download de mídia do CDN do Instagram (download direto via httpx).
- **Let's Encrypt:** CA do wildcard `*.daberga.com` que o router consome via `tls=true` no Traefik (o cert é emitido uma única vez pela stack do Traefik, não por este app).

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (`01-network/traefik`): roteamento HTTPS em `rssig.${DOMAIN}`, entrypoint `websecure`, `tls=true` consumindo o wildcard `*.daberga.com` (CA Let's Encrypt, emitido pela stack do Traefik) e middleware `internal-only@docker` (restrição de rede definida na stack do Traefik).
- **Rede `bergatrix-proxy`** (`external: true`): rede compartilhada provida pela stack do Traefik.
- Não usa litellm/LLM, nem Authentik, nem banco de dados externo da plataforma — a persistência é um SQLite local próprio no volume `${INSTALOADER_DATA_DIR}`.

## 🔑 Variaveis de ambiente necessarias
- **Domínio/roteamento:** `DOMAIN`
- **Credenciais Instagram:** `IG_USERNAME`, `IG_PASSWORD`, `IG_USER_AGENT`
- **Armazenamento:** `INSTALOADER_DATA_DIR` (interpolação host-side do compose para o volume)
- **Feeds:** `RSS_BASE_URL`
- **Scraper/scheduler:** `SCRAPE_DAYS`, `SCHEDULE_INTERVAL_HOURS`
- **Definidas no compose (não via .env):** `TZ`, `DATA_DIR`

(Apenas nomes — nenhum valor é exibido. Todas as variáveis do `.env` são aplicadas a ambos os serviços via `env_file`.)

## 🗂️ Estrutura de codigo
- `docker-compose.yml` — define os dois serviços, redes (internal/egress/proxy), volumes, healthchecks e labels Traefik.
- `.env.example` — placeholders das variáveis (única fonte de env versionada).
- `worker/main.py` — processo em background: sessão instaloader, download de mídia via httpx, `fetch_profile` com lock por perfil, e os 4 jobs do APScheduler (`scrape_all`, `manual_queue`, `cleanup`, `alive`).
- `worker/rss_builder.py` — geração do RSS 2.0 por perfil com feedgen e montagem do HTML de `description`/`enclosure`.
- `worker/db.py` — camada SQLite (schema, perfis, posts, fila manual, stats).
- `api/main.py` — FastAPI: REST `/api/*`, mounts estáticos `/feeds`, `/media`, `/ui`, redirect de `/`.
- `api/db.py` — **cópia byte-a-byte** de `worker/db.py` (não há pacote compartilhado).
- `api/ui/` — dashboard SPA: `index.html`, `app.js` (tabela de perfis, add/remove, fetch com polling, auto-refresh a cada 30s), `style.css`.
- `worker/Dockerfile`, `api/Dockerfile`, `*/requirements.txt` — build e dependências de cada serviço.

## 🛡️ Gestao de segredos
- Credenciais do Instagram e demais variáveis são injetadas via `env_file: .env` em ambos os serviços; `TZ` e `DATA_DIR` vêm diretamente de `environment:`.
- O repositório versiona apenas `.env.example` com placeholders. A verificação com `git ls-files` confirmou que **nenhum `.env` real está commitado** e que não há arquivos ignorados presentes — **nenhum segredo exposto encontrado**.
- A sessão autenticada do instaloader é persistida no volume (`${INSTALOADER_DATA_DIR}/session/session-<IG_USERNAME>`).
- **Atenção:** não há autenticação de aplicação no dashboard `/ui` nem nos endpoints `/api` (incluindo as rotas de escrita de adicionar/remover perfil e disparar fetch). A proteção depende inteiramente do middleware `internal-only@docker` do Traefik. Recomenda-se revisar essa restrição de rede; em caso de credencial real ter sido exposta em algum momento fora do versionado, rotacionar a senha da conta secundária do Instagram.

## 🚧 Notas de evolucao / pendencias
- Corrigir a divergência de host: compose usa `rssig.`, `.env.example`/`RSS_BASE_URL` usam `rss-ig.` — alinhar `RSS_BASE_URL` ao host real ou a mídia nos feeds quebra.
- `db.py` duplicado byte-a-byte entre `worker/` e `api/` — extrair para um pacote compartilhado para evitar divergência.
- Uso de `datetime.utcnow()` (deprecado no Python 3.12); comparações de timestamp feitas como strings ISO (assumem formato consistente).
- feedgen usa `published`/`updated` (Atom) em um feed RSS 2.0; `enclosure length` é sempre `0`.
- `python-multipart` no requirements da API parece vestigial (nenhum endpoint multipart).
- Sem testes automatizados e sem migrações de schema (apenas `CREATE TABLE IF NOT EXISTS`).
- Sem rate-limit/backoff exponencial além do delay aleatório de 30–180s; risco de bloqueio da conta com muitos perfis.
- Sem autenticação de aplicação — segurança delegada ao Traefik.

## ❓ Perguntas em aberto
- Qual host é o correto: `rssig.${DOMAIN}` (compose) ou `rss-ig.${DOMAIN}` (.env.example)? `RSS_BASE_URL` precisa acompanhar.
- O que exatamente o middleware `internal-only@docker` restringe (faixa de IP/rede)? Isso define se leitores RSS conseguem buscar os feeds.
- Como leitores RSS externos acessariam os feeds se o acesso é internal-only — o uso pretendido é apenas dentro do homelab/VPN?
- A retenção fixa em 30 dias (hardcoded) vs `SCRAPE_DAYS` configurável é intencional (manter feed com janela maior que a coleta)?
- É aceitável que as rotas de escrita da API e o dashboard não tenham autenticação de aplicação, confiando apenas na restrição de rede?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
