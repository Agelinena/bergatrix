# 🔀 Migração de domínio: `bergaestudio.xyz` → `daberga.com`

> **Status:** concluída no repositório (jun/2026). Restam **ações manuais no servidor** (ver §4) que não podem ser feitas a partir do repo.
> O domínio antigo `bergaestudio.xyz` foi **perdido**; o novo `daberga.com` está registrado na Porkbun e delegado ao **deSEC**.

---

## 1. O que está migrado (no repositório)

### Domínio
- **`config/traefik.yml`** (`01-network/traefik`): wildcard TLS `main: daberga.com` + SAN `*.daberga.com`.
- **`docker-compose.yml`** de todas as stacks: usam `${DOMAIN}` / `${WEB_DOMAIN}` / `${API_DOMAIN}` / `${DEEMIX_DOMAIN}` / `${N8N_DOMAIN}` — **agnósticos de domínio**; o valor real vem do `.env` (servidor).
- **`.env.example`**: `berga-news` (`DOMAIN=daberga.com`) e `wazuh` (comentário de exemplo) atualizados.
- **Flutter (`bergastream`)**: `track_card.dart` → link `https://stream.daberga.com/...` (⚠️ exige rebuild — ver §4).
- **Docs**: todas as referências de domínio em `docs/` migradas (os docs usam `${DOMAIN}`; literais antigos corrigidos em passo anterior).

### Estratégia de certificado (TLS wildcard)
Antes, cada app pedia um **certificado individual** via `tls.certresolver=letsencrypt` (ou `=production`). Agora **todas as apps usam só `tls=true`** (sem `certresolver`) e herdam o **wildcard `*.daberga.com`** emitido uma única vez pelo Traefik.

**15 `docker-compose.yml` migrados** (19 routers): `cloudbeaver`, `authentik`, `bitwarden` (2 routers), `berga-news`, `bergastream` (3 routers: web/api/deemix), `drop`, `ghostmap`, `jellyfin` (2 routers: jellyfin/catalogo), `litellm`, `n8n` (era `production`), `openuiweb`, `rss-ig`, `rss`, `transcriptor` (era `production`), `wazuh`.

> O `docker-compose.yml` do Traefik **não** foi alterado (já estava correto: `--configFile=/traefik.yml`, `dns: 9.9.9.9/149.112.112.112`, resolvers deSEC autoritativos, `LEGO_DISABLE_CNAME_SUPPORT=true`).

### Infraestrutura crítica (DNS) — documentada
A emissão do cert quebrava porque o OPNsense fazia **hijacking transparente de DNS na porta 53**, impedindo a descoberta da zona via SOA (erro `domainName=com`). **Solução:** regra NAT **"No RDR (NOT)"** no OPNsense para a origem `192.168.10.10`, porta 53. Detalhada em [`stacks/networks.md`](stacks/networks.md), [`stacks/traefik.md`](stacks/traefik.md) e [`01-arquitetura-rede-seguranca.md`](01-arquitetura-rede-seguranca.md). **Se removida, a renovação automática falha em ~60 dias.**

### Documentação atualizada
`stacks/traefik.md`, `stacks/networks.md`, `01-arquitetura-rede-seguranca.md`, `02-convencoes-e-padroes.md` (template de labels), e os 15 `.md` de stack (nota de cert: usa wildcard, não emite individual).

---

## 2. O que ainda referencia `bergaestudio` — e **NÃO deve mudar**

`grep -rln bergaestudio` (excluindo `.git`/`.claude`) retorna **apenas 4 arquivos**, todos do **identificador de pacote do app Flutter** `xyz.bergaestudio.bergastream` — que é **package name, não domínio**:

| Arquivo | Ocorrência | Tipo |
|---|---|---|
| `03-apps/bergastream/frontend/android/app/build.gradle.kts` | `namespace` + `applicationId` | ID do app Android |
| `.../android/app/src/main/kotlin/xyz/bergaestudio/bergastream/MainActivity.kt` | `package` + caminho de diretório | pacote Kotlin |
| `03-apps/bergastream/frontend/lib/main.dart` | `androidNotificationChannelId` | derivado do package |
| `03-apps/bergastream/frontend/windows/runner/Runner.rc` | `CompanyName` / `LegalCopyright` | branding Windows |

**Por que não mudar:** `applicationId` é a identidade do app na loja/dispositivo — trocá-lo cria um **app diferente** (instalações existentes não atualizam). Mudar o `namespace`/pacote exige mover diretórios Kotlin e rebuild. **Package name não precisa corresponder a um domínio que você possui** — é inofensivo manter. Rebrand de identidade do app, se desejado, é tarefa própria e deliberada.

**Artefatos de build do Flutter** (`*/frontend/build/*`, `*/.dart_tool/*`): **não presentes no repo** (gitignored / não gerados aqui) — nada a tratar. Se forem gerados localmente, podem conter o package antigo até um rebuild limpo.

---

## 3. Verificação rápida

```bash
# Nenhum domínio antigo no repo (deve ser vazio):
grep -rn "bergaestudio\.xyz" . --exclude-dir=.git --exclude-dir=.claude

# Nenhum certresolver nos composes (deve ser vazio):
grep -rn "certresolver" --include=docker-compose.yml .

# Só o package name do app deve sobrar para "bergaestudio":
grep -rln "bergaestudio" . --exclude-dir=.git --exclude-dir=.claude
```

---

## 4. Ações manuais (dependem do servidor — **NÃO feitas por este repo**)

> O agente não tem acesso ao servidor. As ações abaixo são suas.

1. **Rotacionar o token do deSEC** (`DESEC_TOKEN`) — o domínio antigo foi perdido; gere/rote o token e atualize o `.env` real do Traefik no servidor.
2. **Rebuild do frontend `bergastream` (e deemix)** — a `API_URL` e links são **compilados** no Flutter (`build.args: API_URL=https://${API_DOMAIN}`). Sem `docker compose build web`, o app web/APK continua apontando para o domínio antigo. Inclui o link `stream.daberga.com` do `track_card.dart`.
3. **Recriar containers que ainda rodam config antiga** — serviços fora deste repo (deployados só no servidor) que precisam de `up -d --force-recreate` para pegar o novo domínio/cert: **rss-bridge, flutter, minio, rsshub** (e quaisquer outros que cacheiem o domínio).
4. **Reapontar webhooks externos do n8n** — integrações externas que chamam `WEBHOOK_URL` no domínio antigo precisam ser **reapontadas manualmente** para `https://${N8N_DOMAIN}` (daberga.com). O n8n não reescreve webhooks já registrados em serviços de terceiros.
5. **Aplicar os composes migrados** — após `git pull` no servidor, `docker compose up -d` nas 15 stacks para os routers passarem a usar `tls=true` (wildcard).
6. **Preservar a regra NAT "No RDR" do OPNsense** — infra crítica para renovação do cert (§1).

---

_Relatório gerado durante a migração de domínio do homelab Bergatrix. Atualize conforme as ações manuais forem concluídas._
