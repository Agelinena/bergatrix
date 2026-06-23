# openuiweb — Open WebUI (interface estilo ChatGPT) auto-hospedada como "Bergatrix AI", conectada ao LiteLLM e a um Ollama local com GPU NVIDIA, exposta em chat.${DOMAIN} mas restrita a LAN

> **Categoria:** app | **Caminho:** `03-apps/openuiweb` | **Status:** documented

## 🎯 Finalidade
Stack de frontend de IA conversacional do homelab Bergatrix. Roda a imagem oficial `open-webui/open-webui` (interface web tipo ChatGPT) sob a marca **"Bergatrix AI"**, oferecendo simultaneamente duas fontes de modelos:

1. O gateway **LiteLLM** da stack `03-apps/litellm`, via endpoint OpenAI-compatible (`http://litellm:4000/v1`), que por sua vez roteia para provedores externos como OpenRouter.
2. Um daemon **Ollama** local rodando no mesmo compose, com aceleracao GPU NVIDIA, para inferencia on-premise.

O modelo padrao pre-selecionado e `deepseek-v3`. O cadastro publico esta desabilitado e a autenticacao e obrigatoria. Embora tenha um hostname publico (`chat.${DOMAIN}`) servido pelo wildcard `*.daberga.com` compartilhado do Traefik (via `tls=true`, sem certresolver proprio; CA Let's Encrypt), o acesso e restrito a LAN pelo middleware `internal-only@docker` do Traefik — ou seja, e um servico de uso interno, sem exposicao a internet publica.

## 🧱 Stack tecnologica
- **Open WebUI** — `ghcr.io/open-webui/open-webui:main` (UI conversacional)
- **Ollama** — `ollama/ollama:latest` (servidor de inferencia LLM local)
- **GPU NVIDIA** via NVIDIA Container Toolkit
- **Docker Compose** (orquestracao)
- **Traefik** (reverse proxy, TLS via wildcard `*.daberga.com` compartilhado / CA Let's Encrypt, ipallowlist) — stack `01-network/traefik`
- **LiteLLM** (gateway OpenAI-compatible) — stack separada `03-apps/litellm`

Stack puramente de infraestrutura: nao ha codigo-fonte proprio, apenas imagens upstream.

## 📦 Servicos / Containers

| Aspecto | open-webui | ollama |
|---|---|---|
| Imagem | `ghcr.io/open-webui/open-webui:main` | `ollama/ollama:latest` |
| Porta interna | 8080 (apenas via Traefik; sem mapeamento de host) | 11434 (apenas rede interna; sem mapeamento de host) |
| Volumes | `${OPENWEBUI_DATA_DIR}:/app/backend/data` | `${DATA_DIR}:/root/.ollama` |
| Redes | `bergatrix-proxy` (external) | `bergatrix-proxy` (external) |
| depends_on | nenhum declarado (dependencia logica de litellm/ollama resolvida por DNS) | nenhum |
| restart | `unless-stopped` | `unless-stopped` |
| healthcheck | nenhum | nenhum |
| deploy / GPU | sem reserva de recursos | `reservations.devices`: driver nvidia, `count: all`, capabilities `[gpu]` (reserva TODAS as GPUs) |
| Labels Traefik | sim (ver secao de roteamento) | nenhuma (nao exposto) |
| DNS | `1.1.1.1`, `8.8.8.8` | padrao |

Observacao: o `open-webui` **nao** reserva GPU — toda a inferencia local com GPU fica no servico `ollama`.

## 🌐 Dominios / Roteamento
Apenas o `open-webui` e roteado pelo Traefik:

- **Router** `openwebui`: `rule=Host(\`chat.${DOMAIN}\`)`
- **Entrypoint:** `websecure`
- **TLS:** `tls=true` — serve o wildcard `*.daberga.com` compartilhado do Traefik (sem `certresolver` proprio; nao emite certificado individual; CA Let's Encrypt)
- **Middleware:** `internal-only@docker` — ipallowlist do Traefik (definido na stack `01-network/traefik`) que so permite origens `127.0.0.1/32` e a LAN `192.168.10.0/24`
- **Service port:** `loadbalancer.server.port=8080`

O `ollama` **nao** tem labels Traefik e e acessivel apenas internamente em `http://ollama:11434`.

## 📐 Regras de negocio
- Cadastro de novos usuarios desabilitado (`ENABLE_SIGNUP=false`) — contas criadas/administradas internamente.
- Autenticacao obrigatoria para uso (`WEBUI_AUTH=true`).
- Marca/produto apresentado ao usuario: **"Bergatrix AI"** (`WEBUI_NAME`).
- Modelo padrao pre-selecionado: `deepseek-v3` (`DEFAULT_MODELS`).
- Dois back-ends de modelos disponiveis ao mesmo tempo: LiteLLM (remoto, OpenAI-compatible) e Ollama (local, GPU); API Ollama explicitamente habilitada (`ENABLE_OLLAMA_API=true`).
- Acesso a interface restrito a LAN pelo middleware `internal-only`, apesar do hostname publico.

Nao ha cron, workers ou agendamentos nesta stack.

## 🗄️ Modelo de dados
Nao ha modelo de dados proprio (imagens prontas). O estado e persistido em volumes:
- **Open WebUI:** usuarios, contas, historico de chats, configuracoes e uploads em SQLite/arquivos dentro de `${OPENWEBUI_DATA_DIR}` (montado em `/app/backend/data`).
- **Ollama:** modelos baixados e blobs em `${DATA_DIR}` (montado em `/root/.ollama`).

Nenhum banco de dados externo e declarado para esta stack (o Postgres pertence a stack `litellm`).

## 🔌 Endpoints / API
- `http://litellm:4000/v1` — consumido como `OPENAI_API_BASE_URL` (gateway LiteLLM).
- `http://ollama:11434` — consumido como `OLLAMA_BASE_URL` (API Ollama local).
- `open-webui` escuta internamente em `:8080` (roteado pelo Traefik).
- `ollama` escuta internamente em `:11434` (nao exposto externamente).

## 🔗 Integracoes externas
- **Let's Encrypt** — CA do wildcard `*.daberga.com` (emitido uma unica vez pela stack Traefik); o open-webui apenas consome esse cert via `tls=true`, sem emitir o proprio.
- **DNS publico** `1.1.1.1` / `8.8.8.8` — configurado no servico open-webui.
- **Provedores externos de LLM** (ex.: OpenRouter) — alcancados indiretamente atraves do gateway LiteLLM; nao chamados diretamente por esta stack.

## 🧩 Dependencias internas (Bergatrix)
- **`01-network/traefik`** — reverse proxy, terminacao TLS via wildcard `*.daberga.com` compartilhado (consumido com `tls=true`, sem certresolver proprio; CA Let's Encrypt) e middleware `internal-only@docker` (ipallowlist `192.168.10.0/24` + `127.0.0.1/32`).
- **`03-apps/litellm`** — gateway LLM OpenAI-compatible; o open-webui usa o servico `litellm` (`http://litellm:4000/v1`) e reutiliza a `LITELLM_MASTER_KEY` como chave de API.
- **Rede Docker externa `bergatrix-proxy`** — compartilhada pelos dois servicos; e onde o servico `litellm` de outra stack e resolvido por DNS.

## 🔑 Variaveis de ambiente necessarias
**Variaveis de ambiente do container open-webui:**
- `WEBUI_SECRET_KEY`
- `WEBUI_NAME` (literal: "Bergatrix AI")
- `OPENAI_API_BASE_URL` (literal: http://litellm:4000/v1)
- `OPENAI_API_KEY` (valor interpolado de `${LITELLM_MASTER_KEY}`)
- `ENABLE_OLLAMA_API` (literal: true)
- `OLLAMA_BASE_URL` (literal: http://ollama:11434)
- `ENABLE_SIGNUP` (literal: false)
- `WEBUI_AUTH` (literal: true)
- `DEFAULT_MODELS` (literal: deepseek-v3)

**Variaveis de ambiente do container ollama:**
- `NVIDIA_VISIBLE_DEVICES` (literal: all)
- `NVIDIA_DRIVER_CAPABILITIES` (literal: compute,utility)

**Variaveis de interpolacao do compose (vem do `.env`, nao sao env vars de container):**
- `OPENWEBUI_DATA_DIR` (caminho do volume open-webui)
- `DATA_DIR` (caminho do volume ollama)
- `WEBUI_SECRET_KEY` (segredo)
- `LITELLM_MASTER_KEY` (segredo; interpolado como valor de OPENAI_API_KEY)
- `DOMAIN` (hostname no label Traefik)

## 🗂️ Estrutura de codigo
Stack minima, sem codigo-fonte proprio. Apenas dois arquivos na arvore canonica:
- **`docker-compose.yml`** — define os servicos `open-webui` e `ollama`, a rede externa `bergatrix-proxy` e as labels Traefik.
- **`.gitignore`** — ignora apenas `.env`.

Toda a logica de aplicacao vem das imagens upstream. O nome do diretorio `openuiweb` e uma variacao/abreviacao de "Open WebUI".

## 🛡️ Gestao de segredos
Todos os segredos vem de um arquivo `.env` **nao versionado** (o `.gitignore` ignora explicitamente `.env`). Nenhum valor de segredo esta hardcoded no `docker-compose.yml` — apenas referencias `${...}`.

- `WEBUI_SECRET_KEY` — chave de assinatura de sessao do Open WebUI.
- `LITELLM_MASTER_KEY` — interpolada como valor de `OPENAI_API_KEY` para autenticar no gateway LiteLLM; **compartilhada** com a stack `litellm`.

**Nenhum segredo exposto/commitado foi encontrado.** Caso seja necessaria rotacao, ela deve ser feita no `.env` e coordenada com a stack `litellm` (a mesma `LITELLM_MASTER_KEY` e usada nas duas stacks).

## 🚧 Notas de evolucao / pendencias
- O comentario no volume do Ollama menciona centralizar a pasta do "Mimesis" no mesmo volume `${DATA_DIR}` — intencao de reaproveitar dados, mas sem configuracao explicita para esse projeto nesta stack.
- **Sem `depends_on`:** o open-webui pode subir antes de litellm/ollama estarem prontos; a resolucao e apenas por DNS na rede compartilhada.
- Comentarios em portugues com emojis no compose ("🔌 ATIVADO", "🟢 OLLAMA COM SUPORTE A GPU") sugerem ativacao recente/manual do suporte a Ollama e GPU.
- Uso de **tags rolantes** (`:main` e `:latest`) para ambas as imagens — sem pin de versao, builds reproduziveis nao garantidos.
- **Sem healthcheck** em nenhum dos servicos — falhas de inicializacao/runtime nao sao detectadas automaticamente.

## ❓ Perguntas em aberto
- Como as GPUs NVIDIA sao compartilhadas entre o Ollama (`count=all`) e outras stacks que usam GPU no homelab (ex.: jellyfin optimizer NVENC)? Pode haver contencao de recursos.
- A quais caminhos fisicos no host as variaveis `DATA_DIR` e `OPENWEBUI_DATA_DIR` apontam, e ha sobreposicao com o volume do projeto "Mimesis" citado no comentario?
- O modelo padrao `deepseek-v3` e servido via LiteLLM (remoto) ou via Ollama (local)? O compose nao deixa explicito.
- Por que o hostname e publico (`chat.${DOMAIN}`, servido pelo wildcard `*.daberga.com` via `tls=true`, sem certresolver proprio; CA Let's Encrypt) se o acesso e restrito a LAN pelo middleware `internal-only`? Provavelmente TLS interno via DNS split-horizon — nao confirmado nesta stack.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
