# litellm — Proxy/gateway LiteLLM auto-hospedado que expoe uma API unica compativel com OpenAI, roteando para modelos da OpenRouter (free e pagos), com um sidecar que sincroniza o catalogo e gerencia virtual keys

> **Categoria:** app | **Caminho:** `03-apps/litellm` | **Status:** active

## 🎯 Finalidade
Centraliza o acesso a LLMs para todas as stacks do homelab Bergatrix. Em vez de cada app conversar diretamente com a OpenRouter, todos usam este proxy LiteLLM — que e compativel com a API OpenAI — exposto em `llm.${DOMAIN}`. O proxy resolve tres problemas: (1) uma unica porta de entrada para multiplos modelos, com roteamento `least-busy`, retries e cooldown; (2) persistencia de modelos e chaves em Postgres com UI de administracao; e (3) um sidecar (`litellm-updater`) que mantem o catalogo de modelos sempre atualizado com o que a OpenRouter expoe, separando modelos gratuitos de pagos e mantendo duas virtual keys distintas (`free-models-key` e `paid-models-key`).

## 🧱 Stack tecnologica
- **LiteLLM Proxy** — imagem `ghcr.io/berriai/litellm:main-latest` (tag movel, sem pinning)
- **PostgreSQL 16** — `postgres:16-alpine`
- **Python 3.11-slim** — imagem base do sidecar `litellm-updater`
- **requests >= 2.31.0** — unica dependencia Python do sidecar
- **Docker Compose** — orquestracao (3 servicos, 3 redes)
- **Traefik** — proxy reverso / TLS (stack externa do repo)
- **OpenRouter** — provedor upstream de todos os modelos LLM

## 📦 Servicos / Containers

| Servico | Imagem / Build | Portas | Volumes | Redes | depends_on | Restart | Healthcheck | Traefik |
|---|---|---|---|---|---|---|---|---|
| **litellm-db** | `postgres:16-alpine` | 5432 (apenas interno; sem publicacao no host) | `${LITELLM_DATA_DIR}:/var/lib/postgresql/data` | `litellm-internal` | — | `unless-stopped` | `pg_isready -U litellm -d litellm` (interval 10s, timeout 5s, retries 5, start_period 30s) | nao exposto |
| **litellm** | `ghcr.io/berriai/litellm:main-latest` | 4000 (porta interna; exposta so via Traefik, sem mapeamento ao host) | `./config.yaml:/app/config.yaml:ro` | `litellm-internal`, `bergatrix-proxy` | `litellm-db` (`condition: service_healthy`) | `unless-stopped` | nenhum no compose (expoe `/health/liveliness`) | `Host(\`llm.${DOMAIN}\`)`, entrypoint `websecure`, `tls=true` (wildcard `*.daberga.com`, sem certresolver proprio), middleware `internal-only@docker`, lb port 4000 |
| **litellm-updater** | build local `./updater` (`python:3.11-slim`) | — | — | `litellm-internal`, `litellm-egress` | `litellm` (depends_on simples, sem condition) | `unless-stopped` | nenhum | nao exposto |

**Notas adicionais:**
- Nenhum servico define limites de recursos ou GPU.
- `litellm` e `litellm-updater` fixam DNS em `1.1.1.1` e `8.8.8.8`. O banco nao tem override de DNS.
- `command` do proxy: `--config /app/config.yaml --port 4000 --detailed_debug`.
- `litellm-updater` roda `python -u update_free_models.py` em loop.

## 🌐 Dominios / Roteamento
- **Hostname:** `llm.${DOMAIN}`
- **Entrypoint:** `websecure` (HTTPS), TLS via `tls=true` consumindo o wildcard `*.daberga.com` compartilhado do Traefik (sem `certresolver` proprio — nao emite certificado individual; CA continua sendo o Let's Encrypt)
- **Middleware:** `internal-only@docker` (definido na stack Traefik) — restringe o acesso a rede interna / VPN
- **Load balancer:** porta 4000 do container `litellm`
- Apenas o servico `litellm` e roteado pelo Traefik; `litellm-db` e `litellm-updater` sao internos.

## 📐 Regras de negocio
O sidecar `litellm-updater` implementa a logica de sincronizacao, em loop infinito (`sync_once()` + `sleep(SYNC_INTERVAL)`, default 3600s = 1h):

1. **Startup:** `wait_for_litellm()` faz polling em `/health/liveliness` (ate 120s, intervalo de 5s); considera o proxy pronto quando o status HTTP for menor que 500. Se nao responder a tempo, inicia mesmo assim. Esse wait e necessario porque o `depends_on` do compose nao usa `condition: service_healthy` para o proxy.
2. **Fetch OpenRouter:** busca `GET /models` e classifica cada modelo via `is_free()`:
   - **Gratuito** se o id termina com `:free` **OU** se `pricing.prompt == 0` E `pricing.completion == 0`. O safety net usa default `"1"` quando o pricing esta ausente — ou seja, na duvida o modelo e tratado como **pago**.
3. **Convencao de nomes:** modelos free recebem prefixo `or-free/` e tem o sufixo `:free` removido do `model_name` (para evitar `:`); modelos pagos recebem prefixo `or-paid/`.
4. **Diff de modelos:** compara o catalogo da OpenRouter com os modelos gerenciados no LiteLLM (filtrados por prefixo). Adiciona novos via `POST /model/new` e remove ausentes via `POST /model/delete` (payload JSON `{"id": db_id}`).
5. **Virtual keys (upsert a cada ciclo):**
   - `free-models-key` → apenas modelos `or-free/`.
   - `paid-models-key` → modelos `or-paid/` **+** `STATIC_MODELS` (`deepseek-v3`).
   - Se a key existe (busca por alias em `/key/list`), e atualizada via `/key/update` reaproveitando o token; senao e criada via `/key/generate`.
6. **Modelos estaticos:** `deepseek-v3` (em `STATIC_MODELS` e no `config.yaml`) NUNCA entra no diff de add/remove; e apenas anexado a `paid-models-key`.
7. **Roteamento (config.yaml):** `routing_strategy: least-busy`, `num_retries: 3`, `allowed_fails: 2` (pausa o modelo apos 2 falhas), `cooldown_time: 120` (segundos fora apos falhas consecutivas).
8. **Resiliencia:** falhas individuais de add/delete de modelo e upsert de key sao toleradas (logadas como warning, ciclo continua). Falhas nas etapas de fetch (OpenRouter ou LiteLLM) abortam o ciclo atual (`return`), mas o loop sobrevive — excecoes nao tratadas sao capturadas com `log.exception`.

## 🗄️ Modelo de dados
PostgreSQL gerenciado pelo proprio LiteLLM (schema interno do produto, ativado por `store_model_in_db: true` e `load_models_from_db: true`). Persiste:
- **Definicoes de modelos:** `model_name` → `litellm_params` (`openrouter/<id>`, `api_base`, `api_key`) + `model_info` (`mode: chat`, `source: openrouter-sync`).
- **Virtual keys:** aliases, lista de modelos permitidos e metadata (`description`, `managed_by: openrouter-sync`).

O sidecar **nao acessa o Postgres diretamente**; toda manipulacao e via API REST do proxy. **Observacao de seguranca:** ao adicionar modelos via `/model/new`, o sidecar embute o valor resolvido de `OPENROUTER_API_KEY` no campo `litellm_params.api_key`, que portanto fica persistido no DB do proxy (diferente do modelo estatico do `config.yaml`, que usa `os.environ/OPENROUTER_API_KEY`).

## 🔌 Endpoints / API
**Consumidos pelo sidecar:**
- `GET https://openrouter.ai/api/v1/models` — catalogo upstream
- `GET {LITELLM_URL}/model/info` — modelos gerenciados (filtra por prefixo)
- `POST {LITELLM_URL}/model/new` — adiciona modelo
- `POST {LITELLM_URL}/model/delete` — remove modelo (`{"id": db_id}`)
- `GET {LITELLM_URL}/key/list?key_alias=...` — busca virtual key por alias
- `POST {LITELLM_URL}/key/update` — atualiza key existente
- `POST {LITELLM_URL}/key/generate` — cria nova key
- `GET {LITELLM_URL}/health/liveliness` — readiness do proxy

**Expostos pelo proxy** (API estilo OpenAI em `llm.${DOMAIN}`): `/v1/chat/completions`, `/v1/models`, UI de administracao, entre outros do produto LiteLLM.

## 🔗 Integracoes externas
- **OpenRouter** (`https://openrouter.ai/api/v1`) — provedor upstream de todos os modelos LLM; catalogo lido em `/models`, roteamento via `openrouter/<id>`.
- **Let's Encrypt** — CA do wildcard `*.daberga.com` (emitido uma unica vez pela stack Traefik); o proxy apenas consome esse cert via `tls=true`, sem emitir o proprio.
- **DNS publicos** `1.1.1.1` / `8.8.8.8` — fixados nos containers `litellm` e `litellm-updater`.

## 🧩 Dependencias internas (Bergatrix)
- **Rede externa `bergatrix-proxy`** — compartilhada com a stack Traefik, usada para expor o proxy.
- **Traefik** — roteamento `Host(\`llm.${DOMAIN}\`)`, TLS via `tls=true` consumindo o wildcard `*.daberga.com` compartilhado (sem certresolver proprio; CA Let's Encrypt) e o middleware `internal-only@docker` (definido na stack Traefik) que restringe o acesso a rede interna / VPN.
- **Provedor de LLM central do homelab** — outras stacks Bergatrix (ex.: berga-news, transcriptor, jellyfin optimizer) deveriam consumir LLMs atraves deste proxy. Nao ha referencia cruzada explicita nos arquivos desta stack.

## 🔑 Variaveis de ambiente necessarias
**Banco / proxy:**
- `LITELLM_DB_PASSWORD`
- `LITELLM_DATA_DIR`
- `LITELLM_MASTER_KEY`
- `LITELLM_SALT_KEY`
- `LITELLM_UI_USERNAME`
- `LITELLM_UI_PASSWORD`

**Provedor / roteamento:**
- `OPENROUTER_API_KEY`
- `DOMAIN`

**Sidecar (opcional):**
- `LITELLM_SYNC_INTERVAL` (default `3600`)

> `DATABASE_URL` e `LITELLM_URL` nao precisam ser definidos pelo usuario: o primeiro e montado no compose a partir de `${LITELLM_DB_PASSWORD}`, e o segundo e literal (`http://litellm:4000`).

## 🗂️ Estrutura de codigo
Stack minimalista de 6 arquivos versionados.

**Raiz (`03-apps/litellm`):**
- `docker-compose.yml` — 3 servicos + 3 redes (`litellm-internal` com `internal: true`, `litellm-egress` bridge, `bergatrix-proxy` external).
- `config.yaml` — `model_list` (1 modelo estatico `deepseek-v3`), `router_settings` (least-busy), `general_settings` (`store_model_in_db` / `load_models_from_db`).
- `.gitignore` — ignora `.env` e `pgdata/`.

**Subpasta `updater/`:**
- `Dockerfile` — `python:3.11-slim`, instala requirements, `CMD python -u update_free_models.py`.
- `requirements.txt` — `requests>=2.31.0`.
- `update_free_models.py` (384 linhas) — o sidecar:
  - **OpenRouter:** `fetch_openrouter_models()`, `is_free()`.
  - **Modelos LiteLLM:** `fetch_litellm_managed()`, `add_model()`, `delete_model()`, `sync_models()` (definida mas **nao usada**).
  - **Virtual keys:** `fetch_existing_key()`, `upsert_virtual_key()`.
  - **Orquestracao:** `sync_once()` (diff inline free/paid + upsert das keys), `wait_for_litellm()` e o `__main__` com o loop principal.

## 🛡️ Gestao de segredos
- Todos os segredos sao injetados via variaveis de ambiente a partir de um arquivo `.env`, que esta corretamente listado no `.gitignore` e **nao e versionado** (confirmado via `git ls-files`: apenas `.gitignore`, `config.yaml`, `docker-compose.yml` e os 3 arquivos do `updater/` estao sob controle de versao).
- O `config.yaml` referencia segredos de forma segura com a sintaxe `os.environ/...` (`LITELLM_MASTER_KEY`, `DATABASE_URL`, `OPENROUTER_API_KEY`), nunca valores literais.
- O sidecar le segredos exclusivamente de `os.environ`. O `DATABASE_URL` no compose embute a senha do banco via interpolacao `${LITELLM_DB_PASSWORD}`.
- **Nenhum valor de segredo esta hardcoded em arquivos versionados** — `secretsExposed` esta vazio.
- **Superficies de exposicao a observar (nenhuma em arquivo versionado):** (1) o sidecar embute o valor de `OPENROUTER_API_KEY` no payload de `/model/new`, persistido no DB do proxy; (2) o proxy roda com `--detailed_debug`, que pode logar payloads/segredos; (3) o token de uma virtual key recem-criada e impresso nos logs do sidecar na criacao. Recomenda-se revisar `--detailed_debug` para producao e rotacionar segredos caso esses logs/DB tenham sido expostos.

## 🚧 Notas de evolucao / pendencias
- **`--detailed_debug` fixo** no comando do proxy: util para diagnostico, mas verboso e potencialmente vazante de payloads/segredos em logs. Revisar para producao.
- **Imagem `main-latest`** (tag movel): sem pinning de versao reproduzivel.
- **Codigo morto:** `sync_models()` (linhas 188-210) existe mas nunca e chamada — `sync_once()` reimplementa o diff inline. Alem disso, o `return` de `sync_models()` tem uma expressao de conjuntos confusa/potencialmente incorreta, sem impacto pratico por estar morta.
- **API key embutida no DB:** ao adicionar modelos, o sidecar envia `OPENROUTER_API_KEY` como valor literal no payload de `/model/new` (diferente do `config.yaml` estatico que usa `os.environ/...`).
- **Distribuicao manual de keys:** o token de uma virtual key so e exibido nos logs na criacao; nao ha exportacao automatica para os apps consumidores.
- **Sem healthcheck no `litellm`** no compose, embora exista `/health/liveliness`.
- **Sidecar sem limites de recursos nem backoff exponencial:** em falha de rede o unico retry e o proximo ciclo (default 1h). `litellm-updater` usa `depends_on` simples (sem `condition`), por isso o `wait_for_litellm` no codigo e essencial.

## ❓ Perguntas em aberto
- Como as virtual keys (`free-models-key` / `paid-models-key`) sao distribuidas aos apps consumidores, ja que o token so aparece nos logs na criacao? Existe processo manual de copia?
- Quais stacks Bergatrix de fato consomem este proxy hoje (berga-news, transcriptor, jellyfin optimizer)? Nao ha referencia cruzada nos arquivos desta stack.
- O middleware `internal-only@docker` realmente restringe `llm.${DOMAIN}` a rede interna/VPN — confirmar a definicao na stack Traefik.
- A funcao `sync_models()` ficou sem uso intencionalmente? Deveria ser removida ou o diff inline de `sync_once()` refatorado para usa-la?
- O modelo estatico `deepseek-v3` aponta para `openrouter/deepseek/deepseek-v3` (sem `:free`) — confirmar se e o id correto/atual na OpenRouter.
- E aceitavel que o valor de `OPENROUTER_API_KEY` seja persistido no DB do proxy via `/model/new`?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
