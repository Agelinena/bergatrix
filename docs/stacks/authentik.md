# authentik — Provedor de identidade (IdP) e SSO self-hosted que centraliza autenticacao e fornece ForwardAuth ao Traefik

> **Categoria:** security | **Caminho:** `02-security/authentik` | **Status:** stable

## 🎯 Finalidade
O Authentik e o servico central de Identity & Access Management (IAM) do homelab Bergatrix. Ele resolve o problema de ter um unico ponto de autenticacao (SSO) para todas as aplicacoes auto-hospedadas, em vez de cada servico gerenciar logins isoladamente.

Suas duas funcoes principais:
1. **IdP / SSO** — fornece login unico via OIDC, SAML e proxy, com gestao de usuarios, grupos, flows e policies.
2. **ForwardAuth para o Traefik** — expoe um endpoint de outpost embarcado que o Traefik consulta (middleware `authentik`) para autorizar ou barrar o acesso a outros servicos. Aplicacoes como CloudBeaver e Wazuh so abrem apos login no SSO.

O deployment segue o stack de referencia oficial do goauthentik: `server` + `worker` + PostgreSQL + Redis. O dominio publicado e `authentik.${DOMAIN}`, servido pelo wildcard compartilhado `*.daberga.com` do Traefik (via `tls=true`, sem `certresolver` proprio) e atras do middleware `internal-only@docker` (acesso restrito a loopback e a LAN `192.168.10.0/24`).

## 🧱 Stack tecnologica
- **Authentik** — `ghcr.io/goauthentik/server:2025.10.2` (mesma imagem para server e worker, diferenciados por `command`).
- **PostgreSQL 16** — `docker.io/library/postgres:16-alpine` (banco principal).
- **Redis** — `docker.io/library/redis:alpine` (cache/broker de tarefas e sessoes; tag nao fixada em versao).
- **Traefik** — reverse proxy, TLS e ForwardAuth (stack externa em `01-network/traefik`).
- **Docker Compose** — orquestracao declarativa. Nao ha codigo-fonte de aplicacao no repo; toda a logica roda dentro das imagens oficiais.

## 📦 Servicos / Containers

| Servico | Imagem | Portas | Volumes | Redes | depends_on | Restart | Healthcheck |
|---|---|---|---|---|---|---|---|
| **postgresql** (`authentik-db`) | `postgres:16-alpine` | — (interno) | `${STORAGE_PATH}/authentik/database:/var/lib/postgresql/data` | `authentik-internal` | — | `unless-stopped` | `pg_isready -d $POSTGRES_DB -U $POSTGRES_USER` (start 20s, intervalo 30s, 5 retries, timeout 5s) |
| **redis** (`authentik-redis`) | `redis:alpine` | — (interno) | `${STORAGE_PATH}/authentik/redis:/data` | `authentik-internal` | — | `unless-stopped` | `redis-cli ping \| grep PONG` (start 20s, intervalo 30s, 5 retries, timeout 3s) |
| **server** (`authentik-server`) | `goauthentik/server:2025.10.2` | porta interna 9000 (via Traefik) | `media:/media`, `custom-templates:/templates` | `bergatrix-proxy`, `authentik-internal` | postgresql, redis | `unless-stopped` | nenhum |
| **worker** (`authentik-worker`) | `goauthentik/server:2025.10.2` | — | `/var/run/docker.sock`, `media:/media`, `certs:/certs`, `custom-templates:/templates` | `bergatrix-proxy`, `authentik-internal` | postgresql, redis | `unless-stopped` | nenhum |

Observacoes:
- **redis** usa `command: --save 60 1 --loglevel warning` (persistencia por snapshot).
- **server** roda `command: server` (UI/admin + API + endpoint de outpost embarcado).
- **worker** roda `command: worker` (tarefas em background). Monta `/var/run/docker.sock` (acesso root-equivalente ao host) para gerenciamento/descoberta de containers e outposts.
- Nenhum servico declara `deploy` (sem limites de GPU/recursos).
- Apenas o **server** possui labels Traefik.

## 🌐 Dominios / Roteamento
- **Hostname:** `authentik.${DOMAIN}` (router Traefik `authentik`).
- **Entrypoint:** `websecure`; **TLS:** `tls=true` (sem `certresolver`) — consome o wildcard compartilhado `*.daberga.com` do Traefik; nao emite certificado individual.
- **Servico Traefik:** `authentik-service`, `loadbalancer.server.port=9000`; `traefik.docker.network=bergatrix-proxy`.
- **Middleware de acesso (UI):** `internal-only@docker` — definido na stack Traefik como `ipAllowList` com sourcerange `127.0.0.1/32, 192.168.10.0/24`, restringindo o painel a loopback e a LAN.
- **Middleware ForwardAuth definido aqui:** `authentik` →
  `http://authentik-server:9000/outpost.goauthentik.io/auth/traefik`
  com `trustForwardHeader=true` e `authResponseHeaders=X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid,Authorization`.

postgresql e redis nao tem roteamento: ficam **internos apenas** na rede `authentik-internal`.

## 📐 Regras de negocio
- **Publicacao do painel:** server exposto via Traefik com `Host(authentik.${DOMAIN})`, servindo o wildcard compartilhado `*.daberga.com` (via `tls=true`, sem `certresolver` proprio), e protegido pelo `internal-only@docker` (somente loopback + `192.168.10.0/24`).
- **ForwardAuth como guardiao:** o middleware `authentik` autentica requisicoes contra o outpost embarcado; outros servicos o aplicam para exigir login. Consumidores reais no repo: **cloudbeaver** (`internal-only@docker,authentik@docker`) e **wazuh** (`internal-only@docker,authentik@docker`).
- **Propagacao de identidade:** apos login, o ForwardAuth repassa aos backends os headers `X-authentik-username`, `X-authentik-groups`, `X-authentik-email`, `X-authentik-name`, `X-authentik-uid` e `Authorization`.
- **IP real atras do proxy:** `AUTHENTIK_TRUSTED_PROXY_CIDRS` (definida inline apenas no server) confia em `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, CGNAT `100.64.0.0/10` e IPv6 `fd6d:f154:e57d::/64`.
- **Isolamento de dados:** postgres e redis ficam apenas na rede `authentik-internal` (bridge), sem exposicao externa. server e worker participam de ambas as redes (`bergatrix-proxy` + `authentik-internal`).
- **Tarefas de background (worker):** envio de email, rotacao de certificados, expiracao de sessoes, sincronizacoes e tarefas agendadas; acesso ao Docker via `docker.sock` para gerenciar outposts/containers.
- **Dependencias de boot:** server e worker tem `depends_on` de postgresql e redis.

## 🗄️ Modelo de dados
- **PostgreSQL 16**, database `authentik`, usuario `authentik` — schema gerenciado integralmente pelo proprio Authentik (usuarios, grupos, aplicacoes, providers, flows, policies, tokens, eventos). Persistido em `${STORAGE_PATH}/authentik/database`.
- **Redis** — cache e broker de tarefas/sessoes; persistencia por snapshot (`--save 60 1`). Dados em `${STORAGE_PATH}/authentik/redis`.
- **Volumes de arquivos:** `media` (uploads/icones), `certs` (certificados gerenciados pelo worker), `custom-templates` (templates customizados).
- As migrations e o schema sao aplicados pelas proprias imagens do Authentik; nao ha definicao de schema versionada no repo.

## 🔌 Endpoints / API
- `http://authentik-server:9000/outpost.goauthentik.io/auth/traefik` — endpoint de **ForwardAuth** consumido internamente pelo Traefik para autenticar requisicoes (rede interna).
- `https://authentik.${DOMAIN}` — **UI web e API/admin** do Authentik, via Traefik (entrypoint `websecure`; porta interna do container `9000`).

## 🔗 Integracoes externas
- **Let's Encrypt** — CA do TLS; o certificado e o wildcard compartilhado `*.daberga.com`, emitido uma unica vez pela stack `01-network/traefik`. Esta app apenas consome esse wildcard (via `tls=true`), nao emite certificado individual.
- **ghcr.io / Docker Hub** — registries das imagens (goauthentik server, postgres, redis).
- **Sentry / error reporting do goauthentik** — controlado por `AUTHENTIK_ERROR_REPORTING__ENABLED` (habilitado, `=true`, no `.env.example`).

## 🧩 Dependencias internas (Bergatrix)
- **traefik** (`01-network/traefik`) — reverse proxy, TLS e o middleware `internal-only@docker` (ipAllowList) referenciado por esta stack.
- **Rede `bergatrix-proxy`** — rede Docker externa compartilhada (`external: true`), deve existir previamente (criada pela stack de rede/traefik).
- **Consumidores do ForwardAuth:** `00-infrastructure/cloudbeaver` e `04-monitoring/wazuh` aplicam o middleware `authentik@docker` nos seus routers.
- **`STORAGE_PATH`** — variavel de caminho de armazenamento persistente compartilhada no homelab.

## 🔑 Variaveis de ambiente necessarias
> Apenas nomes; nunca valores.

**Segredos (via `.env`):**
- `PG_PASS`
- `AUTHENTIK_SECRET_KEY`

**Configuracao geral (via `.env`):**
- `AUTHENTIK_ERROR_REPORTING__ENABLED`
- `DOMAIN`
- `STORAGE_PATH`

**Definidas inline no compose (valores fixos ou derivados):**
- `POSTGRES_PASSWORD` (= `${PG_PASS}`), `POSTGRES_USER` (`authentik`), `POSTGRES_DB` (`authentik`) — no postgresql
- `AUTHENTIK_REDIS__HOST` (`redis`), `AUTHENTIK_POSTGRESQL__HOST` (`postgresql`), `AUTHENTIK_POSTGRESQL__USER` (`authentik`), `AUTHENTIK_POSTGRESQL__NAME` (`authentik`), `AUTHENTIK_POSTGRESQL__PASSWORD` (= `${PG_PASS}`) — em server e worker
- `AUTHENTIK_TRUSTED_PROXY_CIDRS` — apenas no server

> Nota: `AUTHENTIK_SECRET_KEY` e `AUTHENTIK_ERROR_REPORTING__ENABLED` nao aparecem nos blocos `environment:`; chegam exclusivamente via `env_file: .env`.

## 🗂️ Estrutura de codigo
Stack puramente declarativa, sem codigo de aplicacao:
- **`docker-compose.yml`** — define os 4 servicos (postgresql, redis, server, worker), redes (`bergatrix-proxy` externa, `authentik-internal` bridge), volumes, labels Traefik e o middleware ForwardAuth.
- **`.env.example`** — modelo de variaveis com **placeholders** (`PG_PASS`, `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_ERROR_REPORTING__ENABLED`, `DOMAIN`, `STORAGE_PATH`).
- **Volume `custom-templates`** — montado em `/templates` no server e no worker para templates customizados (nenhum versionado no repo).

A configuracao de IdP (flows, providers, applications, policies) e feita em runtime via UI/blueprints do Authentik e nao esta versionada aqui.

## 🛡️ Gestao de segredos
- Segredos sao injetados por variaveis de ambiente e pelo arquivo `.env` (**nao versionado** — confirmado que nao existe `.env` real no repo).
- `PG_PASS` preenche `POSTGRES_PASSWORD` (postgresql) e `AUTHENTIK_POSTGRESQL__PASSWORD` (server/worker) via `${PG_PASS}`; `AUTHENTIK_SECRET_KEY` chega via `env_file`.
- O repositorio versiona apenas `.env.example` com **valores PLACEHOLDER** (genericos, nao segredos reais).
- **Nenhum segredo real exposto/commitado** (`secretsExposed` vazio).
- Recomendacoes: gerar `AUTHENTIK_SECRET_KEY` com alta entropia e `PG_PASS` forte antes do deploy.
- **Atencao de seguranca:** o `worker` monta `/var/run/docker.sock` (acesso root-equivalente ao host). E pratica padrao do Authentik para gerenciar outposts, mas amplia a superficie de ataque — convem isolar/limitar conforme a politica interna.

## 🚧 Notas de evolucao / pendencias
- Sem `.env` real commitado — apenas `.env.example` com placeholders (boa pratica de seguranca).
- Stack minima e estavel, alinhada ao template oficial do goauthentik; configuracao de flows/providers/aplicacoes feita em runtime via UI/blueprints (nao versionada).
- Volume `custom-templates` montado, mas sem templates customizados versionados no repo.
- **Divergencia de pinning:** redis usa tag `alpine` (nao fixada) enquanto postgres usa `16-alpine` — recomenda-se fixar a versao do redis.
- server e worker **nao declaram healthcheck** (apenas postgresql e redis tem) — considerar adicionar para deteccao de falhas.
- Nao ha politica explicita de backup dos volumes (`database`/`redis`/`media`/`certs`) declarada nesta stack.

## ❓ Perguntas em aberto
- A configuracao de IdP (flows, providers OIDC/SAML/Proxy, applications, policies, grupos) e gerenciada em runtime e nao esta versionada — nao ha blueprints exportados para revisao. Como sera versionado/reproduzido em um redeploy?
- Existe estrategia de backup/restore para os volumes persistentes do Authentik?
- Ha consumidores do ForwardAuth alem de cloudbeaver e wazuh em deploys nao versionados? (No repo, somente esses dois.)
- Ha intencao de fixar a versao da imagem do Redis para alinhar a estrategia de pinning?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
