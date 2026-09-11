# traefik — Reverse proxy / ingress central do homelab Bergatrix (Traefik v3.6.2) com TLS wildcard automatico via Let's Encrypt e DNS-01 challenge no deSEC.

> **Categoria:** network | **Caminho:** `01-network/traefik` | **Status:** active

## 🎯 Finalidade
E o ponto unico de entrada HTTP/HTTPS de todo o homelab Bergatrix. Escuta nas portas 80 e 443, redireciona automaticamente todo o trafego HTTP (entrypoint `web`) para HTTPS (entrypoint `websecure`) e termina TLS com um certificado **wildcard `*.daberga.com`** emitido pelo Let's Encrypt. Descobre dinamicamente os servicos a expor lendo o socket do Docker (provider `docker`, `exposedByDefault=false`) e roteia conforme labels declaradas em cada stack downstream. Resolve o problema de expor de forma segura e centralizada dezenas de servicos internos sob um unico dominio com TLS gerenciado automaticamente — sendo dependencia obrigatoria para a exposicao web de praticamente todo o restante do Bergatrix.

## 🧱 Stack tecnologica
- **Traefik v3.6.2** (imagem oficial `traefik:v3.6.2`, versao pinada)
- **Docker / Docker Compose** (orquestracao e service discovery via socket)
- **Let's Encrypt (ACME)** para emissao de certificados
- **DNS-01 challenge via deSEC** (provider `desec`)
- **TLS wildcard** (`*.daberga.com`)
- Configuracao **YAML estatica** (`config/traefik.yml`, carregada via flag `--configFile=/traefik.yml` no compose) + **dinamica via labels Docker** (e um `config/config.yml` orfao — ver pendencias)

Nao ha codigo de aplicacao: o stack e puramente declarativo.

## 📦 Servicos / Containers
Servico unico no compose:

| Item | Valor |
|---|---|
| **Servico** | `traefik` |
| **Imagem** | `traefik:v3.6.2` |
| **Portas** | `80:80`, `443:443` |
| **Volumes** | `/var/run/docker.sock:/var/run/docker.sock:ro` · `./config/traefik.yml:/traefik.yml:ro` · `./config/acme.json:/acme.json` |
| **Redes** | `bergatrix-proxy` (external) |
| **depends_on** | nenhum |
| **restart** | `unless-stopped` |
| **healthcheck** | nenhum definido |
| **deploy / recursos** | sem limites de recurso/GPU; `security_opt: no-new-privileges:true`; `dns: 9.9.9.9, 149.112.112.112` (Quad9) |
| **Labels Traefik** | `traefik.enable=true`; `traefik.http.middlewares.internal-only.ipallowlist.sourcerange=127.0.0.1/32, 192.168.10.0/24` |

Observacao: `acme.json` e referenciado como volume mas e **criado em runtime** (nao versionado).

## 🌐 Dominios / Roteamento
- **Entrypoint `web` (:80)** — redireciona todo o trafego para `websecure` com `scheme: https`.
- **Entrypoint `websecure` (:443)** — termina TLS com `certResolver: letsencrypt`, dominio `main: daberga.com` + SAN `*.daberga.com`.
- **`forwardedHeaders.trustedIPs`**: `127.0.0.1/32`, `192.168.10.0/24` (rede interna, inclui gateway OPNsense), `192.168.3.0/24` (rede backup).
- **Provider docker**: `exposedByDefault=false`, `network: bergatrix-proxy` — so roteia containers com `traefik.enable=true`.
- **Router `dashboard`** (em `config/config.yml`): aponta para `api@internal`, `entrypoints: websecure`, `tls`, `priority: 100`, `Host({SUBDOMAIN_TRAEFIK_DASHBOARD})`. **Atencao:** este arquivo nao e montado no container e nao ha provider `file` em `traefik.yml`, entao o dashboard provavelmente **nao esta ativo** (ver pendencias).
- **Middleware `internal-only`** (ipallowlist via label) — definido aqui, mas so tem efeito se referenciado por um router downstream.

## 📐 Regras de negocio
- Todo trafego HTTP (:80) e redirecionado para HTTPS (:443).
- Certificado **wildcard unico** (`*.daberga.com`, dominio `daberga.com`) compartilhado por todos os subdominios do homelab.
- **Estrategia de certificado = wildcard:** os apps downstream **nao emitem certificado individual**. Cada router usa apenas `tls=true` (**sem** `tls.certresolver`), herdando o wildcard `*.daberga.com` ja emitido aqui. Isso elimina uma emissao ACME por subdominio e o risco de rate limit do Let's Encrypt.
- Emissao do wildcard **exclusivamente via DNS-01** (deSEC), `delayBeforeChecks: 60s`, com `LEGO_DISABLE_CNAME_SUPPORT=true` no environment e resolvers apontando para o **autoritativo do deSEC** (`ns1.desec.io:53` e `ns2.desec.org:53`). Os resolvers publicos (`1.1.1.1`/`8.8.8.8`) foram abandonados porque a rede sequestrava DNS publico na porta 53 — a correcao definitiva foi uma regra NAT **No RDR (NOT)** no OPNsense liberando o DNS do servidor (`192.168.10.10`); ver causa-raiz em [networks.md](networks.md) e [01-arquitetura-rede-seguranca.md](../01-arquitetura-rede-seguranca.md). **Sem essa regra, a renovacao automatica do certificado volta a falhar (~60 dias).**
- **CA staging/producao (toggle):** usa a CA de **producao** do Let's Encrypt por padrao. Ha uma linha `caServer` de **staging comentada** em `traefik.yml` — descomente no servidor para testar a emissao sem gastar o rate limit de producao (certs de staging nao sao confiaveis no browser). Ao voltar para producao, **apague o `acme.json`** para reemitir certificados validos.
- **Opt-in de exposicao**: `exposedByDefault=false` — container so e roteado com `traefik.enable=true`.
- Confianca em headers `X-Forwarded-*` restrita aos `trustedIPs` (gateway e redes internas).
- Endurecimento do container: `no-new-privileges:true`, socket Docker **read-only** (`:ro`), DNS fixado em **Quad9** (`9.9.9.9`/`149.112.112.112`) — upstream que a rede ja utiliza e nao sequestra, evitando o problema dos resolvers publicos.

## 🗄️ Modelo de dados
n/a — nao ha banco nem modelo de negocio. O unico estado persistido e `acme.json` (conta ACME + certificados TLS). Roteamento e estado de servicos vivem em memoria, derivados das labels do socket Docker.

## 🔌 Endpoints / API
- `web :80` — redireciona tudo para `websecure`.
- `websecure :443` — TLS wildcard com certResolver `letsencrypt`.
- `api@internal` (dashboard/API do Traefik) — exposto pelo router `dashboard` em `config/config.yml`, porem **provavelmente inativo** por falta de carregamento da config dinamica.
- Demais rotas: descobertas dinamicamente via labels Docker dos stacks downstream.

## 🔗 Integracoes externas
- **Let's Encrypt (ACME)** — emissao de certificados TLS wildcard.
- **deSEC** (provider DNS `desec`) — DNS-01 challenge, via `DESEC_TOKEN`/`DESEC_DOMAIN`.
- **Quad9 (`9.9.9.9` / `149.112.112.112`)** — DNS do container (upstream que a rede ja usa e nao sequestra).
- **Autoritativo deSEC (`ns1.desec.io` / `ns2.desec.org`)** — resolvers consultados pelo ACME para validar o DNS-01 challenge, contornando o sequestro de DNS publico na rede.

## 🧩 Dependencias internas (Bergatrix)
- **Rede externa `bergatrix-proxy`** (`external: true`) — backbone de ingress consumido por **15 stacks downstream** alem do proprio traefik: `03-apps/jellyfin`, `03-apps/bergastream`, `03-apps/openuiweb`, `03-apps/berga-news`, `03-apps/drop`, `03-apps/ghostmap`, `03-apps/litellm`, `03-apps/n8n`, `03-apps/rss-ig`, `03-apps/rss`, `03-apps/transcriptor`, `02-security/authentik`, `02-security/bitwarden`, `00-infrastructure/cloudbeaver`, `04-monitoring/wazuh`.
- **Docker daemon** (socket `/var/run/docker.sock`, `:ro`) — provider de service discovery.
- Stacks downstream declaram routers com apenas `tls=true` (entrypoint `websecure`, `traefik.docker.network=bergatrix-proxy`) e **sem `certresolver`** — assim usam o wildcard `*.daberga.com` emitido por esta stack, em vez de pedir um certificado individual. (Antes da migracao usavam `tls.certresolver=letsencrypt`/`production`, removido em jun/2026.)

## 🔑 Variaveis de ambiente necessarias
Definidas em `.env` (nao versionado; ha `.env.example` com placeholders):
- **deSEC / ACME:** `DESEC_TOKEN`, `DOMAIN` (mapeado para `DESEC_DOMAIN` no container). O compose tambem define `LEGO_DISABLE_CNAME_SUPPORT=true` (impede o lego de seguir CNAME ao resolver `_acme-challenge` — valor fixo, nao e segredo).
- **Dashboard (em `config/config.yml`, atualmente nao carregado):** `SUBDOMAIN_TRAEFIK_DASHBOARD`, `TRAEFIK_USER`, `TRAEFIK_PASSWORD`

(Apenas nomes — nunca valores.)

## 🗂️ Estrutura de codigo
- `docker-compose.yml` — define o servico `traefik`: `command: --configFile=/traefik.yml` (carrega a config estatica), montagens, `dns: 9.9.9.9/149.112.112.112` (Quad9), `security_opt`, labels e a rede externa `bergatrix-proxy`. Passa `DESEC_TOKEN`, `DESEC_DOMAIN` e `LEGO_DISABLE_CNAME_SUPPORT=true` ao container.
- `config/traefik.yml` — **config estatica** (montada `/traefik.yml:ro`, carregada via `--configFile=/traefik.yml`): `log.level: DEBUG`; entrypoints `web`/`websecure` com redirect 80->443; wildcard TLS `main: daberga.com` + `*.daberga.com`; `forwardedHeaders.trustedIPs`; provider `docker` (`exposedByDefault=false`); `certificatesResolvers.letsencrypt` com `dnsChallenge` deSEC (resolvers `ns1.desec.io:53`/`ns2.desec.org:53`, `delayBeforeChecks: 60s`, linha `caServer` de staging comentada).
- `config/config.yml` — **config dinamica pretendida**: router `dashboard` -> `api@internal` e middleware basicAuth `auth`. **Orfa**: nao e montada no container e nao ha provider `file`.
- `.env.example` — template de variaveis com placeholders comentados.
- `config/acme.json` — storage de certificados, **criado em runtime** (nao versionado).

## 🛡️ Gestao de segredos
- Segredos injetados exclusivamente via variaveis de ambiente a partir de um `.env` **nao versionado**. Ha apenas `.env.example` com placeholders comentados.
- No compose: `DESEC_TOKEN` -> env `DESEC_TOKEN`; `DOMAIN` -> env `DESEC_DOMAIN`. Credenciais do dashboard e o subdominio sao referenciados em `config/config.yml` via `${...}`/`{...}`.
- **Nenhum segredo real encontrado hardcoded ou commitado:** nao existem `.env` nem `acme.json` versionados (verificado).
- Endurecimento: socket Docker montado **read-only** (`:ro`) e `no-new-privileges:true`.
- Recomendacao geral: garantir `chmod 600` no `acme.json` em runtime.

## 🚧 Notas de evolucao / pendencias
- **`config/config.yml` orfa:** o compose monta apenas `traefik.yml` e `acme.json`, e `traefik.yml` nao declara provider `file`. Logo o **dashboard e o middleware basicAuth `auth` provavelmente nao estao ativos**. Falta montar o arquivo e habilitar o provider file.
- Mesmo se carregada, a config dinamica usa templating (`${TRAEFIK_USER}:${TRAEFIK_PASSWORD}`, `{SUBDOMAIN_TRAEFIK_DASHBOARD}`) — o **provider file do Traefik nao interpola env nativamente**, exigindo `envsubst` ou outro pre-processamento.
- Middleware `internal-only` definido por label, mas **so tem efeito se referenciado por um router downstream**.
- `log.level: DEBUG` — recomenda-se `INFO`/`WARN` em producao.
- **Sem healthcheck e sem limites de recurso** no container.
- Versao pinada (`v3.6.2`) exige atualizacao manual de seguranca.

## ❓ Perguntas em aberto
- O `config/config.yml` (dashboard + basicAuth) e realmente carregado em algum ambiente? Como esta, parece inativo — confirmar se ha montagem/provider file faltando ou um deploy diferente do versionado.
- O middleware `internal-only` chega a ser aplicado a algum router downstream?
- Como o `acme.json` e provisionado/permissionado na primeira execucao (chmod 600)?
- O redirect global 80->443 interfere em eventuais challenges HTTP-01 de outros stacks? (Aqui o challenge e DNS-01, entao provavelmente ok.)

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
