# Doberga

Utilidades do dia a dia da família: lista de compras, recorrentes, calendário e notas, num app Flutter (Android,
Windows, Linux e web) que funciona sem internet. Endereço: `doberga.${DOMAIN}`.

Arquitetura, protocolo de sync e fases: [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

| Fase | O quê | Estado |
|---|---|---|
| 0 | Núcleo: login, Usuários, espaços e convites, sync offline, Hoje | Servidor testado; app escrito, falta compilar |
| 1 | Lista de compras | – |
| 2 | Recorrentes, Hoje/Semana, notificações | – |
| 3 | Calendário | – |
| 4 | Notas | – |

## Subir

1. **Authentik** (passo a passo abaixo): aplicação `doberga`, grupos `doberga_users` e `doberga_admins`.
2. **`.env`:** `cp .env.example .env` e preencha (senhas com `openssl rand -hex 32`).
3. **Pastas:**
   ```bash
   sudo mkdir -p /srv/appdata/doberga/{postgres,redis}
   ```
4. **Subir:**
   ```bash
   docker compose up -d --build
   curl -s https://doberga.<domínio>/api/app/version
   ```

## Authentik

Mesmo modelo do Berganews e do Bergastream ([docs/05-acesso.md](../../docs/05-acesso.md)).

**Directory → Groups:** `doberga_users` (todo mundo que usa) e `doberga_admins` (página Usuários; ponha também em
`doberga_users`).

**Applications → Providers → Create → OAuth2/OpenID Provider**

| Campo | Valor |
|---|---|
| Name | `doberga` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | **Confidential** |
| Redirect URIs | `Strict` · `https://doberga.example.com/api/auth/oidc/callback` |
| Signing Key | `authentik Self-signed Certificate` (RS256) |
| Scopes | `openid`, `email`, `profile` |
| Subject mode | `Based on the User's hashed ID` (não mude depois: é o que liga a conta) |
| Include claims in id_token | ligado |

**Applications → Applications → Create:** nome `Doberga`, slug `doberga`, provider `doberga`, launch URL
`https://doberga.example.com`. Em **Policy / Group / User Bindings**, vincule o grupo `doberga_users`.

Copie o Client ID e o Client Secret para `DOBERGA_SSO_CLIENT_ID` e `DOBERGA_SSO_CLIENT_SECRET`.

## Como funciona, em resumo

- **Espaços:** cada pessoa tem o seu espaço pessoal, e qualquer pessoa cria grupos e convida outras por link
  (`/convite/<token>`, vale 7 dias e 10 usos). O admin só controla quem usa o app; não vê o conteúdo dos grupos.
- **Offline:** o app grava tudo no aparelho e manda depois. O servidor recebe as operações por `POST /api/sync/push`
  e devolve o que mudou por `POST /api/sync/pull`. A web funciona só online.
- **Tempo real:** `GET /api/sync/events` (SSE) avisa os aparelhos de que algo mudou.
- **Sinal ruim:** um refresh token recém-trocado ainda vale por 2 minutos, para a sessão não cair quando a resposta
  da renovação se perde na rede.

## Testes

```bash
# Servidor: Postgres de verdade (pgserver), sem Docker
cd backend
pip install -r requirements.txt pgserver
python tests/integration_pgserver.py . /tmp/doberga-pg

# App
cd frontend
flutter pub get
flutter analyze
flutter test
```

## App

O código das plataformas (`android/`, `windows/`, `linux/`, `web/`) veio do Berganews, renomeado para
`com.bergatrix.doberga`. **Os ícones ainda são os do Berganews.** Para trocar: novos PNGs em
`android/app/src/main/res/mipmap-*`, `web/icons`, `web/favicon.png` e `windows/runner/resources/app_icon.ico`.
