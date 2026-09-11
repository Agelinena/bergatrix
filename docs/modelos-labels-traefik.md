# Modelos de Labels do Traefik — Bergatrix

Referência rápida para adicionar serviços novos sem redescobrir a lógica toda vez.

## ⚠️ Bugs que já nos morderam

| Problema | Sintoma | Correção |
|---|---|---|
| Middleware do `dynamic.yml` referenciado com `@docker` | 404 fantasma, roteador nunca ativa | Sempre usar `@file` para middlewares definidos no `dynamic.yml` |
| `ClientIP()` com múltiplos IPs na mesma chamada | Erro `unexpected number of parameters`, roteador descartado sem aviso visível | Um IP por chamada, unindo com `\|\|`: `(ClientIP(\`a\`) \|\| ClientIP(\`b\`))` |

## 📌 Dispositivos de confiança

```
192.168.10.140/32   → Notebook
192.168.10.121/32   → Celular
192.168.10.1/32     → Firewall (OPNsense)
```

Snippet de regra (rota "direta", pulando Authentik):
```
(ClientIP(`192.168.10.140/32`) || ClientIP(`192.168.10.121/32`) || ClientIP(`192.168.10.1/32`))
```

Middlewares equivalentes no `dynamic.yml`:
```yaml
http:
  middlewares:
    internal-only:          # só os 3 dispositivos de confiança
      ipAllowList:
        sourceRange:
          - "192.168.10.140/32"
          - "192.168.10.121/32"
          - "192.168.10.1/32"

    lan-only:                # rede local inteira
      ipAllowList:
        sourceRange:
          - "192.168.10.0/24"
```

---

## Resumo — qual modelo usar

| Modelo | De fora (internet) | Da rede local | Uso típico |
|---|---|---|---|
| **A** | Login Authentik | Direto (dispositivos de confiança) | Painel simples, só navegador |
| **B** | Login Authentik | Direto + API própria do app | Vaultwarden, apps com cliente nativo |
| **C** | ❌ Bloqueado (403) | Só dispositivos de confiança | Admin do Authentik, painéis sensíveis |
| **C2** | ❌ Bloqueado (403) | Qualquer um na LAN | Serviço pra convidados/dispositivos de terceiros |
| **D** | Só API (token próprio) + web com Authentik | Direto na parte web | Webhooks, integrações externas |
| **E** | Livre, sem login nenhum | Livre | App com auth própria (Jellyfin, etc) |

---

## Modelo A — Público, só navegador

**Quando usar:** sem app nativo/API, protegido pelo Authentik pra todo mundo, exceto dispositivos de confiança.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-direct.rule=Host(`meuapp.${DOMAIN}`) && (ClientIP(`192.168.10.140/32`) || ClientIP(`192.168.10.121/32`) || ClientIP(`192.168.10.1/32`))"
  - "traefik.http.routers.MEUAPP-direct.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-direct.tls=true"
  - "traefik.http.routers.MEUAPP-direct.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-direct.priority=110"

  - "traefik.http.routers.MEUAPP-router.rule=Host(`meuapp.${DOMAIN}`)"
  - "traefik.http.routers.MEUAPP-router.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-router.tls=true"
  - "traefik.http.routers.MEUAPP-router.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-router.middlewares=public-auth@file"
  - "traefik.http.routers.MEUAPP-router.priority=100"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

---

## Modelo B — Público, com app/API própria

**Quando usar:** cliente nativo/app mobile que não consegue fazer login OAuth interativo (ex: Vaultwarden, Nextcloud, Immich).

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-router.rule=Host(`meuapp.${DOMAIN}`) && !PathPrefix(`/api-access-bypass`) && !(ClientIP(`192.168.10.140/32`) || ClientIP(`192.168.10.121/32`) || ClientIP(`192.168.10.1/32`))"
  - "traefik.http.routers.MEUAPP-router.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-router.tls=true"
  - "traefik.http.routers.MEUAPP-router.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-router.middlewares=public-auth@file"
  - "traefik.http.routers.MEUAPP-router.priority=100"

  - "traefik.http.routers.MEUAPP-direct.rule=Host(`meuapp.${DOMAIN}`) && (ClientIP(`192.168.10.140/32`) || ClientIP(`192.168.10.121/32`) || ClientIP(`192.168.10.1/32`))"
  - "traefik.http.routers.MEUAPP-direct.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-direct.tls=true"
  - "traefik.http.routers.MEUAPP-direct.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-direct.priority=110"

  - "traefik.http.routers.MEUAPP-bypass.rule=Host(`meuapp.${DOMAIN}`) && PathPrefix(`/api-access-bypass`)"
  - "traefik.http.routers.MEUAPP-bypass.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-bypass.tls=true"
  - "traefik.http.routers.MEUAPP-bypass.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-bypass.middlewares=api-access-bypass@file"
  - "traefik.http.routers.MEUAPP-bypass.priority=120"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

> Tem WebSocket (tipo `/notifications/hub`)? Duplica os 3 roteadores acima (`-ws-router`, `-ws-direct`, `-ws-bypass`) apontando pro serviço/porta do WebSocket — veja o `docker-compose.yml` do Vaultwarden como referência.
>
> Authentik com "External host" dedicado (ex: `auth.daberga.com`)? Precisa de um roteador de callback apontando pro `authentik-service`, ou o login trava em 404.

---

## Modelo C — Só dispositivos de confiança

**Quando usar:** admin do Authentik, painéis sensíveis — nem outros dispositivos da LAN entram, muito menos a internet.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-router.rule=Host(`meuapp.${DOMAIN}`)"
  - "traefik.http.routers.MEUAPP-router.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-router.tls=true"
  - "traefik.http.routers.MEUAPP-router.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-router.middlewares=internal-only@file"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

---

## Modelo C2 — Rede local inteira

**Quando usar:** qualquer dispositivo da LAN pode acessar (convidados, TV, dispositivo de terceiros), mas nunca a internet.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-router.rule=Host(`meuapp.${DOMAIN}`)"
  - "traefik.http.routers.MEUAPP-router.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-router.tls=true"
  - "traefik.http.routers.MEUAPP-router.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-router.middlewares=lan-only@file"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

> Única diferença pro Modelo C: `lan-only@file` no lugar de `internal-only@file`.

---

## Modelo D — Público, com API/webhook por token (sem Authentik)

**Quando usar:** endpoint de API/webhook consumido por terceiros, com autenticação própria (API key, HMAC, Bearer token) — não dá pra colocar Authentik na frente porque quem chama não é um navegador humano. A interface web (se existir) segue o padrão do Modelo A.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-api.rule=Host(`meuapp.${DOMAIN}`) && PathPrefix(`/api`)"
  - "traefik.http.routers.MEUAPP-api.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-api.tls=true"
  - "traefik.http.routers.MEUAPP-api.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-api.priority=120"

  - "traefik.http.routers.MEUAPP-direct.rule=Host(`meuapp.${DOMAIN}`) && (ClientIP(`192.168.10.140/32`) || ClientIP(`192.168.10.121/32`) || ClientIP(`192.168.10.1/32`))"
  - "traefik.http.routers.MEUAPP-direct.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-direct.tls=true"
  - "traefik.http.routers.MEUAPP-direct.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-direct.priority=110"

  - "traefik.http.routers.MEUAPP-web.rule=Host(`meuapp.${DOMAIN}`)"
  - "traefik.http.routers.MEUAPP-web.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-web.tls=true"
  - "traefik.http.routers.MEUAPP-web.service=MEUAPP-service"
  - "traefik.http.routers.MEUAPP-web.middlewares=public-auth@file"
  - "traefik.http.routers.MEUAPP-web.priority=100"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

> O roteador `-api` fica exposto sem Authentik por design — confia inteiramente na autenticação própria do serviço. Vale complementar com `ratelimit` (middleware nativo do Traefik) nesse roteador especificamente.

---

## Modelo E — Totalmente aberto

**Quando usar:** o serviço já tem sua própria autenticação robusta e não precisa de nenhuma camada extra do Traefik (ex: Jellyfin, algo com login e 2FA nativos que você já confia). Sem Authentik, sem filtro de IP — internet e LAN acessam igual.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"

  - "traefik.http.routers.MEUAPP-router.rule=Host(`meuapp.${DOMAIN}`)"
  - "traefik.http.routers.MEUAPP-router.entrypoints=websecure"
  - "traefik.http.routers.MEUAPP-router.tls=true"
  - "traefik.http.routers.MEUAPP-router.service=MEUAPP-service"

  - "traefik.http.services.MEUAPP-service.loadbalancer.server.port=PORTA"
```

> **Use com cautela.** Sem Authentik e sem filtro de IP, a segurança inteira depende só do login do próprio app. Antes de usar esse modelo, confirme que o serviço tem: senha forte exigida, proteção contra brute-force, e idealmente 2FA. Se tiver dúvida, prefira o Modelo A.

---

## Checklist ao adicionar um serviço novo

- [ ] Qual modelo (A/B/C/C2/D/E) se encaixa?
- [ ] Nome do serviço/roteador não colide com outro já existente
- [ ] Middlewares com sufixo certo (`@file` para os do `dynamic.yml`)
- [ ] `ClientIP()` sempre 1 IP por chamada, unindo com `||` quando precisar de mais
- [ ] Prioridades não conflitam entre roteadores do mesmo `Host()`
- [ ] `docker logs traefik 2>&1 | grep -i NOMEDOAPP` sem erro de parsing
- [ ] Testado como dispositivo de confiança **e** como visitante externo (4G)