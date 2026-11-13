# Jellyfin só pelo Authentik

Todo mundo entra no Jellyfin pelo Authentik. A exceção são duas contas locais que só funcionam na rede de casa. Quem faz isso é o plugin **Bergafin Auth** ([Agelinena/Bergafin-auth](https://github.com/Agelinena/Bergafin-auth)), que é nosso. Substitui o LDAP, que foi removido em novembro de 2026.

## Como funciona

| Quem | Como entra | De onde |
|---|---|---|
| Contas do Authentik (grupo `jellyfin_users`) | Botão do Authentik no navegador, app Bergafin ou Quick Connect | Qualquer lugar |
| Admins (grupo `jellyfin_admins`) | Igual. Viram admin no Jellyfin a cada login. | Qualquer lugar |
| `sala` (TV Samsung, app Tizen) | Usuário e senha locais | Só `192.168.10.0/24` |
| Admin de emergência | Usuário e senha locais | Só `192.168.10.0/24` |

- **Contas do Authentik não têm senha no Jellyfin.** O provedor delas (`Authentik (Bergafin)`) recusa qualquer login por senha, em qualquer app.
- **As contas locais têm o acesso remoto desligado.** O Jellyfin confere isso **em toda requisição**, não só no login. Até um token obtido por Quick Connect para essas contas para de funcionar fora de casa.
- **Quick Connect:** o aparelho mostra um código. A pessoa abre `https://jellyflix.${DOMAIN}/Bergafin/QuickConnect`, digita o código e confirma no Authentik. Serve para apps oficiais, a TV e o Seerr.

## Configuração (uma vez)

### 1. Authentik

1. Em *Applications → Providers → Create → OAuth2/OpenID Provider*:
   - **Nome:** `Jellyfin`;
   - **Client type:** Confidential;
   - **Redirect URI** (strict): `https://jellyflix.${DOMAIN}/Bergafin/Callback`;
   - **Escopos:** `openid`, `profile` e `email`. O `profile` do Authentik já manda os grupos (`groups`).
2. Em *Applications → Applications → Create*, crie a aplicação `Jellyfin` com esse provider. Em *Policy / Group / User Bindings*, adicione os grupos `jellyfin_users` e `jellyfin_admins`.
3. Anote o **Client ID**, o **Client Secret** e o **Issuer** (`https://auth.${DOMAIN}/application/o/<slug>/`). O secret vai para o Vaultwarden.

### 2. Plugin

1. Em *Painel → Plugins → Repositórios*, adicione `https://raw.githubusercontent.com/Agelinena/Bergafin-auth/manifest/manifest.json`.
2. Em *Catálogo*, instale **Bergafin Auth** e reinicie o Jellyfin (`docker restart jellyfin`).
3. Em *Painel → Plugins → Bergafin Auth*, preencha:
   - endereço público: `https://jellyflix.${DOMAIN}`;
   - issuer, client ID e client secret do passo anterior.
4. As atualizações chegam sozinhas pela tarefa *Atualizar plugins*. Um workflow do repositório recompila o plugin a cada versão nova do Jellyfin.

### 3. Rede (*Painel → Rede*)

Sem isso, o Jellyfin vê o IP do Traefik em vez do IP real do cliente:

- **Proxies conhecidos:** `172.16.0.0/12`, a faixa do Docker ([proxy confiável](../06-redes.md));
- **Redes LAN:** `192.168.10.0/24`;
- **Quick Connect** ligado, em *Painel → Geral*.

> Antes de confiar na regra da rede de casa, confira que um acesso **de fora** (4G) aparece com o IP real em *Painel → Dispositivos* ou no log do Traefik. Se o roteador trocar a origem para `192.168.10.1` no redirecionamento de porta, as contas locais ficariam liberadas para a internet.

### 4. Contas locais

1. **`sala`:** crie em *Painel → Usuários* com uma senha forte. Desmarque **Permitir acesso remoto**.
2. **Admin de emergência:** mesma coisa. Senha no Vaultwarden.
3. Na TV, o app Tizen entra como `sala`.

Contas locais nunca são ligadas ao Authentik. Se alguém do Authentik tiver o mesmo nome, o login dessa pessoa é recusado, para ninguém tomar a conta `sala` ou a do admin.

## Migração do LDAP (feita em novembro de 2026)

Não precisa recriar ninguém. O plugin liga pelo **mesmo nome de usuário** as contas que usavam o LDAP (`LdapAuthenticationProviderPlugin`), e o histórico continua. Ordem:

1. Faça os passos 1 a 3 acima e teste o login com a sua conta pelo navegador. O botão do Authentik ainda não existe na tela; use `https://jellyflix.${DOMAIN}/Bergafin/Login`.
2. Desinstale o plugin **LDAP Authentication** e reinicie o Jellyfin.
3. No servidor, aplique o repositório:
   ```bash
   cd ~/bergatrix && git pull
   (cd 03-apps/jellyfin && docker compose up -d)
   (cd 02-security/authentik && docker compose up -d --remove-orphans)   # remove o authentik-ldap
   docker network rm bergatrix-ldap
   ```
4. No Authentik, apague o outpost LDAP, o provider e a aplicação LDAP, a conta `ldapservice`, o grupo `ldap_search` e a role `LDAP search`. Também apague o flow `ldap-authentication-flow` e a etapa `ldap-authenticator-validation`, se existirem. No `.env` do Authentik, apague o `OUTPOST_LDAP_TOKEN`.
5. Em *Painel → Dispositivos*, confira se sobrou sessão de quem não devia ter acesso.

## Seerr (`catalogo`)

O Seerr entra por **Quick Connect** desde a versão 3.4.0. Na tela de login, a pessoa escolhe Quick Connect, aprova o código em `/Bergafin/QuickConnect` e pronto. Ela continua com os próprios pedidos e avisos.

O login com senha do Jellyfin no Seerr só funciona para as contas locais, na rede de casa. O login local do próprio Seerr continua desligado (*Settings → Users*).

## Uso no dia a dia

| Quero… | Onde |
|---|---|
| Dar acesso | Colocar no `jellyfin_users` do Authentik |
| Tornar admin | Colocar no `jellyfin_admins`. Vale no próximo login. |
| Tirar acesso | Tirar do grupo e apagar os aparelhos da pessoa em *Painel → Dispositivos* (sessões abertas continuam até isso) |
| Conectar uma TV ou app oficial | Quick Connect no aparelho e aprovar em `/Bergafin/QuickConnect` |
| Ver por que alguém não entrou | `docker logs jellyfin 2>&1 \| grep Authentik` |

## Próximas fases

- **Bergafin-web:** fork do `jellyfin-web` com o botão "Entrar com Authentik" e o cast pelo celular. O servidor passa a usar a imagem `ghcr.io/agelinena/bergafin`, que é o Jellyfin oficial com o nosso web.
- **Bergafin-android:** fork do app, com login pelo Authentik no navegador do sistema (`bergafin://login`) e cast melhor para o Chromecast do quarto (Default Media Receiver, sem pagar nada ao Google).
