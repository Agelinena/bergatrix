# Login pelo Authentik em apps sem OIDC (LDAP)

Para apps que não suportam OIDC, mas aceitam LDAP. O app pergunta ao Authentik, via LDAP, se o usuário e a senha conferem e se a pessoa está no grupo do app. Contas, senhas, 2FA e acessos ficam todos no Authentik.

Primeiro app neste modelo: **Jellyfin** (outubro de 2026). Ele foi escolhido porque os apps de TV e celular não têm tela de SSO; com LDAP, funcionam com o mesmo usuário e senha.

> Quando o app suporta OIDC, prefira OIDC: é login único de verdade, pelo navegador. Ver [03-padrao-stacks.md](../03-padrao-stacks.md#acesso-traefik-e-autenticação).

## Como funciona

```
app ─▶ plugin/config LDAP do app ─▶ authentik-ldap:3389 ─▶ Authentik
                                    (outpost, só na rede Docker)
```

| Peça | Onde | Observação |
|---|---|---|
| Outpost LDAP (`authentik-ldap`) | Stack `02-security/authentik`, serviço `ldap` | Mesma versão do Authentik. Token em `OUTPOST_LDAP_TOKEN`. Sem porta publicada. |
| Provider e aplicação LDAP | Authentik → Applications | Um só, compartilhado por todos os apps LDAP. Cada app filtra pelo próprio grupo. |
| Conta de serviço `ldapservice` | Authentik → Directory → Users | É a única conta que pode ler o diretório inteiro. Senha no Vaultwarden. |
| Grupo `ldap_search` | Authentik → Directory → Groups | Tem a role `LDAP search`. **Só a `ldapservice` fica nele.** |
| Grupos do app | `<app>_users` e `<app>_admins` | Definem quem entra e quem é admin naquele app. |

## Configuração inicial (uma vez)

1. **Conta de serviço:** em *Directory → Users → New User*, crie `ldapservice`. Depois, em *Recovery → Set password*, defina uma senha forte.
2. **Provider e aplicação:**
   - Em *Applications → Providers → Create → LDAP Provider*:
     - **Bind flow:** `default-authentication-flow`;
     - **Base DN:** `dc=ldap,dc=goauthentik,dc=io`;
     - **Certificate:** vazio;
     - **Code-based MFA Support:** ligado.
   - Em *Applications → Applications → Create*, crie uma aplicação apontando para esse provider.
3. **Permissão de busca:**
   - Em *Directory → Roles*, crie a role `LDAP search`.
   - No provider, aba *Permissions*, atribua a ela **Search full LDAP directory**.
   - Crie o grupo `ldap_search` com essa role e coloque nele só a `ldapservice`.
   - No Authentik 2025.10, as roles são atribuídas a grupos, e não direto a usuários.
4. **Outpost:**
   - Em *Applications → Outposts → New Outpost*:
     - **Tipo:** LDAP;
     - **Integration:** vazio;
     - **Applications:** a aplicação do passo 2.
   - Copie o token das informações de implantação para `OUTPOST_LDAP_TOKEN` no `.env` da stack do Authentik e rode `docker compose up -d ldap`.

## Ligar um app novo

1. Crie os grupos `<app>_users` e `<app>_admins`. Coloque as pessoas na aba *Users* de cada grupo. **Todo admin precisa estar nos dois grupos.**
2. Configure o LDAP no app:

| Campo | Valor |
|---|---|
| Servidor / porta | `authentik-ldap` / `3389`, sem TLS |
| Bind DN | `cn=ldapservice,ou=users,dc=ldap,dc=goauthentik,dc=io` |
| Senha do bind | a da `ldapservice` |
| Base DN | `dc=ldap,dc=goauthentik,dc=io` |
| Filtro de usuários | `(memberOf=cn=<app>_users,ou=groups,dc=ldap,dc=goauthentik,dc=io)` |
| Filtro de admins | `(memberOf=cn=<app>_admins,ou=groups,dc=ldap,dc=goauthentik,dc=io)` |
| Atributo de ID / de login | `uid` / `cn` |

3. O app precisa alcançar `authentik-ldap`, ou seja, estar na rede `bergatrix-ldap` ([06-redes.md](../06-redes.md)).
4. Mantenha um **admin local** do app fora do LDAP. É o acesso de emergência se o Authentik cair.

### Jellyfin

- **Plugin:** *LDAP Authentication*, instalado pelo catálogo.
- **Configuração:** os valores da tabela acima, com os grupos `jellyfin_users` e `jellyfin_admins`, e mais:
  - **Search Attributes:** `uid, cn, mail, displayName`;
  - **Enable User Creation:** ligado;
  - **Library Access:** as bibliotecas padrão para contas novas;
  - **Troca de senha:** desligada.
- **Contas que já existem:** em *Painel → Usuários → (pessoa) → Provedor de autenticação → LDAP-Authentication*. O usuário no Authentik precisa ter **o mesmo nome**. O histórico continua.

## Uso no dia a dia

| Quero… | Onde |
|---|---|
| Dar acesso | Colocar no `<app>_users` |
| Tornar admin | Colocar no `<app>_admins` (e no `<app>_users`). Vale a partir do próximo login. |
| Tirar acesso | Remover do `<app>_users` |
| Bloquear em todos os apps | *Directory → Users → Deactivate* |
| Pessoa nova | Criar no Authentik e mandar *Create recovery link*: ela mesma define a senha |

- **Login:** é com o nome de usuário do Authentik; por e-mail não funciona.
- **2FA:** quem tem 2FA digita `senha;código` no campo de senha. Os apps guardam o login, então é uma vez por aparelho.
- **Sessões já abertas:** tirar alguém do grupo bloqueia **novos** logins, mas não derruba quem já está logado. No Jellyfin, apague os aparelhos da pessoa em *Painel → Dispositivos*.

## Segurança

- **A role `LDAP search` nunca vai nos grupos dos apps.** Ela permite ler o diretório inteiro (todos os usuários, e-mails e grupos); só a `ldapservice` precisa dela.
- **LDAP sem TLS:** a conexão fica dentro da rede Docker da VM, junto com o tráfego Traefik ↔ apps, que também não é criptografado. LDAPS com *Skip SSL verification* não protegeria contra quem consegue interceptar. Se um dia for feito, use um certificado com o nome `authentik-ldap` e a CA configurada no app.
- **App público na internet:** coloque o `crowdsec-bouncer@file` na rota dele. O login agora usa as senhas do Authentik.
