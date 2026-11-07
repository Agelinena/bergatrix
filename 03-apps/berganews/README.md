# Berganews

Leitor de notícias (RSS) da família: cada pessoa assina os veículos que quiser, lê a matéria inteira dentro do app,
sem anúncio, e vê a mesma notícia de vários veículos agrupada numa história, com linha do tempo. O resumo e uma
newsletter diária vêm nas próximas fases. Toda a IA roda no Ollama local.

Arquitetura, modelo de dados e fases: [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

| Serviço | O que faz | Redes |
|---|---|---|
| `web` | App web (Flutter) no nginx, que repassa `/api/` à API; tem a rota no Traefik | `berganews-internal`, `bergatrix-proxy` |
| `api` | API do app, login pelo Authentik, imagens pelo servidor | `berganews-internal`, `bergatrix-proxy` (Authentik) |
| `fetcher` | Coleta os feeds e o texto completo, limpeza diária | só `berganews-internal` (sai pelo `egress`) |
| `ai` | No Ollama: tradução sob demanda, embeddings e histórias (depois: resumos, newsletter) | `berganews-internal`, `bergatrix-ai` |
| `egress` | Proxy de saída (smokescreen): recusa redes privadas | `berganews-internal`, `berganews-egress` |
| `db` | Postgres 16 com pgvector | `berganews-internal` |
| `redis` | Filas e estado do login | `berganews-internal` |

Endereço: `news.${DOMAIN}` (app web e API).

## Subir

1. **Authentik:** crie a aplicação (abaixo).
2. **Modelos de IA**, uma vez: `docker exec ollama ollama pull gemma3:4b` (tradução) e
   `docker exec ollama ollama pull bge-m3` (histórias).
3. **Pastas** no servidor, com o dono 1000:

   ```bash
   sudo mkdir -p /srv/appdata/berganews/{postgres,redis} /srv/cache/berganews/images
   sudo chown -R 1000:1000 /srv/cache/berganews
   ```

4. `cp .env.example .env`, preencha, e `docker compose up -d --build`.

## App

O app fica em [frontend/](frontend/) (Flutter, sem geração de código), igual para web, Android, Windows e Linux:
abas configuráveis (Todas, Veículos, Pastas, Histórias, Salvos), leitor sem anúncio com tradução, linha do tempo da
história com juntar e separar, busca, painel Aparência, veículos, pastas, OPML e a página Usuários do admin.

- **Web:** `news.<domínio>`, montado pelo serviço `web` no `docker compose up -d --build`.
- **Android, Windows e Linux:** `git tag berganews-v0.1.0 && git push origin berganews-v0.1.0` publica a release
  ([.github/workflows/berganews-release.yml](../../.github/workflows/berganews-release.yml)). O APK usa os mesmos
  secrets de assinatura do Bergastream. No primeiro login, o app pede o endereço do servidor.
- **Conferência:** cada push que mexe no app roda análise, testes e o build da web
  ([berganews-app.yml](../../.github/workflows/berganews-app.yml)).

Fora da web, o Authentik volta ao app por `com.bergatrix.berganews://auth` (Android) ou por um endereço local
`http://127.0.0.1:<porta>/callback` (computador). Esses endereços não vão no provider: quem fala com o Authentik
é o servidor, e o callback cadastrado é só o `https://news.<domínio>/api/auth/oidc/callback`.

## Authentik

Padrão OIDC de [docs/05-acesso.md](../../docs/05-acesso.md):

| Campo | Valor |
|---|---|
| Provider | OAuth2/OpenID, *Confidential* |
| Redirect URI (Strict) | `https://news.<domínio>/api/auth/oidc/callback` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Signing key | `authentik Self-signed Certificate` (RS256) |
| Scopes | `openid`, `profile`, `email` (o claim `groups` vem no `profile`) |
| Acesso | Binding da aplicação ao grupo `berganews_users` |

Crie também o grupo `berganews_admins` (quem vê a página Usuários). O issuer vai em `BERGANEWS_OIDC_ISSUER`,
o client ID e o secret em `BERGANEWS_SSO_CLIENT_ID` e `BERGANEWS_SSO_CLIENT_SECRET`.

## Usuários

Como no Bergastream, as contas vêm do Authentik: quem está em `berganews_users` entra por "Entrar com o Authentik",
e a conta é criada no primeiro login. Nome, usuário, e-mail e admin seguem o Authentik a cada login.

Na página **Usuários** (admin): desativar ou reativar a conta e desconectar os aparelhos. Desativar não apaga nada
(assinaturas, salvos e pastas ficam). Para tirar o acesso: tire a pessoa do grupo no Authentik **e** desative aqui
(as sessões abertas não dependem do Authentik).

## Matérias, vídeos e retenção

- O texto vem da página do veículo, com parágrafos, negrito, links, citações e fotos. Com paywall, fica o começo
  da matéria e o app mostra "Só o trecho", com o botão para o site.
- Vídeos aparecem como cartões com a miniatura e abrem no player do veículo. O arquivo de vídeo não é copiado
  (vem em pedaços, muitas vezes protegido, e pesa centenas de MB).
- Matérias com mais de **5 meses** somem, com as imagens, **menos as salvas**: ao salvar, as imagens da matéria
  são guardadas no servidor e ficam enquanto ela estiver salva. O prazo é `BERGANEWS_ARTICLE_RETENTION_DAYS`.
- Feed parado (a matéria mais recente é mais velha que o prazo) é recusado ao assinar, com a data da última.

## Tradução

O leitor mostra o botão **Traduzir** quando a matéria está num idioma diferente do de leitura (padrão: português),
ou, numa matéria em português, para o inglês. Quem traduz é o modelo local, um bloco de texto por vez; o app mostra o
progresso e alterna entre o original e a tradução. A tradução fica guardada: a segunda pessoa que pedir já recebe
pronta. Links e negrito dentro do parágrafo se perdem na tradução (o original continua a um toque).

## Histórias

O worker `ai` gera o embedding de cada matéria nova (manchete + começo do texto, com o `bge-m3`) e a põe numa
história: a mesma notícia em vários veículos, inclusive em outro idioma. A aba "IA" mostra as histórias com 2
veículos ou mais, e a tela da história mostra a linha do tempo, com os veículos que a pessoa não assina como "também
noticiado por". Durante o dia isso anda em lotes pequenos; o resumo (fase 3) virá de madrugada.

Quando o agrupamento errar, qualquer pessoa pode **juntar** duas histórias ou **separar** matérias de uma. Isso vale
para a casa toda e vira exemplo para calibrar.

### Calibrar o limite

1. Rotule exemplos: `GET /api/admin/stories/pairs/suggest` lista pares perto do limite e `POST /api/admin/stories/pairs`
   grava "mesma notícia" ou não. Juntar e separar também gravam exemplos.
2. `GET /api/admin/stories/calibration` mostra precisão, cobertura e F1 para cada limite, e o melhor.
3. Ajuste `BERGANEWS_STORY_THRESHOLD` no `.env`, rode `docker compose up -d` e peça
   `POST /api/admin/stories/recluster?days=3` para refazer os últimos dias (o que foi mexido à mão fica).

## Dados pessoais (LGPD)

O banco guarda, por pessoa: nome, usuário, e-mail e identificador do Authentik, assinaturas, pastas, o que leu e
salvou, as preferências e quem juntou ou separou histórias. Trate os backups (`pg_dump`) como dado pessoal.

## Testes

```bash
cd backend && pip install -r requirements.txt pytest && python -m pytest tests
```

Integração com Postgres de verdade (com pgvector), sem Docker:

```bash
cd backend && pip install pgserver && python tests/integration_pgserver.py . /tmp/berganews-pg
```
