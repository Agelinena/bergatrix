# 🛡️ Bergatrix — Arquitetura de Rede & Segurança

> Como o tráfego entra, como as stacks se isolam e quais controles de segurança existem. Base para qualquer mudança de rede/exposição.

## 1. Topologia de rede (hub-and-spoke)
O **Traefik v3.6.2** (`01-network/traefik`) é o **único ingress**: publica as portas **80/443** no host, faz redirect `80 → 443` e descobre serviços via **Docker provider** com `exposedByDefault=false` (só roteia quem tem labels) e `network=bergatrix-proxy`.

### Redes Docker externas compartilhadas
| Rede | Tipo | Função | Quem usa |
|---|---|---|---|
| **`bergatrix-proxy`** | bridge (external) | Backbone de ingress — toda stack exposta se conecta aqui; Traefik enxerga os serviços | Traefik + ~15 stacks |
| **`bergatrix-db-internal`** | external | Acesso ao **Postgres global** do homelab | `cloudbeaver` |
| **`bergatrix-backend`** | external (declarada) | — **órfã**: criada no runbook mas não referenciada por nenhuma stack | ninguém (ver roadmap) |

> ⚠️ O runbook [`00-infrastructure/networks/networks.md`](stacks/networks.md) cria `bergatrix-proxy` e `bergatrix-backend`, mas **não** cria `bergatrix-db-internal` (consumida pelo cloudbeaver) nem `media-internal` (definida pelo próprio compose do jellyfin). Quem seguir a doc ao pé da letra falha ao subir o cloudbeaver.

### Redes internas por stack (defesa em profundidade)
Cada stack adiciona sua própria rede, muitas com **`internal: true`** (sem saída para a internet) para isolar bancos e workers:
- `authentik-internal`, `berganews-internal`, `litellm-internal`, `rss-internal`, `wazuh-internal`, `instaloader-internal`, `ghost-network`, etc.
- Sufixo **`-egress`** (bridge, com saída) quando o worker precisa alcançar a internet mas a API não: `litellm-egress`, `instaloader-egress`.
- `media-network` (nome real `media-internal`) conecta todos os serviços de mídia do jellyfin entre si.

**Padrão:** API na `*-internal` + `bergatrix-proxy`; banco só na `*-internal`; worker que precisa de internet na `*-egress`.

## 2. Traefik (ingress / TLS)
- **Entrypoints:** `web` (:80, redirect) e `websecure` (:443, TLS).
- **TLS:** certificado **wildcard `*.daberga.com`** via **Let's Encrypt** com **DNS-01 challenge** no provider **deSEC**. Resolvers nomeados: `letsencrypt` (maioria) e `production` (usado por `transcriptor` e `n8n` — confirmar se é o mesmo resolver com outro nome).
- **forwardedHeaders:** confia em `192.168.10.0/24` e `192.168.3.0/24` (LAN principal e backup).
- **Descoberta:** por labels Docker; cada serviço exposto declara `traefik.enable=true`, `traefik.docker.network=bergatrix-proxy`, um router `Host(...)` e um service `loadbalancer.server.port`.

### Middlewares de segurança (definidos na stack do Traefik)
| Middleware | O que faz | Quem usa |
|---|---|---|
| **`internal-only@docker`** | `ipAllowList` = `127.0.0.1/32` + `192.168.10.0/24` (LAN/Tailscale/OPNsense) — só acessa quem está na rede interna ou via VPN | berga-news, litellm, openuiweb, rss-ig, cloudbeaver, wazuh, e os 9 painéis do jellyfin |
| **`authentik@docker`** | **ForwardAuth** para o Authentik — exige login SSO antes de chegar à app | cloudbeaver, wazuh |

> **Padrão de exposição:** público (só `websecure`+TLS) para serviços de uso externo; `internal-only` para painéis administrativos e apps de uso pessoal; **`internal-only` + `authentik`** (dupla camada) para os mais sensíveis (cloudbeaver, wazuh).

## 3. Identidade & SSO — Authentik
- IdP/SSO self-hosted (`02-security/authentik`): serviços `server`, `worker`, `postgresql`, `redis`.
- Fornece **ForwardAuth** ao Traefik via `authentik@docker`, protegendo serviços de outras camadas sem que cada app implemente login.
- ⚠️ Nem todas as apps usam Authentik — várias têm **autenticação própria** (berga-news: sessão+cookie; transcriptor: cookie assinado + API key; bergastream: JWT próprio) ou **nenhuma** (rss-ig, alguns painéis), confiando apenas no `internal-only`.

## 4. Segredos — Vaultwarden
- `02-security/bitwarden` roda **Vaultwarden** (servidor compatível com Bitwarden, em Rust), exposto em `bitwarden.${DOMAIN}` com TLS Let's Encrypt.
- É o cofre de senhas pessoal — **não** é o mecanismo de injeção de segredos nas stacks (isso é feito via `.env`).

## 5. SIEM — Wazuh
- `04-monitoring/wazuh` (4.7.2 single-node): `indexer` (OpenSearch), `manager` (OSSEC+Filebeat), `dashboard`.
- Recebe eventos de agentes na **1514/tcp** e registra agentes na **1515/tcp** (`authd` **sem senha**).
- Dashboard protegido por **`internal-only` + Authentik**.
- ⚠️ Em configuração: `vulnerability-detector` e `active-response` inativos; **credenciais demo padrão versionadas** (ver §8 e roadmap).

## 6. Admin de banco — CloudBeaver
- `00-infrastructure/cloudbeaver`: console web para o **Postgres global**, alcançado pela rede `bergatrix-db-internal`.
- Protegido por **`internal-only` + Authentik**.

## 7. Estratégia de segredos
- **Injeção:** exclusivamente via **`.env`** por stack (`env_file` / interpolação `${VAR}` no compose). O **`.env` real nunca é versionado**; só o **`.env.example`** com placeholders.
- **Hashing:** senhas de usuário com **bcrypt** (berga-news, bergastream); cookies assinados com `itsdangerous` (transcriptor); JWT (bergastream).
- **`.gitignore`** bloqueia segredos, certificados, dados persistentes (`**/data/`, `**/db_data/`, `**/volumes/`, `**/backups/`, `**/downloads/`, `**/storage/`) e `**/AdGuardHome.yaml`.
- ⚠️ **4 apps sem `.env.example`** (litellm, n8n, openuiweb, transcriptor) — dificulta reprodução.

## 8. Exposições conhecidas (rotacionar) 🔴
> Apenas **localizações** — nenhum valor é reproduzido. Tratar antes de qualquer exposição externa.

| Local | Problema | Ação |
|---|---|---|
| `04-monitoring/wazuh/config/wazuh_dashboard/wazuh.yml` | Senha em texto plano do usuário de API `wazuh-wui` (valor **demo** do Wazuh) versionada | Trocar por valor próprio e rotacionar |
| `04-monitoring/wazuh/config/wazuh_indexer/internal_users.yml` | Hashes bcrypt de usuários internos **demo** versionados | Substituir por hashes próprios |
| `04-monitoring/wazuh/config/wazuh_cluster/wazuh_manager.conf` | Chave de cluster `<key>` hardcoded (cluster `disabled`) | Rotacionar se habilitar cluster |
| `berga-news` — `POST /admin/users` | Senha de novo usuário exposta na **querystring** do redirect (vaza em logs) | Corrigir para não passar segredo em URL |

## 9. Recomendações de hardening (priorizadas)
| Prioridade | Recomendação |
|:---:|---|
| 🔴 Alta | Trocar/rotacionar as credenciais demo do Wazuh (§8) antes de expor o dashboard |
| 🔴 Alta | Resolver os marcadores de conflito de merge no `LICENSE` (arquivo versionado quebrado) |
| 🟠 Média | Corrigir o runbook de redes (incluir `bergatrix-db-internal` e `media-internal`); remover/usar a rede órfã `bergatrix-backend` |
| 🟠 Média | Padronizar autenticação: avaliar pôr atrás do Authentik as apps hoje só com `internal-only` (rss-ig sem auth de app) |
| 🟠 Média | Adicionar `.env.example` às 4 stacks que faltam |
| 🟡 Baixa | Definir healthchecks no Wazuh (`depends_on` hoje só `service_started`) |
| 🟡 Baixa | Confirmar/unificar o nome do certresolver (`letsencrypt` vs `production`) |

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a estrutura evoluir._
