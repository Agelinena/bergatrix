# cloudbeaver — Console web de administracao de banco de dados (CloudBeaver) para o Postgres global do homelab, protegido por Tailscale + Authentik SSO via Traefik

> **Categoria:** infrastructure | **Caminho:** `00-infrastructure/cloudbeaver` | **Status:** deployed (stack minima, somente compose; sem codigo-fonte proprio)

## 🎯 Finalidade
Disponibiliza uma interface web (CloudBeaver, a versao web do DBeaver) para administrar e consultar os bancos de dados do homelab Bergatrix — em especial o Postgres global — sem precisar expor a porta do banco diretamente na internet. O problema que resolve: dar acesso pratico via navegador a um console de DB, mas atras de duas barreiras de seguranca encadeadas (rede privada Tailscale + login SSO no Authentik), de modo que apenas operadores autorizados e dentro da rede privada consigam abrir a UI.

## 🧱 Stack tecnologica
- **Orquestracao:** Docker Compose (stack declarativa, sem build proprio)
- **Aplicacao:** CloudBeaver — imagem oficial `dbeaver/cloudbeaver:latest`
- **Reverse proxy / TLS:** Traefik (entrypoint websecure, servindo o wildcard compartilhado `*.daberga.com` via `tls=true`, sem `certresolver` proprio)
- **Autenticacao:** Authentik (forward-auth via middleware `authentik@docker`)
- **Rede privada:** Tailscale (aplicada pelo middleware `internal-only@docker`)
- **Banco alvo:** PostgreSQL (externo a esta stack, acessado pela rede `bergatrix-db-internal`)

## 📦 Servicos / Containers
Stack de um unico servico.

| Campo | Valor |
|---|---|
| Servico / container | `cloudbeaver` |
| Imagem | `dbeaver/cloudbeaver:latest` (sem pin de versao) |
| Build | Nenhum (imagem oficial) |
| Portas | `8978` interna; **nao publicada no host** — exposta so via Traefik (`loadbalancer.server.port=8978`) |
| Volumes | `${STORAGE_PATH}/cloudbeaver:/opt/cloudbeaver/workspace` |
| Redes | `bergatrix-proxy`, `bergatrix-db-internal` (ambas `external: true`) |
| depends_on | Nenhum |
| restart | `unless-stopped` |
| healthcheck | Nao definido |
| deploy (GPU/limites) | Nao definido |
| Labels Traefik | `traefik.enable=true`; `traefik.docker.network=bergatrix-proxy`; router `cloudbeaver` em ``Host(`db.${DOMAIN}`)``; `entrypoints=websecure`; `tls=true`; `middlewares=internal-only@docker,authentik@docker`; `services.cloudbeaver.loadbalancer.server.port=8978` |

## 🌐 Dominios / Roteamento
- **Hostname:** `https://db.${DOMAIN}`
- **Entrypoint:** `websecure` (HTTPS), `tls=true` (sem `certresolver`) — serve o wildcard compartilhado `*.daberga.com` do Traefik; nao emite certificado individual.
- **Middlewares (ordem):** `internal-only@docker` (exige presenca na rede Tailscale) e `authentik@docker` (exige login no SSO) — **ambos devem passar** para a rota abrir.
- **Rede do proxy:** `traefik.docker.network=bergatrix-proxy` fixa por qual rede o Traefik fala com o container (necessario porque o servico esta em duas redes).
- Porta de servico interna usada pelo Traefik: `8978`.

## 📐 Regras de negocio
- **Defesa em profundidade dupla:** acesso so e concedido se o cliente estiver simultaneamente na rede Tailscale (`internal-only@docker`) E autenticado no Authentik (`authentik@docker`).
- **Somente HTTPS:** o router usa exclusivamente o entrypoint `websecure` com `tls=true`, servindo o wildcard compartilhado `*.daberga.com` (CA Let's Encrypt) do Traefik; nao emite certificado individual.
- **Sem exposicao de porta no host:** nenhuma porta e publicada; todo o trafego entra pelo Traefik na rede `bergatrix-proxy`.
- **Isolamento de rede:** o acesso ao Postgres ocorre apenas pela rede interna `bergatrix-db-internal`, separada da rede de proxy.

Nao ha cron, workers ou logica de aplicacao proprios — toda a "logica" e a politica de roteamento/seguranca declarada nas labels do Traefik.

## 🗄️ Modelo de dados
n/a (proprio). O CloudBeaver e um cliente de administracao; nao define schema proprio. Seu estado (conexoes salvas, usuarios da console, preferencias) vive no workspace persistido em `${STORAGE_PATH}/cloudbeaver` (montado em `/opt/cloudbeaver/workspace`). Os bancos administrados (Postgres global) sao externos a esta stack.

## 🔌 Endpoints / API
- `https://db.${DOMAIN}` — UI web do CloudBeaver (entrypoint websecure/TLS; porta interna 8978). Nao expoe API propria documentada nesta stack alem da UI.

## 🔗 Integracoes externas
- **Let's Encrypt** — CA do TLS; o certificado servido e o wildcard compartilhado `*.daberga.com`, emitido uma unica vez pela stack `01-network/traefik`. Esta app apenas o consome (via `tls=true`), nao emite certificado individual.
- **Tailscale** — rede privada de acesso, exigida pelo middleware `internal-only`.

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** — roteamento, TLS e os middlewares `internal-only@docker` e `authentik@docker`.
- **Authentik** — provedor do middleware `authentik@docker` (forward-auth SSO).
- **Postgres global** — alvo de administracao, alcancado por `bergatrix-db-internal` (nao definido na arvore canonica do repo).
- **Rede externa `bergatrix-proxy`** — deve existir previamente (`external: true`).
- **Rede externa `bergatrix-db-internal`** — deve existir previamente (`external: true`); **nao** consta no script `00-infrastructure/networks/networks.md`, que so cria `bergatrix-proxy` e `bergatrix-backend`.

## 🔑 Variaveis de ambiente necessarias
**Caminho / storage**
- `STORAGE_PATH`

**Dominio / roteamento**
- `DOMAIN`

(Apenas nomes; valores no `.env.example` sao placeholders.)

## 🗂️ Estrutura de codigo
- `docker-compose.yml` — define o unico servico `cloudbeaver`: imagem, volume de workspace, as duas redes externas e todas as labels do Traefik (router, TLS, middlewares de seguranca, porta).
- `.env.example` — template com 2 placeholders (`STORAGE_PATH`, `DOMAIN`); sem valores reais.

Nao ha Dockerfile, codigo-fonte, migrations nem scripts auxiliares — stack puramente declarativa.

## 🛡️ Gestao de segredos
- Nenhum segredo e definido no `docker-compose.yml` nem no `.env.example` (este traz so placeholders `caminho`/`dominio`).
- As credenciais de conexao aos bancos sao configuradas em runtime dentro do proprio CloudBeaver e ficam no workspace persistido (volume no host), fora do versionamento.
- **Nenhum segredo exposto encontrado** na arvore canonica desta stack. Nada a rotacionar.

## 🚧 Notas de evolucao / pendencias
- Imagem em `:latest` — sem pin de versao; recomenda-se fixar uma tag para reprodutibilidade.
- Sem `healthcheck` — Traefik nao tem sinal de readiness do container.
- Sem `depends_on` — assume Traefik/Authentik/Postgres ja no ar nas redes externas.
- A rede `bergatrix-db-internal` e `external` mas nao e criada por `networks.md`; um `docker compose up` falha se ela nao tiver sido criada manualmente antes. Vale alinhar a documentacao de redes.
- Sem bloco `deploy` (limites de recursos) — pouco critico para a ferramenta, mas poderia limitar consumo.

## ❓ Perguntas em aberto
- Onde/como a rede `bergatrix-db-internal` e criada? Ela e `external` no compose mas nao aparece em `00-infrastructure/networks/networks.md` (que so cria `bergatrix-proxy` e `bergatrix-backend`).
- Qual instancia de Postgres global o CloudBeaver administra e onde ela esta definida? Nao foi encontrada nenhuma definicao de servico Postgres na arvore canonica do repo.
- As conexoes de banco sao pre-provisionadas ou configuradas manualmente na primeira execucao via UI?
- Onde estao definidos os middlewares `internal-only@docker` e `authentik@docker` (provavelmente nas stacks de Traefik/Authentik fora deste diretorio)?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
