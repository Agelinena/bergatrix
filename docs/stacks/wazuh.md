# wazuh — Plataforma SIEM/XDR (Wazuh 4.7.2) auto-hospedada para monitoramento de segurança, detecção de intrusão e conformidade

> **Categoria:** monitoring | **Caminho:** `04-monitoring/wazuh` | **Status:** Ativo (em configuração) — `wazuh.${DOMAIN}`

## 🎯 Finalidade
Stack de monitoramento de segurança (SIEM/XDR) baseada no **Wazuh 4.7.2** em deploy **single-node** Docker. Coleta e analisa eventos de segurança de agentes instalados em hosts, com módulos habilitados de:
- **Rootcheck** (detecção de rootkits/trojans/portas) a cada 12h;
- **Syscollector** (inventário de hardware/OS/rede/pacotes/processos) a cada 1h;
- **Syscheck/FIM** (integridade de arquivos em `/etc`, `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`, `/boot`) a cada 12h com alerta de novos arquivos;
- **SCA** (Security Configuration Assessment) a cada 12h;
- **Detecção de vulnerabilidades** (módulo globalmente **desabilitado**, mas com providers `msu`/Windows e `nvd` marcados enabled internamente).

Recebe eventos de agentes via **TCP 1514** e registra novos agentes via `wazuh-authd` na **1515**. O **OpenSearch** (indexer) armazena os dados e o **dashboard** (OpenSearch Dashboards/Kibana) provê a UI, exposta via Traefik (protegida por `internal-only` + Authentik). Comandos de active-response existem (disable-account, firewall-drop, host-deny, route-null, netsh) mas o bloco está **comentado/inativo**. Cluster definido porém **desabilitado** (single-node).

## 🧱 Stack tecnologica
- **Wazuh 4.7.2:** `wazuh-indexer` (OpenSearch), `wazuh-manager` (OSSEC + Filebeat), `wazuh-dashboard` (OpenSearch Dashboards/Kibana)
- Docker Compose; **Traefik** (reverse proxy); **Authentik** (forward-auth)
- OpenSSL (geração de certificados TLS), Java/JVM (`OPENSEARCH_JAVA_OPTS`), Bash (`cert.sh`, `fix-permissions.sh`)

## 📦 Servicos / Containers

| Aspecto | wazuh-indexer | wazuh-manager | wazuh-dashboard |
|---|---|---|---|
| Imagem | `wazuh/wazuh-indexer:4.7.2` | `wazuh/wazuh-manager:4.7.2` | `wazuh/wazuh-dashboard:4.7.2` |
| Portas | nenhuma no host (9200/9300 internos) | **1514/tcp** (eventos), **1515/tcp** (authd) | 5601 (só interno, via Traefik) |
| Redes | `wazuh-internal` (alias `wazuh.indexer`) [internal: true] | `wazuh-internal` (alias `wazuh.manager`) [internal: true], `wazuh-egress` [bridge] | `bergatrix-proxy` + `wazuh-internal` [internal: true] |
| depends_on | — | indexer (service_healthy) | indexer + manager (service_healthy) |
| restart | unless-stopped | unless-stopped | unless-stopped |
| Healthcheck | **Sim** (curl em `_cat/health` para `green\|yellow`) | **Sim** (`wazuh-control status`) | **Sim** (curl HTTP em `:5601`) |
| Traefik | — | — | `Host(wazuh.${DOMAIN})`, websecure, `tls=true` (wildcard `*.daberga.com`); mw `internal-only@docker` + `authentik@docker`; backend HTTPS `:5601` via serversTransport `wazuh-transport` (`insecureSkipVerify=true`) |

Notas:
- **Indexer:** OpenSearch single-node, JVM heap fixo `1g`, `ulimits memlock unlimited`/`nofile 65536`, SSL HTTP/transport habilitado, `admin_dn=CN=admin`. Possui custom `entrypoint` no compose que gera dinamicamente os hashes de senha das variáveis de ambiente (`INDEXER_PASSWORD` e `DASHBOARD_PASSWORD`) e os insere no `internal_users.yml` no boot.
- **Manager:** DNS 8.8.8.8/1.1.1.1 (para feeds NVD/MSU); Filebeat envia ao indexer com verificação SSL `full`; `ossec.conf` monta config de cluster (`name=wazuh`, `node01/master`, `disabled=yes`); `authd` **sem senha** (`use_password=no`) e `ssl_verify_host=no`; API (`wazuh-wui`) em `:55000` interno. Possui acesso à internet via rede `wazuh-egress`.
- **Dashboard:** `defaultRoute /app/wazuh`, multitenancy desabilitado; conecta no indexer com `verificationMode=certificate` e na API do manager (`https://wazuh.manager:55000`) como `wazuh-wui`; HTTPS próprio com cert autoassinado (daí o `insecureSkipVerify` no Traefik). Possui custom `entrypoint` que copia a configuração e substitui a senha da API com o valor de `API_PASSWORD` do `.env` no boot.

## 🌐 Dominios / Roteamento
- `wazuh.${DOMAIN}` → `wazuh-dashboard:5601` (HTTPS interno)
- **Dupla proteção:** `internal-only@docker` (restrito à rede interna/LAN) **+** `authentik@docker` (SSO forward-auth) **antes** de chegar ao login do Wazuh

## 📐 Regras de negocio
- **Ingestão:** eventos de agentes via TCP **1514**; registro de agentes via `wazuh-authd` na **1515**.
- **Registro de agentes (authd):** **sem senha** (`use_password=no`), **sem verificação de host** (`ssl_verify_host=no`), `purge=yes` (agentes removidos são expurgados).
- **Desconexão:** agente considerado offline após 10m (`agents_disconnection_time=10m`); alerta imediato (`alert_time=0`).
- **Níveis de alerta:** registro a partir do nível 3 (`log_alert_level`); email a partir do 12 (email desabilitado).
- **Rootcheck** a cada 12h (43200s), pulando NFS.
- **Syscollector** a cada 1h com scan no start; portas: só escutando (`all=no`).
- **Syscheck/FIM:** monitora `/etc`, `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`, `/boot` a cada 12h; alerta em novos arquivos; ignora `.log`/`.swp` e `private.key` (sem diff).
- **SCA** habilitado, a cada 12h, scan no start.
- **Vulnerability-detector** globalmente **DESABILITADO** (`enabled=no`) apesar de providers `msu`/`nvd` enabled; CIS-CAT e osquery desabilitados.
- **Active-response:** comandos definidos (disable-account, restart-wazuh, firewall-drop, host-deny, route-null, win_route-null, netsh) mas o bloco está **comentado** (inativo).
- **Comandos locais periódicos** (cada 360s): `df -P`, netstat de portas em escuta, `last -n 20`.
- **Saída:** alertas em JSON (`jsonout_output=yes`); `logall`/`logall_json` desabilitados.

## 🗄️ Modelo de dados
Sem banco relacional/SQL nem migrations. Dados são **índices OpenSearch** geridos pelo `wazuh-indexer` (alertas, inventário syscollector, eventos FIM, etc.), persistidos em `${STORAGE_PATH}/wazuh/indexer`. Config/estado do manager em `${STORAGE_PATH}/wazuh/manager_etc`; logs em `…/manager_logs`. Índices de segurança do OpenSearch (`.opendistro-*`, `.opensearch-observability`) declarados como `system_indices`.

## 🔌 Endpoints / API
- **Dashboard UI:** `https://wazuh.${DOMAIN}` (Traefik → dashboard:5601, HTTPS interno)
- **Manager API (interna):** `https://wazuh.manager:55000` (usuário `wazuh-wui`)
- **Indexer (interno):** `https://wazuh.indexer:9200` (OpenSearch, usuário `admin`)
- **Eventos de agentes:** `tcp://0.0.0.0:1514`
- **Registro de agentes (authd):** `tcp://0.0.0.0:1515`
- **Cluster (interno, desabilitado):** porta 1516

## 🔗 Integracoes externas
- **NVD** (National Vulnerability Database) — feed de vulnerabilidades (provider `nvd` enabled, via DNS 8.8.8.8/1.1.1.1)
- **Microsoft MSU** — feed de vulnerabilidades Windows (provider `msu` enabled)
- **Let's Encrypt** — CA do wildcard `*.daberga.com` consumido via `tls=true` no Traefik (o dashboard consome o wildcard compartilhado; não emite cert individual)
- **SMTP** (notificação por email) — configurado mas **DESABILITADO** (`email_notification=no`, valores de exemplo `smtp.example.wazuh.com`)

## 🧩 Dependencias internas (Bergatrix)
- **Traefik** (`01-network/traefik`): ingress, rede externa `bergatrix-proxy`, `tls=true` consumindo o wildcard `*.daberga.com` (CA Let's Encrypt, emitido pela stack do Traefik), entrypoint `websecure`
- **Authentik** (`02-security/authentik`): SSO via middleware `authentik@docker` (forward-auth) protegendo o dashboard
- **Middleware `internal-only@docker`** — restringe o dashboard a redes internas/LAN
- **Rede `bergatrix-proxy`** (external)
- **`${STORAGE_PATH}`** — storage persistente compartilhado (volumes `wazuh/indexer`, `wazuh/manager_etc`, `wazuh/manager_logs`)

## 🔑 Variaveis de ambiente necessarias
- `STORAGE_PATH`, `DOMAIN`
- `WAZUH_PASSWORD`, `WAZUH_API_PASSWORD`, `WAZUH_KIBANA_PASSWORD`

(Apenas nomes — nenhum valor é exibido. Internamente o compose também referencia `INDEXER_USERNAME/PASSWORD`, `DASHBOARD_USERNAME/PASSWORD`, `API_USERNAME/PASSWORD` e variáveis de SSL.)

## 🗂️ Estrutura de codigo
Stack puramente declarativa/de configuração (sem código de aplicação próprio). `docker-compose.yml` na raiz define os 3 serviços + rede externa `bergatrix-proxy` e interna `wazuh-internal`. `config/` por componente:
- `wazuh_cluster/wazuh_manager.conf` — `ossec.conf` (regras de negócio dos módulos)
- `wazuh_dashboard/` — `opensearch_dashboards.yml`, `wazuh.yml`
- `wazuh_indexer/` — `wazuh.indexer.yml`, `internal_users.yml`
- `wazuh_indexer_ssl_certs/` — certificados
- Scripts: `cert.sh` (gera CA + certs TLS por nó com SAN) e `fix-permissions.sh` (chmod/chown dos certs); `certs.yml` documenta a topologia de nós.

## 🛡️ Gestao de segredos
- Senhas e domínio injetados via `.env` (`env_file` + `${VAR}`); `.env.example` versionado com placeholders. Certificados TLS gerados localmente por `cert.sh` (CA raiz autoassinada + certs por nó com SAN) e montados como volumes; `fix-permissions.sh` ajusta permissões (chmod 400/500, chown 1000:1000).
- Os arquivos versionados `wazuh.yml` e `internal_users.yml` contêm apenas placeholders ou hashes padrão (de desenvolvimento). A stack injeta os valores reais do `.env` na memória do container no boot através de custom entrypoints, resolvendo a vulnerabilidade de exposição de credenciais em produção no repositório Git.
- ⚠️ **Exposições conhecidas (rotacionar):**
  - `04-monitoring/wazuh/config/wazuh_cluster/wazuh_manager.conf` — **chave de cluster** `<key>` hardcoded (cluster está `disabled`, mas rotacionar se for habilitado).

## 🚧 Notas de evolucao / pendencias
- **Inconsistência:** `vulnerability-detector` com `enabled=no` no nível raiz mesmo com providers `nvd`/`msu` enabled — a detecção efetivamente **não roda**.
- **Active-response** totalmente comentado — respostas automáticas (ex: firewall-drop) não são acionadas apesar dos comandos definidos.
- **Email** desabilitado e com valores de exemplo — não configurado de fato.
- **Cluster `disabled=yes`** (single-node) — escalável a multi-node no futuro.

## ❓ Perguntas em aberto
- Os certs TLS (gerados por `cert.sh`) são versionados ou gerados no deploy? Só `root-ca.srl` está no repo; os `.pem`/`.key` referenciados não aparecem na árvore (provavelmente gerados em runtime).
- A senha de API hardcoded em `wazuh.yml` deve coincidir com `WAZUH_API_PASSWORD` do `.env`? Como são reconciliadas?
- O módulo de detecção de vulnerabilidades deveria estar ativo? (`enabled=no` contradiz providers habilitados).
- Quais hosts/agentes do homelab efetivamente reportam a este manager? Não há inventário no repo.
- Integrar alertas a algum canal (email/Slack/n8n)? Email está com placeholders e desabilitado.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
