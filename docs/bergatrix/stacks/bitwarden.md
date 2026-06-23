# bitwarden — Gerenciador de senhas auto-hospedado (Vaultwarden) exposto via Traefik com o wildcard TLS compartilhado *.daberga.com

> **Categoria:** security | **Caminho:** `02-security/bitwarden` | **Status:** documented

## 🎯 Finalidade
Cofre de senhas/segredos pessoal e familiar self-hosted, substituindo serviços comerciais de gerenciamento de senhas. Roda o **Vaultwarden** (`vaultwarden/server:latest`), uma reimplementação leve em Rust da API do Bitwarden, compatível com todos os clientes oficiais (extensões de navegador, apps mobile/desktop e CLI). O cadastro público de novos usuários está desabilitado (`SIGNUPS_ALLOWED=false`), tornando-o um cofre fechado. Suporta sincronização/notificações em tempo real entre dispositivos via WebSocket. É uma stack puramente de infraestrutura declarativa — não há código de aplicação versionado, apenas `docker-compose.yml` e `.env.example`.

## 🧱 Stack tecnológica
- **Vaultwarden** (servidor compatível com Bitwarden, escrito em Rust) — imagem oficial `vaultwarden/server:latest`
- **Docker Compose** (orquestração)
- **Traefik** (reverse proxy e terminação TLS)
- **Let's Encrypt** (CA do wildcard compartilhado `*.daberga.com`, emitido pela stack `01-network/traefik`; esta app apenas consome via `tls=true`)
- **WebSocket** para notificações push entre dispositivos
- **SQLite** (banco embutido padrão do Vaultwarden, dentro de `/data`)

## 📦 Serviços / Containers

| Campo | Valor |
|---|---|
| **Serviço** | `vaultwarden` (container_name: `bitwarden`) |
| **Imagem** | `vaultwarden/server:latest` |
| **Portas** | interno **80** (HTTP/API, via Traefik) e interno **3012** (WebSocket `/notifications/hub`, via Traefik). Nenhuma porta publicada diretamente no host. |
| **Volumes** | `${STORAGE_PATH}/vaultwarden:/data` |
| **Redes** | `bergatrix-proxy` (external) |
| **depends_on** | — (nenhum) |
| **restart** | `unless-stopped` |
| **healthcheck** | nenhum definido |
| **deploy / recursos** | nenhum limite de CPU/memória definido |
| **Labels Traefik** | `traefik.enable=true`, `traefik.docker.network=bergatrix-proxy`; dois roteadores (principal + WebSocket) — ver seção de roteamento |

## 🌐 Domínios / Roteamento
Exposto publicamente via Traefik (entrypoint `websecure`, servindo o wildcard compartilhado `*.daberga.com`). Dois roteadores:

- **`vaultwarden-router`** (principal): `Host(\`bitwarden.${DOMAIN}\`)` → service `vaultwarden-service` (porta **80**). `entrypoints=websecure`, `tls=true` (sem `certresolver` — consome o wildcard compartilhado, não emite cert individual).
- **`vaultwarden-ws-router`** (WebSocket): `Host(\`bitwarden.${DOMAIN}\`) && PathPrefix(\`/notifications/hub\`)` → service `vaultwarden-ws-service` (porta **3012**). `entrypoints=websecure`, `tls=true` (sem `certresolver` — consome o wildcard compartilhado, não emite cert individual).

> **Middleware `internal-only@docker` está COMENTADO em ambos os roteadores** (linhas 26 e 35 do `docker-compose.yml`). Atualmente o serviço fica exposto publicamente apenas com TLS + ADMIN_TOKEN, sem restrição de rede interna.

## 📐 Regras de negócio
- **`SIGNUPS_ALLOWED=false`** — registro público de novas contas desabilitado; cofre fechado.
- **`WEBSOCKET_ENABLED=true`** — sincronização em tempo real entre dispositivos, dependente do roteamento de `/notifications/hub` para a porta 3012.
- **`DOMAIN=https://bitwarden.${DOMAIN}`** — URL canônica fixada via HTTPS; necessária para gerar links/notificações e validar origem.
- **Painel `/admin`** protegido pelo `ADMIN_TOKEN` (recurso da imagem Vaultwarden).
- **`TZ=America/Sao_Paulo`** — fuso para logs/timestamps locais.

## 🗄️ Modelo de dados
O Vaultwarden persiste tudo em **SQLite** (`db.sqlite3`) dentro de `/data`, mapeado para `${STORAGE_PATH}/vaultwarden` no host. Além do banco, o diretório guarda anexos, chaves RSA de assinatura, configuração do painel admin e cache de ícones. **Nenhum banco externo** (PostgreSQL/MySQL) está configurado — não há variável de URL de banco no compose.

## 🔌 Endpoints / API
- **API Bitwarden padrão** servida internamente na porta 80 (roteada por `Host(\`bitwarden.${DOMAIN}\`)`). Consumida pelos clientes oficiais Bitwarden.
- **WebSocket de notificações** na porta interna 3012 (rota `/notifications/hub`).
- **Painel administrativo `/admin`** protegido por `ADMIN_TOKEN` (fornecido pela imagem; habilitado pela presença do token).

## 🔗 Integrações externas
- **Let's Encrypt** — CA do TLS; o certificado servido é o wildcard compartilhado `*.daberga.com`, emitido uma única vez pela stack `01-network/traefik`. Esta app apenas consome esse wildcard (via `tls=true`), não emite certificado individual.
- **Clientes oficiais Bitwarden** (extensões de navegador, apps mobile/desktop, CLI) que consomem a API compatível.

## 🧩 Dependências internas (Bergatrix)
- **Traefik** (reverse proxy compartilhado) — roteamento, TLS e terminação HTTPS via labels.
- **Rede Docker externa `bergatrix-proxy`** (declarada como `external: true`).
- **Wildcard compartilhado `*.daberga.com`** (CA Let's Encrypt) emitido pela stack `01-network/traefik`; esta app apenas o consome via `tls=true`, sem `certresolver` próprio.

## 🔑 Variáveis de ambiente necessárias
Resolvidas do `.env` do host (interpoladas no compose):
- `STORAGE_PATH`
- `DOMAIN`
- `ADMIN_TOKEN`

> As demais variáveis do container — `SIGNUPS_ALLOWED`, `TZ`, `WEBSOCKET_ENABLED` — são **valores literais fixos** no `docker-compose.yml`, não variáveis do `.env`.

## 🗂️ Estrutura de código
- **`docker-compose.yml`** — definição do serviço `vaultwarden`: imagem, volume `/data`, rede `bergatrix-proxy`, variáveis de ambiente e labels Traefik (dois roteadores e dois serviços).
- **`.env.example`** — template de variáveis; declara `STORAGE_PATH` e `DOMAIN` como placeholders e traz `ADMIN_TOKEN` comentado com um valor de exemplo.

Não há código-fonte de aplicação; toda a lógica (cofre, criptografia, sincronização) vem da imagem oficial não versionada.

## 🛡️ Gestão de segredos
Segredos e parâmetros de host são injetados por variáveis de ambiente resolvidas de um `.env` no host (não versionado): apenas `${STORAGE_PATH}`, `${DOMAIN}` e `${ADMIN_TOKEN}` são interpolados. O **`ADMIN_TOKEN`** é o segredo mais sensível (protege o painel `/admin`). Nenhum valor real de segredo está presente nos arquivos versionados.

> ⚠️ **Localização a revisar:** `02-security/bitwarden/.env.example` contém um valor de **placeholder** de `ADMIN_TOKEN` (comentado). É um exemplo, não um segredo de produção — mas confirme que esse valor nunca foi reutilizado como token real; se foi, **rotacione o ADMIN_TOKEN**. Recomenda-se usar um token forte e único e manter o placeholder claramente fictício.

## 🚧 Notas de evolução / pendências
- Middleware `internal-only@docker` **comentado** em ambos os roteadores (linhas 26 e 35) — decidir se a exposição pública é intencional ou se deveria restringir ao acesso interno.
- Imagem fixada em **`:latest`** (sem pin de versão) — prejudica reprodutibilidade e pode trazer mudanças inesperadas em pulls futuros.
- **Sem healthcheck** definido.
- **Sem limites de recursos** (`deploy.resources`) definidos.
- **`.env.example` incompleto**: declara só `STORAGE_PATH` e `DOMAIN` e deixa `ADMIN_TOKEN` comentado. Como o compose referencia `${ADMIN_TOKEN}` sem default, subir sem defini-lo no `.env` real resultará em token vazio (painel `/admin` potencialmente desprotegido/desabilitado).

## ❓ Perguntas em aberto
- A exposição pública é intencional, ou o middleware `internal-only@docker` deveria estar ativo?
- Há rotina externa de **backup** do volume `${STORAGE_PATH}/vaultwarden` (SQLite + chaves de criptografia)?
- Existe rotação/gestão do `ADMIN_TOKEN`, dado que o painel `/admin` é acessível publicamente via HTTPS?
- O valor de placeholder de `ADMIN_TOKEN` no `.env.example` já foi usado como token real em algum ambiente?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
