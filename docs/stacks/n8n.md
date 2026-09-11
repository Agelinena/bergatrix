# n8n — Plataforma de automação de workflows self-hosted, com imagem customizada (Python/yt-dlp) e execução de comandos habilitada

> **Categoria:** app | **Caminho:** `03-apps/n8n` | **Status:** active

## 🎯 Finalidade
Disponibiliza uma instância self-hosted do **n8n** — ferramenta de automação low-code/no-code orientada a workflows, webhooks e integrações — para o homelab Bergatrix. A imagem oficial `n8nio/n8n:latest` é estendida via `Dockerfile.n8n` para suportar Python 3 e bibliotecas de extração de conteúdo, permitindo que os workflows façam scraping/extração de transcrições e download de vídeos do YouTube, criptografia e (potencialmente) automação de browser. Resolve a necessidade de orquestrar automações e integrações entre serviços do homelab sem depender de SaaS externo, mantendo dados e credenciais sob controle próprio. A UI/editor é exposta em HTTPS atrás do Traefik no domínio `N8N_DOMAIN`.

## 🧱 Stack tecnologica
- **n8n** (base `n8nio/n8n:latest`, Node.js)
- **Docker / Docker Compose** (serviço único com build local)
- **Dockerfile customizado**: `COPY --from=alpine:3.22` traz os binários/dados do `apk` para dentro da imagem n8n (base Debian), habilitando a instalação de pacotes via apk
- **Python 3 + pip** (`py3-pip`) instalado na imagem
- Bibliotecas Python: **yt-dlp**, **youtube-transcript-api**, **cryptography**
- **Playwright** permitido como módulo externo (download de browser desabilitado)
- **SQLite** (persistência padrão do n8n no volume)
- **Traefik** (reverse proxy / terminação TLS)

## 📦 Servicos / Containers
Serviço único `n8n`:

| Aspecto | Valor |
|---|---|
| Imagem | Build local a partir de `Dockerfile.n8n` (base `n8nio/n8n:latest`) |
| Build | context `.`; copia apk de `alpine:3.22`; `apk add python3 py3-pip`; `pip3 install --break-system-packages youtube-transcript-api yt-dlp cryptography`; `mkdir -p /scripts && chmod 777 /scripts`; ENV `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` e `N8N_ALLOW_EXEC=true`; finaliza com `USER node` |
| Portas | Nenhuma publicada no host; porta interna **5678** exposta apenas ao Traefik |
| Volumes | `${N8N_DATA_DIR}:/home/node/.n8n` |
| Redes | `bergatrix-proxy` (external) |
| depends_on | — |
| restart | `unless-stopped` |
| healthcheck | nenhum definido |
| deploy (GPU/limites) | nenhum |
| DNS | `8.8.8.8` (Google), `1.1.1.1` (Cloudflare) |
| Labels Traefik | `traefik.enable=true`; router `n8n-service` → `Host(${N8N_DOMAIN})`, entrypoint `websecure`, `tls=true`; loadbalancer porta `5678` |

## 🌐 Dominios / Roteamento
- Hostname: `${N8N_DOMAIN}` (interpolado de variável de ambiente do host).
- Regra Traefik: `Host(\`${N8N_DOMAIN}\`)` no entrypoint `websecure` (HTTPS) com `tls=true` (sem `certresolver`) — serve o **wildcard `*.daberga.com`** compartilhado do Traefik, não emite certificado individual.
- Backend: loadbalancer aponta para a porta interna `5678` do container.
- **Sem middlewares de autenticação** declarados no compose — o acesso à UI depende exclusivamente do Traefik/rede a montante.

## 📐 Regras de negocio
- **Nenhuma regra de negócio versionada no repositório.** Os workflows (que contêm toda a lógica: nós, webhooks, integrações, agendamentos/cron) residem no volume de dados em runtime (`N8N_DATA_DIR`) e não foram exportados para o código.
- A customização da imagem é o único indício de uso: yt-dlp + youtube-transcript-api (extração/download do YouTube), `cryptography` (operações criptográficas), Playwright permitido (automação de browser), e `N8N_ALLOW_EXEC=true` + `child_process` em `NODE_FUNCTION_ALLOW_BUILTIN` (execução de comandos/scripts Python a partir dos nós Code).

## 🗄️ Modelo de dados
Não há modelo de dados versionado. O n8n persiste workflows, credenciais e execuções em `/home/node/.n8n` (mapeado para `${N8N_DATA_DIR}` no host). Por padrão usa **SQLite** nesse diretório — nenhum banco externo (Postgres/MySQL) é configurado no compose. As credenciais são criptografadas com `N8N_ENCRYPTION_KEY`.

## 🔌 Endpoints / API
- **Webhook base:** `WEBHOOK_URL=https://${N8N_DOMAIN}/` — os endpoints concretos de webhook dependem dos workflows definidos em runtime (não versionados).
- **UI/editor n8n:** porta interna `5678` (`N8N_PORT=5678`), acessível apenas via Traefik.

## 🔗 Integracoes externas
- **YouTube** — via `yt-dlp` e `youtube-transcript-api` (download de vídeo e extração de transcrições).
- **Let's Encrypt / ACME** — indiretamente via Traefik; a CA continua sendo o Let's Encrypt, mas o app **consome o wildcard `*.daberga.com`** (via `tls=true`, sem `certresolver`) em vez de emitir cert próprio.
- **DNS público** — Google (`8.8.8.8`) e Cloudflare (`1.1.1.1`) configurados no container.
- **Registries de imagem** — `n8nio/n8n:latest` (base) e `alpine:3.22` (origem do apk no build).

## 🧩 Dependencias internas (Bergatrix)
- **traefik** — depende do reverse proxy Bergatrix para roteamento HTTPS e emissão de certificado TLS.
- **Rede externa `bergatrix-proxy`** — compartilhada com os demais serviços da stack.

## 🔑 Variaveis de ambiente necessarias
Requeridas no host (`.env` não versionado neste diretório):
- `N8N_DOMAIN`
- `TIMEZONE`
- `N8N_ENCRYPTION_KEY`
- `N8N_DATA_DIR`

Definidas/derivadas no compose (apenas nomes):
- `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`, `NODE_ENV`, `WEBHOOK_URL`, `GENERIC_TIMEZONE`
- `VUE_APP_EXPLORE_DISABLE`
- `NODE_FUNCTION_ALLOW_BUILTIN`, `NODE_FUNCTION_ALLOW_EXTERNAL`, `NODE_PATH`
- `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`, `N8N_PROXY_HOPS`

Definidas no `Dockerfile.n8n` (apenas nomes):
- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`, `N8N_ALLOW_EXEC`

## 🗂️ Estrutura de codigo
Apenas dois arquivos versionados (confirmado via `git ls-files`):
- **`03-apps/n8n/docker-compose.yml`** — define o serviço único `n8n`: build local, variáveis de ambiente, volume de dados, labels do Traefik, DNS explícito e rede externa.
- **`03-apps/n8n/Dockerfile.n8n`** — estende `n8nio/n8n:latest`: copia o `apk` de `alpine:3.22`, instala Python 3 + bibliotecas (yt-dlp, youtube-transcript-api, cryptography), cria `/scripts` com chmod 777, define ENVs (`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, `N8N_ALLOW_EXEC=true`) e retorna ao `USER node`.

A lógica de negócio (workflows) não está no repositório — vive no volume `N8N_DATA_DIR`.

## 🛡️ Gestao de segredos
- A chave de criptografia do n8n é injetada via `N8N_ENCRYPTION_KEY`, referenciada apenas como `${N8N_ENCRYPTION_KEY}` no compose (**sem valor literal**), resolvida de um `.env` não versionado.
- As credenciais dos workflows são criptografadas pelo n8n com essa chave e persistidas no volume `N8N_DATA_DIR`.
- **Nenhum `.env` ou `.env.example` versionado** em `03-apps/n8n` (confirmado). **Nenhum valor de segredo aparece** no compose nem no Dockerfile.
- Recomendações: manter o `.env` fora do controle de versão; manter a `N8N_ENCRYPTION_KEY` estável e com backup seguro (sua perda inutiliza todas as credenciais salvas).

## 🚧 Notas de evolucao / pendencias
- **Sem healthcheck** definido para o serviço.
- **Persistência em SQLite** (padrão) — ponto de evolução para Postgres caso o uso cresça (recomendação oficial do n8n em produção).
- **Tags `latest`** (`n8nio/n8n:latest` e `alpine:3.22` no `COPY --from`) tornam o build pouco reprodutível — recomenda-se fixar versões.
- **Postura de segurança permissiva:** `N8N_ALLOW_EXEC=true`, `child_process` permitido, `/scripts` com chmod 777 e `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false` ampliam a superfície de execução de código arbitrário a partir dos workflows. Aceitável para homelab, mas crítico se a UI for exposta sem autenticação.
- **Playwright sem browser:** `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` significa que nenhum browser é baixado na imagem — a automação via Playwright só funcionará se um browser estiver disponível por outro meio (possível parte incompleta).

## ❓ Perguntas em aberto
- Quais workflows reais estão ativos? Regras de negócio, webhooks, integrações com IA/LLM e agendamentos/cron não estão versionados (vivem só no volume) e não são auditáveis pelo repo.
- Há integração com `litellm` ou outro provedor de IA/LLM nos workflows?
- O n8n permanece em SQLite ou foi reconfigurado para banco externo via variáveis adicionais no `.env`?
- Playwright está realmente operacional, dado que nenhum browser é instalado na imagem?
- A UI do editor está protegida a montante (middleware Traefik / Authentik / basic-auth)? Não há autenticação configurada no compose.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
