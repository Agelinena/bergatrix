# drop — Transferência segura e efêmera de mensagens/segredos entre dois dispositivos, com criptografia ponta-a-ponta no navegador e servidor como relay zero-knowledge.

> **Categoria:** app | **Caminho:** `03-apps/drop` | **Status:** documented

## 🎯 Finalidade
O **drop** é um app web de página única (SPA) para transferir um segredo (senha, token, mensagem curta) entre dois dispositivos de forma **efêmera** e com **criptografia ponta-a-ponta (E2EE)**.

O fluxo tem dois papéis:
- **Receptor**: abre o app, gera um **código de 8 caracteres** e um **QR Code**, e fica aguardando uma conexão segura via WebSocket.
- **Emissor**: digita o código, lê o QR Code pela câmera, ou entra por deep link (`#code=...`), criptografa a mensagem no próprio navegador e a envia.

O ponto central é o modelo **zero-knowledge**: a chave AES-256-GCM e o `session_id` são derivados **inteiramente no cliente** a partir do código, via PBKDF2. O servidor FastAPI nunca recebe a chave nem o texto em claro — ele apenas **repassa o payload já criptografado** do Emissor para o WebSocket do Receptor. As sessões vivem só na memória do processo por até 10 minutos de inatividade. Caso de uso típico: passar um segredo rapidamente entre celular e desktop sem que nenhum servidor trafegue o conteúdo legível.

## 🧱 Stack tecnológica
- **Backend:** Python 3.11 (imagem `python:3.11-slim`), **FastAPI**, **Uvicorn** (`uvicorn[standard]`), biblioteca **websockets**.
- **Frontend:** SPA single-file (`index.html`), HTML/CSS/JS vanilla, **Tailwind CSS** via Play CDN, **Web Crypto API** (SubtleCrypto: PBKDF2, AES-GCM, SHA-256).
- **Libs de QR (CDN):** `qrcodejs` 1.0.0 (geração) e `html5-qrcode` (leitura via câmera).
- **Fontes:** Google Fonts (Inter).
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
| **healthcheck** | nenhum |
| **deploy** | nenhum (sem GPU / limites de recurso) |
| **security_opt** | `no-new-privileges:true` |

## 🌐 Domínios / Roteamento
Exposto **exclusivamente via Traefik** (não há porta publicada no host). Labels confirmadas no compose:
- `traefik.enable=true`
- Router `drop-router` com regra `Host(\`drop.${DOMAIN}\`)`
- `entrypoints=websecure`, `tls=true` (sem `certresolver`) — consome o wildcard `*.daberga.com` compartilhado do Traefik; não emite certificado individual
- Service `drop-service` com `loadbalancer.server.port=8000`

Como o WebSocket usa o mesmo host, o tráfego WSS também passa pelo Traefik. Sem middlewares declarados (sem autenticação, sem rate limiting).

## 📐 Regras de negócio
- **Relay zero-knowledge:** o servidor nunca vê chave nem texto em claro; cripto e descripto ocorrem só no navegador.
- **Código de conexão:** 8 caracteres do alfabeto sem ambiguidades `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (32 símbolos, sem I/O/0/1) → ~40 bits de entropia. Gerado com `Math.random()` (não com gerador criptográfico).
- **Derivação:** a partir do código derivam-se (1) a chave **AES-256-GCM** via **PBKDF2** (SHA-256, **100.000 iterações**, salt **fixo** `drop-secure-salt`) e (2) o `session_id` = hex do SHA-256 do código.
- **Cifragem:** cada mensagem usa **IV aleatório de 12 bytes** (`crypto.getRandomValues`); o pacote transmitido é `base64(IV || ciphertext)`.
- **Timeout de sessão:** `SESSION_TIMEOUT = 600s` (10 min). `_cleanup()` remove sessões com `now - last_activity > 600`, chamado em `connect` e `send_to_session`. O cliente também expira o `localStorage` após 10 min.
- **Single Listener:** apenas um WebSocket por `session_id`. Nova conexão enquanto há WS ativo é rejeitada com `close(code=1008, reason="Session busy")`. O `disconnect()` zera o WS (`websocket=None`) mas **mantém a sessão**, permitindo reconexão (ex: F5) dentro do timeout.
- **Entrega não garantida:** se o Receptor não tem WS conectado no momento do envio, a mensagem **não é entregue** (`Receiver not connected`); não há fila/buffer/retry.
- **Keep-alive:** o cliente Receptor envia `"ping"` a cada 30s; o servidor trata qualquer texto recebido como atualização de `last_activity` (não envia pings). O cliente ignora mensagens `"ping"`.
- **Persistência de UX no cliente:** `localStorage['drop_app_state']` guarda `{mode, code, sessionId, keyJwk, timestamp}` para restaurar a sessão após reload (dentro de 10 min). A chave AES é exportada em **JWK com `extractable=true`** e persistida nesse mesmo storage.
- **Entradas do Emissor:** código digitado (8 chars, convertido para upper-case), QR pela câmera (html5-qrcode) ou deep link `#code=` (o QR aponta para `origin + '/#code=' + code`).
- **Conveniências do Receptor:** mostrar/ocultar conteúdo, copiar para clipboard e "Limpar Área de Transferência" (exige `window.isSecureContext` / HTTPS).

## 🗄️ Modelo de dados
Sem banco e sem persistência em disco. Todo estado fica em memória do processo:

```
ConnectionManager.sessions: Dict[session_id -> {
    websocket: WebSocket | None,
    created_at: float,
    last_activity: float
}]
```

`session_id` = SHA-256 (hex) do código de 8 chars. No cliente, estado efêmero em `localStorage['drop_app_state']`: `{mode:'receiver'|'sender', code, sessionId, keyJwk, timestamp}`. Reinício do container apaga todas as sessões ativas.

## 🔌 Endpoints / API
- **`GET /`** — retorna o `index.html` (SPA), lido do disco **uma única vez no startup** do processo.
- **`WebSocket /ws/{session_id}`** — canal do Receptor. Aplica Single Listener (fecha conexão duplicada com code 1008). Em loop, recebe texto e atualiza `last_activity`; no `WebSocketDisconnect`, zera o WS mantendo a sessão.
- **`POST /api/send/{session_id}`** — corpo JSON `{encrypted_payload}`. Encaminha o payload criptografado ao WS do Receptor. Retorna `{status:"sent"}` ou `{status:"error", detail:"Receiver not connected"}` — sempre com HTTP 200 (o resultado fica no corpo JSON).

## 🔗 Integrações externas
Apenas dependências de **runtime no navegador** (CDNs de terceiros), nenhuma no backend:
- `cdnjs.cloudflare.com` — qrcodejs 1.0.0
- `unpkg.com` — html5-qrcode (sem versão fixada)
- `cdn.tailwindcss.com` — Tailwind Play CDN
- `fonts.googleapis.com` — fonte Inter

## 🧩 Dependências internas (Bergatrix)
- **traefik** — reverse proxy e terminação TLS servindo o wildcard `*.daberga.com` compartilhado via `tls=true` (CA Let's Encrypt; o cert é emitido uma única vez pela stack do Traefik, este app só o consome); roteia `drop.${DOMAIN}` (HTTPS/WSS).
- **rede `bergatrix-proxy`** — rede Docker externa compartilhada da stack.

Nenhuma dependência de banco, Redis, Authentik ou LiteLLM.

## 🔑 Variáveis de ambiente necessárias
**Compose / infra:**
- `DOMAIN`

Não há outras variáveis. `DOMAIN` é usada apenas no label de roteamento do Traefik.

## 🗂️ Estrutura de código
Stack mínima e autocontida (6 arquivos):

- `docker-compose.yml` — um serviço `drop`, rede externa `bergatrix-proxy`, labels Traefik.
- `Dockerfile` — Python 3.11-slim, instala `app/requirements.txt`, copia `app/`, expõe 8000, roda uvicorn.
- `.env.example` — somente `DOMAIN=example.com` (placeholder).
- `app/server.py` — backend FastAPI (**111 linhas**): classe `ConnectionManager` (`sessions`, `_cleanup`, `connect`, `disconnect`, `send_to_session`) + 3 rotas. Carrega `index.html` no startup.
- `app/index.html` — frontend SPA single-file (**488 linhas**): UI Tailwind + JS de cripto (PBKDF2/AES-GCM), QR (geração e leitura), WebSocket e `localStorage`.
- `app/requirements.txt` — `fastapi`, `uvicorn[standard]`, `websockets` (sem versões fixadas).

Sem testes, migrations, workers/cron ou integração com IA/LLM.

## 🛡️ Gestão de segredos
- **Nenhum segredo de aplicação/credencial** no stack. A única variável é `DOMAIN` (não sensível); `.env.example` traz apenas `DOMAIN=example.com`.
- **Nenhum segredo real commitado** foi encontrado nos arquivos canônicos (compose, Dockerfile, .env.example, server.py, index.html). `secretsExposed` vazio.
- Observações (não são segredos vazados, mas afetam a postura de segurança, sinalizadas por **localização**):
  - **`app/index.html`** — salt do PBKDF2 (`'drop-secure-salt'`) está hardcoded no cliente. É esperado em esquemas E2EE com derivação no cliente, porém é um **salt fixo** que reduz a margem de segurança (comentário no código: "for simplicity in this demo").
  - **`app/index.html`** — a chave AES é exportada como **JWK com `extractable=true`** e persistida em `localStorage`, ampliando a superfície de exposição da chave no dispositivo (XSS / inspeção local).
- Como o segredo viaja sempre criptografado e a chave nunca chega ao servidor, não há rotação de credenciais de servidor a fazer; as recomendações são de design (salt por sessão, evitar persistir a chave extraível).

## 🚧 Notas de evolução / pendências
- Salt do PBKDF2 fixo/hardcoded — candidato a salt por sessão.
- Código gerado com `Math.random()` em vez de `crypto.getRandomValues` — aleatoriedade não criptográfica para um valor que deriva a chave.
- Reconexão Single Listener admitidamente frágil (comentários extensos em `connect()` sobre F5 rápido e ordem entre `disconnect` antigo e `connect` novo).
- Sem entrega garantida: mensagem enviada com Receptor offline é perdida (sem fila/retry/buffer).
- Keep-alive via `setInterval` no cliente nunca é limpo (`clearInterval` ausente) — pode acumular intervals em reconexões. Uso de `except:` genérico no servidor.
- Sem healthcheck no compose; sem limites de recurso/deploy.
- Estado só em memória — reinício do container derruba todas as sessões.
- Dependência de vários CDNs de terceiros em runtime (Tailwind Play CDN, qrcodejs, html5-qrcode sem versão fixada, Google Fonts) — não recomendado para produção e quebra uso offline.
- `requirements.txt` sem pin de versão (build não reproduzível).
- Chave AES persistida em `localStorage` com `extractable=true`.
- Nome "Drop" sugere possível extensão futura para arquivos, embora hoje só trafegue texto.

## ❓ Perguntas em aberto
- Com ~40 bits de entropia no código, salt fixo e PBKDF2, qual é o modelo de ameaça pretendido (online vs offline)? Há intenção de aumentar o tamanho do código, usar gerador criptográfico e/ou adicionar rate limiting em `/api/send` e `/ws`?
- O envio só funciona com o Receptor online; deseja-se adicionar buffer/fila de mensagens pendentes dentro do timeout de 10 min?
- Há intenção de remover os CDNs externos e embutir os assets localmente (produção/offline) e fixar versões?
- O nome "Drop" indica roadmap para suportar arquivos/payloads binários além de texto?
- É aceitável persistir a chave AES (JWK extractable) em `localStorage`, ou ela deveria ficar apenas em memória / `sessionStorage`?

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a stack evoluir._
