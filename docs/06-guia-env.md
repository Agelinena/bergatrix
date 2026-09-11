# 🔑 Bergatrix — Guia do `.env` (como construir, o que ter e como manipular)

> Tudo na Bergatrix injeta segredos e configuração via **`.env`**. Não há um `.env` global: **cada stack tem o seu**, ao lado do `docker-compose.yml`. Este guia explica o modelo mental, o conteúdo esperado, como gerar/manter e as armadilhas reais encontradas no repo.

## 1. Modelo mental — o `.env` tem papel DUPLO
Em cada stack, o `.env` é usado de **duas formas ao mesmo tempo** pelo Docker Compose:

1. **Interpolação no `docker-compose.yml`** — o Compose lê automaticamente o `.env` da **mesma pasta** do arquivo para resolver `${VAR}` (ex.: `Host(\`news.${DOMAIN}\`)`, `${VOLUMES_BASE}/...`). Isso acontece **antes** de subir o container.
2. **Injeção no container** — via `env_file: .env` (e/ou blocos `environment:`), as variáveis viram variáveis de ambiente **dentro** do container, lidas pelo código da app.

> Consequência prática: uma mesma variável (ex.: `DOMAIN`, `POSTGRES_PASSWORD`) pode ser usada nos **dois** papéis. Por isso o `.env` fica na raiz da pasta da stack, não dentro de `app/`.

**Precedência** (do mais forte para o mais fraco): valor já exportado no shell → bloco `environment:` no compose → `env_file: .env`. Ou seja, o que estiver em `environment:` **vence** o `.env`.

## 2. Como construir um `.env` (passo a passo)
```bash
cd 03-apps/<stack>            # pasta da stack que você vai subir
cp .env.example .env          # ponto de partida (NUNCA edite o .example com valores reais)
# edite o .env com seus valores
nano .env                     # (ou seu editor)
docker compose config         # valida e MOSTRA as variáveis já resolvidas (confira ${...})
docker compose up -d          # sobe a stack
```
- **Sempre** comece do `.env.example` da stack — ele lista os nomes esperados.
- Use `docker compose config` para conferir se todo `${VAR}` foi resolvido (variável faltando aparece vazia ou gera warning).
- Para **4 stacks sem `.env.example`** (`litellm`, `n8n`, `openuiweb`, `transcriptor`), descubra as variáveis lendo o `docker-compose.yml` da stack ou a seção "Variáveis de ambiente necessárias" em [`stacks/<nome>.md`](stacks/).

## 3. O que todo `.env` costuma ter (variáveis comuns)
Estas se repetem na maioria das stacks — padronize-as com **os mesmos valores** em todas:

| Variável | Papel | Exemplo / formato |
|---|---|---|
| `DOMAIN` | Domínio base do homelab (usado em `Host(...)`) | `daberga.com` |
| Base de volume | Caminho no host p/ dados persistentes | `VOLUMES_BASE=/mnt/storage/docker_volumes` |
| `TZ` | Timezone (cron/agendamentos) | `America/Sao_Paulo` |
| `PUID` / `PGID` | UID/GID do usuário dono dos arquivos no host | `1000` / `1000` |

E, **quando a stack tem banco/IA**, costumam aparecer:

| Variável | Quando | Observação |
|---|---|---|
| `POSTGRES_USER` / `POSTGRES_DB` | stack com Postgres | em geral = nome da stack |
| `POSTGRES_PASSWORD` | stack com Postgres | **segredo** — gerar forte |
| `DATABASE_URL` | algumas apps (ex. bergastream) | ⚠️ embute a senha — ver §6 |
| `SECRET_KEY` / `JWT_SECRET_KEY` | apps com sessão/JWT | ≥32 chars aleatórios |
| `OPENROUTER_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY` | apps com IA | deixe vazio se não usar aquele provider |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | apps com seed de admin | trocar o `changeme` |

> ⚠️ **Atenção à variável de volume:** hoje o repo **não é uniforme** — `bergastream` usa `VOLUMES_BASE`, `cloudbeaver`/`jellyfin` usam `STORAGE_PATH`/`STORAGE_PATH`, `berga-news` usa `BERGANEWS_DATA_DIR`, `rss` usa `RSS_DATA_DIR`, `transcriptor` usa `TRANSCRIPTOR_DATA_DIR`, `rss-ig` usa `INSTALOADER_DATA_DIR`. Ao criar uma stack nova, **prefira `VOLUMES_BASE`** (ver [02-convencoes-e-padroes.md](02-convencoes-e-padroes.md)). As variáveis específicas de cada stack estão no respectivo `stacks/<nome>.md`.

## 4. Como gerar segredos fortes
Nunca deixe `changeme` / `troque_por_string_aleatoria_32_chars` em produção. Gere valores aleatórios:

```bash
# Senha/segredo genérico (hex de 32 bytes = 64 chars)
openssl rand -hex 32

# Segredo URL-safe (bom para SECRET_KEY / JWT_SECRET_KEY)
python -c "import secrets; print(secrets.token_urlsafe(48))"

# Senha forte (base64, sem caracteres problemáticos)
openssl rand -base64 36 | tr -d '\n'
```
- `SECRET_KEY`/`JWT_SECRET_KEY`: **≥32 caracteres**.
- `WAZUH_API_PASSWORD`: mínimo 8 chars, com maiúscula, minúscula e número (exigência do Wazuh).
- Guarde os valores no **Vaultwarden** (`bitwarden.${DOMAIN}`), não em texto solto.

## 5. Como manipular / manter o `.env`
- **Recarregar após editar:** `docker compose up -d` recria os containers cujo ambiente mudou. Em alguns casos vale `docker compose down && docker compose up -d`.
- **Conferir o que o container recebeu:** `docker compose config` (resolvido) ou `docker compose exec <serviço> env | sort`.
- **Sintaxe do arquivo:**
  - Uma `CHAVE=valor` por linha; sem espaços ao redor do `=`.
  - Comentários com `#` no **início da linha** (o `bergastream/.env.example` usa comentários; evite comentário no fim de uma linha de valor, pois alguns parsers incluem o resto da linha no valor).
  - Valores com espaços/`;`/caracteres especiais entre **aspas**: ex. `IG_COOKIE='sessionid=...; csrftoken=...;'` (visto no `rss/.env.example`).
  - **Não** use `${OUTRA_VAR}` esperando expansão dentro do próprio `.env` — a interpolação acontece no compose, não dentro do `env_file` injetado no container.
- **Manter o `.env.example` em dia:** ao adicionar uma variável nova ao `.env`, adicione o **nome** (com placeholder) ao `.env.example` e commite **só o example**.

## 6. Armadilhas reais encontradas no repo
- 🔴 **`DATABASE_URL` duplica a senha** (`bergastream/.env.example`): `postgresql+asyncpg://bergastream:<senha>@.../bergastream`. Se você trocar `POSTGRES_PASSWORD`, **tem que atualizar `DATABASE_URL` também**, senão a app não conecta. (Melhor evoluir para montar a URL via interpolação no compose, como o `berga-news` faz.)
- 🟠 **Placeholders de `DOMAIN` inconsistentes** entre stacks: `#dominio` (traefik), `daberga.com` (berga-news), `yourdomain.com` (wazuh), `example.com` (drop), vazio (rss). Use sempre o **mesmo** domínio real no seu `.env`.
- 🟠 **Placeholder estilo `=#valor`** (`traefik/.env.example`, ex. `DOMAIN=#dominio`): em um `.env`, isso definiria o valor **literal** `#dominio` (o `#` no meio da linha **não** é comentário). Substitua pelo valor real, sem `#`.
- 🟠 **4 stacks sem `.env.example`** (`litellm`, `n8n`, `openuiweb`, `transcriptor`) — derive as variáveis do compose/`stacks/<nome>.md`.
- 🟡 **`SECRET_KEY` declarada mas sem uso** no `berga-news` (sessões usam uuid4) — preencher mesmo assim não faz mal, mas saiba que hoje é vestigial.

## 7. Conformidade & segurança (obrigatório)
- O **`.env` real NUNCA é versionado** — o `.gitignore` já o bloqueia. Só o `.env.example` (placeholders) entra no git.
- **Nunca** coloque valores de segredo em `docker-compose.yml`, código ou nestes docs.
- Não passe segredo por **querystring/URL** (corrigir o caso do `berga-news` em [04-roadmap-e-backlog.md](04-roadmap-e-backlog.md)).
- **Rotação:** se um segredo vazar (log, histórico, commit acidental), troque o valor e suba a stack de novo. Para Postgres, troque a senha no banco e no `.env` (e `DATABASE_URL` quando existir).
- Caminhos de dados ficam **fora do repo** (`${VOLUMES_BASE}/...`) e também são ignorados pelo git.

## 8. Template canônico de `.env.example` (para padronizar / criar os que faltam)
```dotenv
# ── Identidade / roteamento ───────────────────────────────
DOMAIN=daberga.com
# SUBDOMAIN é usado em Host(`${SUBDOMAIN}.${DOMAIN}`) quando aplicável
# SUBDOMAIN=minhaapp

# ── Armazenamento no host ─────────────────────────────────
VOLUMES_BASE=/mnt/storage/docker_volumes

# ── Locale / permissões ───────────────────────────────────
TZ=America/Sao_Paulo
PUID=1000
PGID=1000

# ── Banco (se a stack tiver Postgres) ─────────────────────
POSTGRES_USER=minhaapp
POSTGRES_DB=minhaapp
POSTGRES_PASSWORD=        # gerar: openssl rand -base64 32

# ── Segredos da aplicação ─────────────────────────────────
SECRET_KEY=              # gerar: python -c "import secrets;print(secrets.token_urlsafe(48))"

# ── Integrações externas (vazio = não usar) ───────────────
OPENROUTER_API_KEY=
```
> Convenção: **todas** as variáveis aparecem no `.env.example` com placeholder; segredos ficam **vazios** ou com instrução de geração (nunca um valor real).

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a estrutura evoluir._
