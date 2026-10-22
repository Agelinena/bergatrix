# Bergastream — login pelo Authentik

Desde a 0.4 o Bergastream entra pelo Authentik (OIDC), nos apps e na web. O **servidor do
Bergastream** é o cliente OIDC: ele fala com o Authentik, confere o grupo e entrega ao app os
tokens de sempre do Bergastream. Detalhes do fluxo em [API_MAP.md](API_MAP.md#8-autenticação).

Troque `example.com` pelo `${DOMAIN}` real em tudo abaixo.

| O quê | Valor |
|---|---|
| Endereço do app | `https://bergastream.example.com` |
| Redirect URI (cadastrar no Authentik) | `https://bergastream.example.com/api/auth/oidc/callback` |
| Slug da aplicação | `bergastream` |
| Issuer | `https://authentik.example.com/application/o/bergastream/` |
| Grupos | `bergastream_users` (pode entrar), `bergastream_admins` (admin do Bergastream) |

Segue o padrão de `docs/05-acesso.md` na raiz: grupo `<app>_users`, client ID e secret como
`BERGASTREAM_SSO_CLIENT_ID` / `BERGASTREAM_SSO_CLIENT_SECRET` no `.env`, e login com 2FA.

## 1. Grupos

**Directory → Groups → Create**

1. `bergastream_users`: todo mundo que usa o Bergastream.
2. `bergastream_admins`: quem pode rodar a limpeza de arquivos (`POST /api/admin/cleanup`).
   Ponha essas pessoas **também** em `bergastream_users`.

## 2. Provider e aplicação

**Applications → Providers → Create → OAuth2/OpenID Provider**

| Campo | Valor |
|---|---|
| Name | `bergastream` |
| Authorization flow | `default-provider-authorization-implicit-consent` (sem tela de "autorizar") |
| Client type | **Confidential** |
| Client ID / Client Secret | os gerados (copie os dois para o `.env`) |
| Redirect URIs/Origins | `Strict` · `https://bergastream.example.com/api/auth/oidc/callback` |
| Signing Key | **`authentik Self-signed Certificate`** (ou outro certificado; precisa ter um) |

Em **Advanced protocol settings**:

| Campo | Valor |
|---|---|
| Scopes | `openid`, `email`, `profile` (os mapeamentos padrão; o `profile` traz os grupos) |
| Subject mode | `Based on the User's hashed ID` (padrão). **Não mude depois**: é o que liga a conta. |
| Include claims in id_token | **ligado** (o Bergastream lê usuário, e-mail e grupos do `id_token`) |

**2FA:** o padrão exige 2FA no login. Isso fica no fluxo de autenticação do Authentik (stage de
MFA), igual para todos os apps; o Bergastream não precisa de nada a mais.

Sem a Signing Key o Authentik assina com a chave do cliente (HS256), e o Bergastream recusa com
"Configure uma chave de assinatura (RS256) no provider do Authentik".

**Applications → Applications → Create**

| Campo | Valor |
|---|---|
| Name | `Bergastream` |
| Slug | `bergastream` |
| Provider | `bergastream` |
| Launch URL | `https://bergastream.example.com` |

Na aplicação, aba **Policy / Group / User Bindings → Bind existing policy/group/user → Group →
`bergastream_users`**. Assim o próprio Authentik já barra quem não está no grupo (o Bergastream
confere de novo pelo `OIDC_REQUIRED_GROUP`).

O **Issuer** aparece na página do provider ("OpenID Configuration Issuer"); confira se é igual ao
da tabela lá em cima, com a barra no final.

## 3. `.env` do Bergastream

```bash
OIDC_ISSUER=https://authentik.example.com/application/o/bergastream/
BERGASTREAM_SSO_CLIENT_ID=<Client ID do provider>
BERGASTREAM_SSO_CLIENT_SECRET=<Client Secret do provider>
OIDC_REDIRECT_URI=https://bergastream.example.com/api/auth/oidc/callback
OIDC_INTERNAL_URL=http://authentik-server:9000
OIDC_REQUIRED_GROUP=bergastream_users
OIDC_ADMIN_GROUP=bergastream_admins
OIDC_AUTO_CREATE=false        # true depois que as contas antigas estiverem ligadas (passo 4)
PASSWORD_LOGIN=true           # auto depois que todos os aparelhos estiverem na 0.4 (passo 5)
```

- `OIDC_INTERNAL_URL`: a API fala com o Authentik pela rede `bergatrix-proxy` (o compose já põe
  a API nela), sem sair pelo Traefik. O Host público vai junto, então o `iss` continua o público.
  Se o container do Authentik tiver outro nome, ajuste; vazio = pelo endereço público.
- `OIDC_ADMIN_GROUP`: quem está no grupo vira admin a cada login, e quem sai do grupo deixa de
  ser. Vazio = o Bergastream não mexe em quem é admin.
- O `BERGASTREAM_SSO_CLIENT_SECRET` é segredo: só no `.env` do servidor, nunca no repositório.

Aplique e confira:

```bash
docker compose up -d --build api
curl -s https://bergastream.example.com/api/auth/config
# {"registration_enabled":false,"oidc_enabled":true,"password_login_enabled":true}
```

## 4. Contas que já existem

Faça esta parte **antes** de cadastrar as pessoas no Authentik, pela página **Ajustes → Conta →
Usuários** do Bergastream (só admin; precisa da 0.4 no servidor).

No primeiro login pelo Authentik, o Bergastream procura a conta nesta ordem:

1. já ligada a esta pessoa do Authentik (`sub`);
2. **mesmo nome de usuário** (sem diferenciar maiúsculas), entre as contas ainda não ligadas;
3. **mesmo e-mail**, entre as contas ainda não ligadas;
4. nenhuma: cria uma conta nova (só com `OIDC_AUTO_CREATE=true`).

Ligada, a conta continua a mesma: playlists (e as compartilhadas), músicas, histórico e
métricas ficam onde estão.

Passo a passo:

1. Em **Usuários**, confira cada conta: usuário e e-mail. As ainda não ligadas aparecem como
   "não ligada". Corrija ali o que precisar (a página avisa antes de salvar que isso muda a
   ligação). O e-mail é único: duas contas não podem ter o mesmo.
2. Crie as pessoas no Authentik com **o mesmo usuário** (ou, se for outro, o mesmo e-mail) da
   conta daqui, e ponha no grupo `bergastream_users`.
3. Quem ainda não tem conta no Bergastream: crie em **Usuários → Novo usuário** com o mesmo
   usuário/e-mail do Authentik (com e-mail, o convite já explica como entrar), ou deixe
   `OIDC_AUTO_CREATE=true`.
4. Cada pessoa entra uma vez por "Entrar com o Authentik". A conta passa a mostrar "Authentik".
5. Ligou na conta errada? **Desligar do Authentik** no menu da conta (desconecta os
   aparelhos), corrija usuário ou e-mail e entre de novo.
6. Todas ligadas: `OIDC_AUTO_CREATE=true` para quem chegar depois ganhar conta sozinho.

Com `OIDC_AUTO_CREATE=false`, quem não casa com nenhuma conta vê "Não há uma conta do Bergastream
para este usuário" em vez de ganhar uma conta vazia por engano.

Pelo terminal também dá: `list-users`, `set-email` e `unlink-authentik`
([USUARIOS.md](USUARIOS.md)).

**Enquanto houver contas por ligar**, deixe desligado no Authentik que as pessoas troquem o
próprio nome de usuário ou e-mail (**System → Settings**: *Allow users to change username* e
*Allow users to change email*). A ligação usa esses dois campos, e alguém poderia pôr o nome ou o
e-mail de outra pessoa e entrar na conta dela. Depois de ligada, a conta só responde ao `sub`.

## 5. Apps antigos e o login por senha

- Apps **0.3.x** só sabem entrar por senha e usam a rota `/api-access-bypass`. Eles mostram a
  atualização ao abrir; depois de atualizados, entram pelo Authentik.
- Enquanto alguém usar a 0.3.x, mantenha `PASSWORD_LOGIN=true` (a tela da 0.4 mostra
  "Entrar com o Authentik" e, recolhido, "Entrar com usuário e senha").
- Todos na 0.4: `PASSWORD_LOGIN=auto` (só Authentik), e apague as linhas `bergastream-bypass` do
  `docker-compose.yml` ([DEPLOY.md](DEPLOY.md)).
- Quem já está logado continua logado: a sessão do Bergastream não depende do Authentik.
  "Sair" e entrar de novo passa pelo Authentik.
- Pelo mesmo motivo, tirar alguém do grupo só barra o **próximo** login. Para tirar na hora:
  **Usuários → (pessoa) → Desativar conta** (ou só "Desconectar os aparelhos").

## 6. Depois de ligada: quem muda o quê

O Authentik é a fonte de **usuário, nome, e-mail e senha**. A cada login pelo Authentik, o
Bergastream copia usuário, nome e e-mail de lá. Como a ligação é pelo `sub`, trocar qualquer um
deles no Authentik **não desfaz a ligação**. Se o valor novo já for de outra conta do Bergastream,
fica o atual e o log da API avisa.

| Quero mudar | Onde |
|---|---|
| Usuário, nome, e-mail, senha (a própria pessoa) | Authentik → "Minha conta". No Bergastream: **Ajustes → Conta → Gerenciar no Authentik** |
| Os mesmos dados de outra pessoa (admin) | Authentik → **Directory → Users** (atalho em **Usuários → Abrir no Authentik**) |
| Senha esquecida | Authentik → "Esqueceu a senha?" na tela de login (fluxo de recuperação, abaixo) |
| Quem é admin do Bergastream | Grupo `bergastream_admins` (com `OIDC_ADMIN_GROUP`); senão, **Usuários** |
| Desativar, desconectar aparelhos, mandar aviso por e-mail | **Usuários** no Bergastream |

Contas ainda **não ligadas** (e com `PASSWORD_LOGIN=true`) continuam editáveis no Bergastream,
com senha própria e "Esqueci minha senha" por e-mail (SMTP do Bergastream, `SMTP_*` no `.env`).

Para as pessoas poderem trocar usuário e e-mail sozinhas no Authentik, **depois que todas as
contas estiverem ligadas**:

1. **System → Settings**: ligue *Allow users to change username* e *Allow users to change email*.
2. Senha esquecida: o Authentik precisa do SMTP dele (`AUTHENTIK_EMAIL__*` no stack authentik) e
   de um fluxo de recuperação. **Flows and Stages → Flows → Import** do blueprint de exemplo
   "Recovery with email verification"; depois, no stage de identificação do login
   (`default-authentication-identification`), escolha esse fluxo em *Recovery flow*. A tela de
   login passa a mostrar "Esqueceu a senha?".
3. Trocar a senha logado já vem pronto em "Minha conta" (fluxo padrão de troca de senha).

## 7. Testar

1. Navegador anônimo → `https://bergastream.example.com` → "Entrar com o Authentik" → login no
   Authentik → volta para o Início já logado.
2. Android (0.4): servidor `bergastream.example.com` → "Entrar com o Authentik" → o navegador
   abre e, no fim, volta ao app.
3. Windows/Linux (0.4): o navegador padrão abre; no fim a aba diz "Pronto! Pode fechar esta aba"
   e o app entra.
4. Uma conta fora de `bergastream_users`: deve ser barrada (no Authentik ou com "Sua conta não
   tem acesso ao Bergastream").

## Problemas comuns

As mensagens aparecem na página de erro do Bergastream; os detalhes ficam em
`docker compose logs api | grep -i oidc`.

| Sintoma | Causa provável |
|---|---|
| Authentik: "Redirect URI Error" | A Redirect URI do provider não é exatamente `OIDC_REDIRECT_URI` (https, domínio, caminho). |
| "Configure uma chave de assinatura (RS256)…" | Provider sem Signing Key (passo 2). |
| "Não foi possível confirmar o login no Authentik." | `OIDC_ISSUER` diferente do Issuer do provider (falta a barra final?) ou `BERGASTREAM_SSO_CLIENT_ID` errado. O log mostra o motivo. |
| "Sua conta não tem acesso ao Bergastream." | A pessoa não está em `bergastream_users`, ou o escopo `profile` (que traz os grupos) não está no provider. |
| "Não há uma conta do Bergastream para este usuário." | `OIDC_AUTO_CREATE=false` e nada casou: veja o passo 4. |
| "Authentik indisponível" | A API não alcança o Authentik: confira `OIDC_INTERNAL_URL` e se o `bergastream-api` está na rede `bergatrix-proxy` (`docker network inspect bergatrix-proxy`). |
| "Login expirado…" | Mais de 10 min entre abrir o Authentik e voltar, ou a mesma página aberta duas vezes. Tente de novo. |
| Android não volta ao app depois do Authentik | Versão do app anterior à 0.4, ou o navegador perguntou "Abrir com Bergastream?" e foi negado. |
| Login por senha responde "Entre pelo Authentik" | `PASSWORD_LOGIN=auto` (ou `false`) com o OIDC configurado. Use `true` na transição. |
