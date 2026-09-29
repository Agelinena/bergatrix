# homeassistant — Plataforma de automação residencial (Home Assistant Core em container) exposta via Traefik no Modelo B (Authentik de fora, direto para dispositivos de confiança, bypass para o app Companion)

> **Categoria:** app | **Caminho:** `03-apps/homeassistant` | **Status:** novo (a subir)

## 🎯 Finalidade
Centraliza a automação da casa: integrações com dispositivos (lâmpadas, tomadas, sensores, câmeras, Zigbee/Z-Wave), automações, dashboards e o app **Companion** (Android/iOS) para controle e notificações de fora de casa. Alinha com o pilar de **soberania de dados**: a lógica roda localmente, sem depender de nuvens de fabricantes sempre que a integração permitir.

## 🧱 Stack tecnológica
- **Home Assistant Core** — imagem oficial `ghcr.io/home-assistant/home-assistant:stable` (Python, s6-overlay).
- Persistência em arquivos dentro de `/config`: YAML, `.storage/` (JSON) e `home-assistant_v2.db` (SQLite do recorder).
- **Traefik** para TLS/roteamento e **CrowdSec** (bouncer) na borda.

## 📦 Serviços / Containers
| Item | Valor |
|---|---|
| **Serviço** | `homeassistant` (container_name `homeassistant`) |
| **Imagem** | `ghcr.io/home-assistant/home-assistant:stable` |
| **Portas** | `8123` só dentro do container; **sem `ports:`**, acesso apenas via Traefik |
| **Volumes** | `${VOLUMES_BASE}/homeassistant/config:/config` · `/etc/localtime:ro` · (opcional) `/run/dbus:ro` para Bluetooth |
| **Redes** | `bergatrix-proxy` (external) |
| **restart** | `unless-stopped` |
| **healthcheck** | `curl` em `http://127.0.0.1:8123/manifest.json` (rota pública do frontend, sem auth); `start_period` de 120 s porque o primeiro boot é lento |
| **security_opt** | `no-new-privileges:true` — **sem `privileged`**; dongles USB entram via `devices:` (bloco comentado no compose) |

## 🌐 Domínios / Roteamento
**Modelo B** de [modelos-labels-traefik.md](../modelos-labels-traefik.md), no mesmo formato do Vaultwarden. Todos os routers usam `Host(\`ha.${DOMAIN}\`)`, `websecure` e `tls=true` (herdam o wildcard `*.daberga.com`, sem `certresolver`):

| Router | Regra extra | Middlewares | Prioridade | Quem cai aqui |
|---|---|---|:---:|---|
| `homeassistant-bypass` | `PathPrefix(/api-access-bypass)` | `crowdsec-bouncer@file`, `api-access-bypass@file` | 120 | App Companion configurado com a URL `https://ha.${DOMAIN}/api-access-bypass` (autentica com o token do próprio HA) |
| `homeassistant-direct` | `ClientIP` dos 3 dispositivos de confiança | — | 110 | Notebook, celular e OPNsense, direto sem Authentik |
| `homeassistant-router` | não é bypass **e** não é dispositivo de confiança | `crowdsec-bouncer@file`, `public-auth@file` | 100 | Qualquer outro acesso: login no Authentik e depois login do HA |

- Service `homeassistant-service` → porta `8123`. O WebSocket (`/api/websocket`) usa a mesma porta, então não há routers `-ws-*` separados como no Vaultwarden.
- O router `-bypass` não passa pelo Authentik por design: nele, a proteção é o login do HA com MFA mais o CrowdSec.

> ⚠️ **Validar o app Companion pelo 4G.** O `stripPrefix` resolve as chamadas de API/WebSocket do app, mas o frontend do HA carrega arquivos por caminho absoluto (`/frontend_latest/...`, `/static/...`). Esses caminhos não têm o prefixo, caem no `homeassistant-router` e exigem sessão do Authentik. Se o painel do app ficar em branco ou pedir login do Authentik, faça o login do Authentik uma vez na webview do app (o cookie vale para o domínio) ou avalie outra saída antes de mudar o modelo.

## 📐 Regras de negócio / segurança
O router `-bypass` depende só do login do próprio HA, então estes itens são **obrigatórios** antes de expor:

1. **MFA (TOTP)** ativo em todos os usuários (Perfil → Módulos de autenticação multifator).
2. **Reverse proxy confiável + ban por IP** no `configuration.yaml` (ver seção abaixo). Sem `trusted_proxies`, o HA responde **400 Bad Request** a toda requisição vinda do Traefik.
3. Nenhum usuário com senha fraca; o usuário *owner* não deve ser usado no dia a dia.

### Bloco `http:` do `configuration.yaml`
O arquivo fica em `${VOLUMES_BASE}/homeassistant/config/configuration.yaml`, que o HA cria no primeiro boot. Ele não é versionado. Descubra a subnet da `bergatrix-proxy`:

```bash
docker network inspect bergatrix-proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

E adicione:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <SUBNET_DA_BERGATRIX_PROXY>   # ex.: 172.18.0.0/16 — saída do comando acima
  ip_ban_enabled: true
  login_attempts_threshold: 5
```

> ⚠️ Se `trusted_proxies` estiver errado com `ip_ban_enabled` ligado, o HA pode banir o **IP do Traefik** e bloquear todo mundo. Nesse caso, apague a entrada em `config/ip_bans.yaml` e reinicie o container.

Os routers `-direct` e `-router` dependem do IP real do cliente. Ele chega até o Traefik porque o Traefik já confia no `proxyProtocol`/`forwardedHeaders` de `10.100.0.1` (ver `config/traefik.yml`) e é repassado ao HA pelo `X-Forwarded-For`.

## 🔌 Rede: bridge × host (limitação conhecida)
A stack usa **bridge** (`bergatrix-proxy`) para seguir o padrão da Bergatrix: sem portas no host e roteamento só pelo Traefik. Consequências:

- ✅ Integrações por IP, nuvem, MQTT e HTTP funcionam normalmente (o container alcança a LAN `192.168.10.0/24` via NAT).
- ❌ **Descoberta automática por multicast** (mDNS/zeroconf, SSDP/UPnP, HomeKit, Chromecast, alguns dispositivos Sonoff/Shelly em modo discovery) **não funciona**, porque o multicast não atravessa a bridge. Dá para adicionar esses dispositivos manualmente pelo IP.

Se a descoberta for indispensável, troque para `network_mode: host`. Nesse caso:
- remova `networks:` e as labels do compose (o Traefik deixa de enxergar o container pela `bergatrix-proxy`);
- crie o router/service no `01-network/traefik/config/dynamic.yml` apontando para `http://192.168.10.10:8123`;
- ajuste `trusted_proxies` para o IP do gateway da `bergatrix-proxy`;
- a porta 8123 passa a ficar aberta no host, então bloqueie no firewall o que não vier da LAN.

## 🗄️ Modelo de dados
Tudo sob `/config`: `configuration.yaml` e YAMLs incluídos, `secrets.yaml`, `.storage/` (registro de entidades/dispositivos, usuários, tokens), `home-assistant_v2.db` (histórico/recorder, SQLite) e `ip_bans.yaml`. **Backup:** o diretório inteiro `${VOLUMES_BASE}/homeassistant/config` (o `backups/` interno do HA também serve).

## 🔗 Integrações externas
Dependem das integrações configuradas na UI. Integrações de nuvem saem pela internet via `bergatrix-proxy` (bridge com egress).

## 🧩 Dependências internas (Bergatrix)
- Rede externa **`bergatrix-proxy`** e **Traefik** (01) ativos.
- **Authentik** (02): o middleware `public-auth@file` encadeia `authentik@file` (ForwardAuth em `authentik-server:9000`). É preciso criar no Authentik o Provider (Proxy, *forward auth single application*) e a Application para `ha.${DOMAIN}`, vinculados ao outpost.
- **CrowdSec** (02) com o bouncer do Traefik configurado (`CROWDSEC_BOUNCER_KEY`). Sem ele, o middleware `crowdsec-bouncer@file` falha e o router não sobe.
- Opcional: a CrowdSec Hub tem a coleção `crowdsecurity/home-assistant`, que detecta brute-force no log do HA. Para usá-la, é preciso expor o log do HA ao container do CrowdSec (ainda não configurado).

## 🔑 Variáveis de ambiente necessárias
`DOMAIN`, `VOLUMES_BASE`, `TZ` (ver `.env.example`). O HA não usa `PUID`/`PGID` (roda como root dentro do container). Segredos das integrações ficam no `secrets.yaml` do próprio HA, **fora do repo**.

## 🗂️ Estrutura de código
- `docker-compose.yml` — serviço único, labels Traefik (Modelo B: `-router`/`-direct`/`-bypass`), healthcheck.
- `.env.example` — placeholders.

## 🛡️ Gestão de segredos
Nenhum segredo no repo. Credenciais de usuários, tokens de longa duração e chaves de integrações vivem em `/config/.storage` e `/config/secrets.yaml` no volume do host. Guarde o TOTP de recuperação e a senha do owner no Vaultwarden.

## 🚧 Notas de evolução / pendências
- Imagem `:stable` não pinada. Para reprodutibilidade, fixe a versão (ex.: `:2026.9`) e atualize de forma deliberada.
- Avaliar a coleção CrowdSec `crowdsecurity/home-assistant`.
- Se entrar um dongle Zigbee, avaliar **Zigbee2MQTT + Mosquitto** como stack/serviços separados (ficam na rede `homeassistant-internal`, sem Traefik).

## ✅ Primeiro deploy
```bash
cd 03-apps/homeassistant
cp .env.example .env            # ajustar VOLUMES_BASE
mkdir -p /mnt/storage/docker_volumes/homeassistant/config   # mesmo VOLUMES_BASE do .env
docker compose up -d
# aguardar o 1º boot e então editar configuration.yaml (bloco http:) e reiniciar:
docker compose restart homeassistant
docker logs traefik 2>&1 | grep -i homeassistant   # sem erro de parsing
```
Teste como dispositivo de confiança **e** pelo 4G (checklist de [modelos-labels-traefik.md](../modelos-labels-traefik.md)).

---
_Documento criado junto com a stack. Atualize conforme a stack evoluir._
