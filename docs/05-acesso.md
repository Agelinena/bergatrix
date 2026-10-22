# Padrão de acesso (Traefik + Authentik)

Como cada serviço fica exposto e autenticado. Vale para toda stack nova e para cada stack migrada. O andamento da migração está em [plano-acesso.md](plano-acesso.md).

## A regra

**Nenhum serviço fica acessível sem passar pelo Authentik, nem na rede local.** O Authentik entra de um destes três jeitos:

| Padrão | O app… | Middlewares da rota |
|---|---|---|
| **OIDC** | Faz o login no Authentik sozinho (OpenID Connect) | `crowdsec-bouncer@file` |
| **LDAP** | Pede usuário e senha e confere no Authentik ([guia](guias/autenticacao-ldap.md)) | `crowdsec-bouncer@file` |
| **Forward-auth** | Não sabe falar com o Authentik. O Traefik exige o login antes de deixar passar. | `crowdsec-bouncer@file,authentik@file` |

Exceções:

| Exceção | Por quê | Middlewares |
|---|---|---|
| **Drop** (público) | Sem contas, por natureza. Cifra de ponta a ponta. | `crowdsec-bouncer@file` + rate limit |
| **Caminho técnico** dentro de um app forward-auth (ex.: `/webhook` do n8n) | Chamado por máquinas que não fazem login no Authentik. Precisa ter autenticação própria (token, chave, assinatura). | `crowdsec-bouncer@file` |
| **Infraestrutura** (Proxmox, OMV, SSH do Ubuntu) | Fica fora do Traefik | Só pela rede local e pelo Tailscale do firewall |

Não se usa mais:
- rotas `-direct` com `ClientIP`, nem IPs fixos nas labels;
- a rota `-bypass` e o middleware `api-access-bypass`;
- o `internal-only` e o `lan-only` em serviços do Docker;
- o `public-auth` (use `authentik@file`).

## Labels por padrão

Sempre uma rota principal, com o nome do serviço. `<app>` é o nome do serviço, e o subdomínio fica escrito na regra.

### OIDC ou LDAP

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"
  - "traefik.http.routers.<app>.rule=Host(`<app>.${DOMAIN}`)"
  - "traefik.http.routers.<app>.entrypoints=websecure"
  - "traefik.http.routers.<app>.tls=true"
  - "traefik.http.routers.<app>.service=<app>"
  - "traefik.http.routers.<app>.middlewares=crowdsec-bouncer@file"
  - "traefik.http.services.<app>.loadbalancer.server.port=<porta>"
```

### Forward-auth

Igual ao anterior, com o Authentik na lista de middlewares:

```yaml
  - "traefik.http.routers.<app>.middlewares=crowdsec-bouncer@file,authentik@file"
```

### Caminho técnico (só quando necessário)

É uma segunda rota, com prioridade maior, para o caminho que não pode passar pelo login. Toda rota assim precisa de um comentário no compose explicando **quem chama e como esse caminho se autentica**.

```yaml
  # Webhooks chamados por serviços externos; cada workflow valida o próprio token.
  - "traefik.http.routers.<app>-webhook.rule=Host(`<app>.${DOMAIN}`) && PathPrefix(`/webhook`)"
  - "traefik.http.routers.<app>-webhook.entrypoints=websecure"
  - "traefik.http.routers.<app>-webhook.tls=true"
  - "traefik.http.routers.<app>-webhook.service=<app>"
  - "traefik.http.routers.<app>-webhook.middlewares=crowdsec-bouncer@file"
  - "traefik.http.routers.<app>-webhook.priority=200"
```

Para dar acesso **só ao painel de administração** de um app OIDC (ex.: `/admin` do Vaultwarden), use a mesma estrutura, com `authentik@file` nos middlewares.

## No Authentik, para cada app

### OIDC: uma aplicação por app

| Campo | Valor |
|---|---|
| **Tipo de provider** | OAuth2/OpenID |
| **Redirect URI** | O caminho de callback do app, com *matching* **Strict** |
| **Client type** | *Confidential* |
| **Authorization flow** | `default-provider-authorization-implicit-consent` |
| **Signing key** | `authentik Self-signed Certificate` (RS256). Sem *encryption key*. |
| **Acesso** | *Binding* da aplicação ao grupo `<app>_users` (Order `0`) |

### Forward-auth: uma aplicação para o domínio inteiro

Já existe uma aplicação única (aqui chamada de **"Forward Auth do domínio"**), com um provider *Proxy* em modo *Forward auth (domain level)* no outpost embutido. Ela protege todo serviço que usa o middleware `authentik@file`. Um app novo nesse padrão **não precisa de nada no Authentik**, só das labels.

- **Quem entra:** a aplicação tem *binding* com o grupo `admins`. Só esse grupo passa em qualquer serviço de forward-auth. Sem binding, qualquer usuário logado passaria.
- **App que precise de outro grupo:** crie uma aplicação *Proxy* em modo *Forward auth (single application)*, com o *external host* dele, no mesmo outpost, vinculada ao grupo do app. Ela vale para aquele endereço, e a de domínio continua cobrindo o resto.
- **Login duplo:** os *arr aceitam `AuthenticationMethod=External` no `config.xml` (o login fica só com o Authentik; a API continua exigindo a chave). No Bazarr, a autenticação vai para `None`. O n8n, o Wazuh, o CloudBeaver e o qBittorrent mantêm o login próprio atrás do Authentik.

Em todos os casos:
- **2FA:** o login dos usuários precisa passar por 2FA.
- **Segredos:** o client secret vai para o `.env` da stack, com o nome `<APP>_SSO_CLIENT_SECRET`, e o client ID para `<APP>_SSO_CLIENT_ID`. Nunca no compose.

## Conferir uma rota

```bash
# Forward-auth: sem login, deve redirecionar (302) para o Authentik
curl -sI https://<app>.<domínio> | grep -iE '^(HTTP|location)'

# OIDC: a página carrega (200), e o login do app leva ao Authentik
curl -sI https://<app>.<domínio> | head -1
```

No painel do Traefik, a rota deve ser **uma só**, mais as rotas de caminho técnico documentadas.
