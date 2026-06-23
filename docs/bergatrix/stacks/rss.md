# rss — Leitor de feeds RSS auto-hospedado (FreshRSS) com PostgreSQL dedicado, exposto via Traefik em freshrss.${DOMAIN}

> **Categoria:** app | **Caminho:** `03-apps/rss` | **Status:** active

## 🎯 Finalidade
Stack de agregacao e leitura de feeds RSS/Atom para o homelab Bergatrix. Roda o **FreshRSS** (aplicacao PHP open-source de leitura de RSS) apoiado por um **PostgreSQL 15** dedicado, que persiste feeds, categorias, artigos e estado de leitura/favoritos. A aplicacao busca novos itens dos feeds periodicamente atraves do cron embutido do FreshRSS, gravando os artigos no banco. A UI web e a API ficam acessiveis apenas via HTTPS, roteadas pelo Traefik no subdominio `freshrss.${DOMAIN}`. Resolve a necessidade de centralizar e ler feeds de noticias/blogs sem depender de um servico de terceiros (substituindo leitores como Feedly/Inoreader).

## 🧱 Stack tecnologica
- **Docker Compose** — orquestracao declarativa (dois servicos).
- **FreshRSS** (imagem oficial `freshrss/freshrss`, aplicacao PHP) — toda a logica de parsing, deduplicacao, marcacao de lido/favorito, filtros, OPML e API.
- **PostgreSQL 15** (`postgres:15-alpine`) — banco dedicado.
- **Traefik** — reverse proxy, terminacao TLS via wildcard `*.daberga.com` (CA Let's Encrypt).
- **Cron embutido do FreshRSS** — agendamento de refresh dos feeds via `CRON_MIN`.

> Nao ha codigo-fonte proprio: a stack e puramente infraestrutura declarativa.

## 📦 Servicos / Containers

| Atributo | `freshrss` | `db` |
|---|---|---|
| Imagem | `freshrss/freshrss` (sem tag — latest implicito) | `postgres:15-alpine` |
| container_name | `freshrss` | `freshrss_db` |
| Portas no host | nenhuma (porta 80 do container exposta ao Traefik) | nenhuma (so na rede interna) |
| Volumes | `${RSS_DATA_DIR}freshrss/data:/var/www/FreshRSS/data`<br>`${RSS_DATA_DIR}freshrss/extensions:/var/www/FreshRSS/extensions` | `${RSS_DATA_DIR}postgres:/var/lib/postgresql/data` |
| Redes | `bergatrix-proxy`, `rss-internal` | `rss-internal` |
| depends_on | `db` (simples, sem condition) | — |
| restart | `always` | `always` |
| healthcheck | nenhum | nenhum |
| deploy (GPU/limites) | nenhum | nenhum |
| Labels Traefik | sim (ver secao de roteamento) | nenhuma |

**Redes declaradas:** `bergatrix-proxy` (`external: true`, rede do Traefik) e `rss-internal` (`internal: true`, isola o Postgres sem acesso externo).

## 🌐 Dominios / Roteamento
- **Hostname:** `freshrss.${DOMAIN}`
- **Router Traefik** (`freshrss`): `rule=Host(\`freshrss.${DOMAIN}\`)`, `entrypoints=websecure`, `tls=true` (sem `certresolver`) — serve o **wildcard `*.daberga.com`** compartilhado do Traefik, nao emite certificado individual.
- **Service:** `loadbalancer.server.port=80`.
- **Rede do Traefik:** fixada via `traefik.docker.network=bergatrix-proxy`.
- O servico `db` **nao** e exposto (sem labels, somente na rede interna).

## 📐 Regras de negocio
- **Refresh de feeds via cron embutido:** `CRON_MIN=1,31` — atualizacao duas vezes por hora (minutos 1 e 31). Novos artigos sao gravados no Postgres.
- **Timezone:** `TZ=America/Sao_Paulo` — afeta agendamento e timestamps dos artigos.
- **Persistencia em PostgreSQL:** `CR_DB_TYPE=pgsql`, `CR_DB_HOST=db` (em vez do SQLite padrao do FreshRSS).
- **Isolamento do banco:** rede `rss-internal` (`internal: true`) — Postgres sem acesso externo.
- **Acesso web somente HTTPS** via Traefik (websecure + wildcard `*.daberga.com`).

## 🗄️ Modelo de dados
Esquema interno do FreshRSS, gerenciado e migrado automaticamente pela propria aplicacao na inicializacao (tabelas de feeds, categorias, entradas/artigos, tags e estado de leitura/favoritos). Persistencia em PostgreSQL com banco padrao `freshrss` (`POSTGRES_DB=freshrss` no `.env.example`). Dados em bind-mounts sob `${RSS_DATA_DIR}`: config/dados do FreshRSS, extensoes e arquivos do Postgres.

## 🔌 Endpoints / API
Endpoints intrinsecos da imagem FreshRSS, servidos na porta 80 e roteados pelo Traefik:
- UI web do FreshRSS.
- **Google Reader API** e **Fever API** (acesso programatico / apps de leitura).

Nenhum endpoint customizado e definido nesta stack.

## 🔗 Integracoes externas
- **Let's Encrypt** — CA dos certificados TLS; o app consome o **wildcard `*.daberga.com`** servido pelo Traefik (`tls=true`, sem `certresolver`), em vez de emitir cert proprio.
- **Feeds RSS/Atom externos** — fontes de conteudo buscadas pelo FreshRSS.
- **Instagram (planejado/indireto)** — a variavel `IG_COOKIE` ('RSSHub Instagram Auth') existe no `.env.example`, mas **nao e consumida** pelo compose; sugere integracao futura via RSSHub (provavelmente na stack `rss-ig`).

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (`01-network/traefik`) — reverse proxy que termina TLS e roteia `freshrss.${DOMAIN}`; consome o wildcard `*.daberga.com` emitido la (via `tls=true`, sem `certresolver`).
- **Rede `bergatrix-proxy`** (`external: true`) — rede compartilhada do Traefik.
- **Possivel relacao com `03-apps/rss-ig` (RSSHub)** — indicada apenas pela presenca de `IG_COOKIE` no template; nao ha acoplamento real nesta stack.

## 🔑 Variaveis de ambiente necessarias
> Apenas nomes; nunca valores.

**Necessarias para a stack funcionar (consumidas pelo compose):**
- `DOMAIN`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`
- `RSS_DATA_DIR`

**Presentes no `.env.example` mas NAO consumidas pelo compose (bootstrap/legado):**
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `ADMIN_API_PASSWORD`
- `IG_COOKIE`

**Variaveis de ambiente internas do container `freshrss` (valores fixos ou interpolados de POSTGRES_*):**
- `TZ`, `CRON_MIN`, `CR_DB_TYPE`, `CR_DB_HOST`, `CR_DB_NAME`, `CR_DB_USER`, `CR_DB_PASSWORD`

## 🗂️ Estrutura de codigo
Apenas dois arquivos na raiz de `03-apps/rss`:
- **`docker-compose.yml`** — define os servicos `freshrss` e `db`, as redes `bergatrix-proxy` (external) e `rss-internal` (internal), e as labels do Traefik.
- **`.env.example`** — template de variaveis de ambiente, com campos majoritariamente vazios e `POSTGRES_DB=freshrss` como default.

Sem Dockerfile, README, migrations ou scripts — toda a logica vem das imagens oficiais.

## 🛡️ Gestao de segredos
- Segredos sao injetados via `.env` **nao versionado** — confirmado que apenas `.env.example` esta no repositorio (nenhum `.env` real commitado).
- Credenciais do Postgres (`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`) sao definidas no servico `db` e repassadas ao FreshRSS por interpolacao nas variaveis de container `CR_DB_USER`/`CR_DB_PASSWORD`/`CR_DB_NAME`.
- O `IG_COOKIE` no `.env.example` contem apenas **placeholders vazios** (sem valores reais de sessao) — nao constitui segredo exposto.
- **Nenhum segredo real foi encontrado commitado.**
- Recomendacao: manter o `.env` real fora do controle de versao e rotacionar segredos conforme a politica interna de classificacao da informacao.

## 🚧 Notas de evolucao / pendencias
- `IG_COOKIE` ('RSSHub Instagram Auth') existe no template mas nao e usado pelo compose — integracao incompleta ou movida para `rss-ig`.
- `ADMIN_EMAIL`/`ADMIN_PASSWORD`/`ADMIN_API_PASSWORD` estao no `.env.example` mas **nao** sao mapeados no `docker-compose.yml`. A imagem FreshRSS suporta auto-provisionamento (variaveis `FRESHRSS_INSTALL`/`FRESHRSS_USER`), porem nada disso esta configurado — o admin e provavelmente criado manualmente via UI na primeira execucao.
- `freshrss` usa `restart: always` mas nao define **healthcheck** nem limites de recursos (`deploy`).
- `db` nao tem **healthcheck**; `freshrss` usa apenas `depends_on` simples (sem `condition: service_healthy`), podendo iniciar antes do Postgres estar pronto (mitigado por restart, mas nao garantido).
- Imagem `freshrss/freshrss` **sem tag fixa** (latest implicito) — risco de mudancas inesperadas em `pull`. O Postgres ja esta fixado em `15-alpine`.

## ❓ Perguntas em aberto
- Como o usuario admin do FreshRSS e provisionado, ja que `ADMIN_*` nao estao no compose? Setup manual via UI?
- O `IG_COOKIE`/RSSHub para Instagram e consumido em algum lugar ou pertence exclusivamente a stack `rss-ig`?
- Qual a politica de backup dos volumes sob `RSS_DATA_DIR` (dados do FreshRSS e arquivos do Postgres)?
- A ausencia de tag fixa na imagem `freshrss` e intencional (sempre a ultima versao) ou deveria ser pinada?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
