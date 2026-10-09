# drop — Transferência segura e efêmera de mensagens/segredos entre dois dispositivos, com criptografia ponta-a-ponta no navegador e servidor como relay zero-knowledge.

> **Categoria:** app | **Caminho:** `03-apps/drop` | **Status:** documented

## 🎯 Finalidade
O **drop** é um app web de página única (SPA) para transferir um segredo (senha, token, mensagem curta) entre dois dispositivos de forma **efêmera** e com **criptografia ponta-a-ponta (E2EE)**.

O fluxo tem dois papéis:
- **Receptor**: abre o app, gera um **código de 20 caracteres** e um **QR Code**, e fica aguardando uma conexão segura via WebSocket.
- **Emissor**: digita o código, lê o QR Code pela câmera, ou entra por deep link (`#code=...`), criptografa a mensagem no próprio navegador e a envia.

O navegador cifra o texto com AES-256-GCM e deriva a chave e o `session_id` a partir do código via PBKDF2. O backend funciona como relay e mantém apenas conexões em memória por no máximo 10 minutos. Isso protege o conteúdo contra leitura casual pelo processo relay, mas **não** contra comprometimento do servidor que entrega `index.html`/`app.js`, do navegador ou do dispositivo; esses componentes podem observar o código e o texto em claro. O serviço é público e não possui conta/login.

## 🧱 Stack tecnológica
- **Backend:** Python 3.11 (imagem `python:3.11-slim`), **FastAPI**, **Uvicorn** (`uvicorn[standard]`), biblioteca **websockets**.
- **Frontend:** HTML (`index.html`), CSS (`app.css`) e JavaScript (`app.js`) vanilla, **Web Crypto API** (SubtleCrypto: PBKDF2, AES-GCM, SHA-256).
- **Libs de QR (CDN):** `qrcodejs` 1.0.0 e `html5-qrcode` 2.3.8, com versão fixada e SRI.
- **Fontes:** Google Fonts (Manrope e Space Mono).
- **Infra:** Docker (build local), Traefik para TLS/roteamento.

## 📦 Serviços / Containers
Stack com um único serviço.

| Atributo | Valor |
|---|---|
| **Serviço** | `drop` (container_name fixo `drop`) |
| **Build** | `context: .` + `Dockerfile` (FROM python:3.11-slim, instala `app/requirements.txt`, copia `app/`, `CMD uvicorn server:app --host 0.0.0.0 --port 8000`) |
| **Imagem** | build local (sem imagem publicada) |
| **Portas** | `8000` apenas `EXPOSE` no container; **sem bloco `ports:`** — nada publicado no host, acesso só via Traefik |
| **Volumes** | nenhum |
| **Redes** | `bergatrix-proxy` (`external: true`) |
| **depends_on** | nenhum |
| **restart** | `unless-stopped` |
| **healthcheck** | `GET /healthz`, a cada 30s |
| **recursos** | limite de 256 MiB RAM, 1 CPU e 100 processos |
| **segurança do container** | usuário não-root, filesystem read-only, `cap_drop: ALL`, `no-new-privileges`, `/tmp` temporário e `pids_limit: 100` |

## 🌐 Domínios / Roteamento
Exposto **exclusivamente via Traefik** (não há porta publicada no host). Labels confirmadas no compose:
- `traefik.enable=true`
- Router `drop-router` com regra `Host(\`drop.${DOMAIN}\`)`
- `entrypoints=websecure`, `tls=true` (sem `certresolver`) — consome o wildcard `*.daberga.com` compartilhado do Traefik; não emite certificado individual
- Service `drop-service` com `loadbalancer.server.port=8000`

Como o WebSocket usa o mesmo host, o tráfego WSS também passa pelo Traefik e pelo rate limit. A média é 30 requisições/minuto por origem, com burst 10. Não há autenticação; o código é a capacidade de acesso à sessão.

## 📐 Regras de negócio
- **Relay criptografado:** o processo backend recebe e encaminha ciphertext; o origin que serve o JavaScript ainda pode observar código e texto em claro.
- **Código de conexão:** 20 caracteres do alfabeto sem ambiguidades `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (32 símbolos) → 100 bits de entropia. Gerado com `crypto.getRandomValues()`.
- **Derivação:** a partir do código derivam-se (1) a chave **AES-256-GCM** via **PBKDF2** (SHA-256, **100.000 iterações**, salt **fixo** `drop-secure-salt`) e (2) o `session_id` = hex do SHA-256 do código.
- **Cifragem:** cada mensagem usa **IV aleatório de 12 bytes** (`crypto.getRandomValues`); o pacote transmitido é `base64(IV || ciphertext)`.
- **Timeout de sessão:** 600s absolutos a partir da criação, sem extensão por atividade. Uma tarefa periódica limpa sessões expiradas; o cliente também expira o estado após 10 min.
- **Limites de abuso:** máximo de 2.048 sessões ativas, 20 mensagens/minuto por sessão e 16 KiB por mensagem.
- **Single Listener:** apenas um WebSocket por `session_id`. Nova conexão enquanto há WS ativo é rejeitada com `close(code=1008, reason="Session busy")`. O `disconnect()` zera o WS (`websocket=None`) mas **mantém a sessão**, permitindo reconexão (ex: F5) dentro do timeout.
- **Entrega não garantida:** se o Receptor não tem WS conectado no momento do envio, a mensagem **não é entregue** (`Receiver not connected`); não há fila/buffer/retry.
- **Keep-alive:** o cliente Receptor envia `"ping"` a cada 30s para manter o WebSocket ativo; frames maiores que 1 KiB são rejeitados e o ping não estende a validade absoluta de 10 minutos.
- **Persistência de UX no cliente:** `sessionStorage['drop_app_state']` guarda `{mode, code, sessionId, timestamp}` para restaurar a sessão na aba atual (dentro de 10 min). A chave não é exportada nem persistida; é derivada novamente do código e mantida não extraível em memória.
- **Entradas do Emissor:** código digitado (20 chars, convertido para upper-case), QR pela câmera (html5-qrcode) ou deep link `#code=` (o QR aponta para `origin + '/#code=' + code`).
- **Conveniências do Receptor:** mostrar/ocultar conteúdo, copiar para clipboard e "Limpar Área de Transferência" (exige `window.isSecureContext` / HTTPS).

## 🗄️ Modelo de dados
Sem banco e sem persistência em disco. Todo estado fica em memória do processo:

```
ConnectionManager.sessions: Dict[session_id -> Session]
Session = {websocket, created_at, sent_at, send_lock}
```

`session_id` = SHA-256 (hex) do código de 20 chars. No cliente, estado efêmero em `sessionStorage['drop_app_state']`: `{mode:'receiver'|'sender', code, sessionId, timestamp}`. Reinício do container apaga todas as sessões ativas.

## 🔌 Endpoints / API
- **`GET /`** — retorna o `index.html` com CSP, `no-store`, anti-frame e `nosniff`.
- **`GET /app.js`** — serve o JavaScript same-origin, sem handlers inline.
- **`GET /app.css`** — serve os estilos locais da aplicação.
- **`GET /healthz`** — healthcheck do container.
- **`WebSocket /ws/{session_id}`** — canal do Receptor. Aplica Single Listener e expiração absoluta da sessão.
- **`POST /api/send/{session_id}`** — valida ID, Base64 e tamanho antes de encaminhar. Retorna `409` sem receptor, `413` para payload grande, `422` inválido ou `429` por excesso de mensagens.

## 🔗 Integrações externas
Dependências de **runtime no navegador** (CDNs de terceiros), nenhuma no backend; scripts têm versão fixada e integridade SRI:
- `cdnjs.cloudflare.com` — qrcodejs 1.0.0
- `unpkg.com` — html5-qrcode 2.3.8
- `fonts.googleapis.com` — fontes Manrope e Space Mono

## 🧩 Dependências internas (Bergatrix)
- **traefik** — reverse proxy e terminação TLS servindo o wildcard `*.daberga.com` compartilhado via `tls=true` (CA Let's Encrypt; o cert é emitido uma única vez pela stack do Traefik, este app só o consome); roteia `drop.${DOMAIN}` (HTTPS/WSS).
- **rede `bergatrix-proxy`** — rede Docker externa compartilhada da stack.

Nenhuma dependência de banco, Redis, Authentik ou LiteLLM.

## 🔑 Variáveis de ambiente necessárias
**Compose / infra:**
- `DOMAIN`

Não há outras variáveis. `DOMAIN` é usada apenas no label de roteamento do Traefik.

## 🗂️ Estrutura de código
Stack mínima e autocontida:

- `docker-compose.yml` — um serviço `drop`, rede externa `bergatrix-proxy`, labels Traefik.
- `Dockerfile` — Python 3.11-slim, instala `app/requirements.txt`, copia `app/`, expõe 8000, roda uvicorn.
- `.env.example` — somente `DOMAIN=example.com` (placeholder).
- `app/server.py` — backend FastAPI, validação e limites de sessão/payload.
- `app/index.html`, `app/app.css` e `app/app.js` — UI e lógica do navegador, sem JavaScript inline ou framework CSS remoto.
- `app/requirements.txt` — `fastapi`, `uvicorn[standard]`, `websockets` (sem versões fixadas).
- `tests/test_server.py` — testes para expiração, capacidade, rate limit e validação do envio.

Sem banco, migrations ou integração com IA/LLM.

## 🛡️ Gestão de segredos
- **Nenhum segredo de aplicação/credencial** no stack. A única variável é `DOMAIN` (não sensível); `.env.example` traz apenas `DOMAIN=example.com`.
- **Nenhum segredo real commitado** foi encontrado nos arquivos canônicos (compose, Dockerfile, .env.example, server.py, index.html). `secretsExposed` vazio.
- A página e o JavaScript são servidos pelo mesmo host público que opera o relay. Um origin comprometido pode alterar `app.js` para capturar código, chave ou texto em claro; E2EE não protege contra o próprio origin que entrega o cliente.
- O código é uma credencial bearer: compartilhe-o apenas com o destinatário e não o reutilize.
- O texto descriptografado é apagado da tela após 60 segundos, mas navegador, sistema operacional, clipboard e extensões podem manter cópias.
- A política CSP bloqueia scripts e handlers inline; `unsafe-inline` em estilos permanece para compatibilidade com o QRCode gerado pelo cliente.

## 🚧 Limites conhecidos
- Não há autenticação de usuário nem fila de mensagens; o código é a credencial da sessão e o receptor precisa estar conectado.
- O rate limit do Traefik é por origem e pode afetar usuários atrás do mesmo NAT.
- Estado de sessão é local ao processo; múltiplas réplicas não compartilham sessões e reinício apaga sessões ativas.
- `requirements.txt` ainda não fixa versões; builds não são totalmente reprodutíveis.
- Scripts externos continuam sendo dependências de confiança, embora fixados por versão e SRI.

## ❓ Perguntas em aberto
- As versões Python ainda não estão fixadas; incluir um lockfile tornaria os builds reproduzíveis.
- O envio só funciona com o receptor online; uma fila futura precisaria definir retenção, consumo único e limites de privacidade.
- Dependências frontend locais eliminariam a confiança de runtime nos CDNs.
- Uma auditoria independente é recomendada antes de usar o serviço para segredos de alto impacto.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
