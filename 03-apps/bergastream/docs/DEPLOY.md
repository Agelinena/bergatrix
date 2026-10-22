# Bergastream — subir no servidor

Endereço final: **https://bergastream.example.com** (troque `example.com` pelo `${DOMAIN}` real).

Acesso no modelo **E** do `docs/plano-acesso.md` da raiz: **uma rota pública só**, com CrowdSec e
**sem forward-auth**. O login é feito dentro do app com o **Authentik (OIDC)**; a API exige o token
dela em toda chamada. Configuração do Authentik: [AUTHENTIK.md](AUTHENTIK.md).

| Quem acessa | Caminho | Login |
|---|---|---|
| Navegador e apps 0.4+ (qualquer rede) | `bergastream.example.com` | "Entrar com o Authentik" |
| Apps 0.3.x ainda não atualizados | `bergastream.example.com/api-access-bypass/api/…` | **temporário**, ver abaixo |

A rota `/api-access-bypass` continua no compose só até todos os aparelhos estarem na 0.4: os apps
0.3.x salvaram o servidor com esse caminho. A 0.4 volta sozinha para o endereço simples ao abrir.
Depois, apague as linhas `bergastream-bypass` do `docker-compose.yml` (antes de tirar o middleware
`api-access-bypass` do `dynamic.yml`).

```
Traefik (bergatrix-proxy) ──► bergastream-web (nginx: app web + /api/ → API)
                                   │  bergastream-internal (sem internet)
                                   ├── bergastream-api ──┐
                                   ├── bergastream-worker├─ bergastream-egress (internet:
                                   ├── bergastream-deemix┘   Spotify, YouTube, Deezer)
                                   ├── bergastream-db (Postgres 16)
                                   └── bergastream-redis
```

## 0. Antes de começar

- Traefik rodando com a rede `bergatrix-proxy` e, no `dynamic.yml`, os middlewares
  `crowdsec-bouncer` e (enquanto houver apps 0.3.x) `api-access-bypass`.
- Authentik com o provider e a aplicação do Bergastream ([AUTHENTIK.md](AUTHENTIK.md)). A API entra
  na rede `bergatrix-proxy` para falar com o `authentik-server` direto.
- DNS de `bergastream.example.com` apontando para o servidor (o curinga do `${DOMAIN}` já resolve).
- **Pare a versão antiga** (`03-apps/bergastream02`) se ela estiver rodando: ela usa os mesmos
  nomes de container e o mesmo domínio.

  ```bash
  cd ~/bergatrix/03-apps/bergastream02 && docker compose down   # os dados dela ficam onde estão
  ```

  A versão nova usa outras pastas de dados (`${APPDATA_PATH}/bergastream`, `${MEDIA_PATH}/musica`) e outro banco:
  nada da antiga é reaproveitado nem apagado.

## 1. Código e pastas

```bash
cd ~/bergatrix && git pull
cd 03-apps/bergastream

# Use os mesmos valores do .env (passo 2)
APPDATA_PATH=/srv/appdata CACHE_PATH=/srv/cache MEDIA_PATH=/mnt/nas/media

sudo mkdir -p $APPDATA_PATH/bergastream/{postgres,redis,deemix,lidarr,youtube} \
              $CACHE_PATH/bergastream/pydeps \
              $MEDIA_PATH/musica/bergastream/deemix_dl $MEDIA_PATH/musica/lidarr
sudo chown -R 1000:1000 $APPDATA_PATH/bergastream/{deemix,lidarr} $CACHE_PATH/bergastream \
                        $MEDIA_PATH/musica/bergastream $MEDIA_PATH/musica/lidarr
```

## 2. `.env`

```bash
cp .env.example .env
nano .env
```

| Variável | O que pôr |
|---|---|
| `DOMAIN`, `TZ`, `PUID`, `PGID` | base Bergatrix (ver `docs/03-padrao-stacks.md` na raiz) |
| `APPDATA_PATH`, `CACHE_PATH`, `MEDIA_PATH` | raízes de armazenamento do servidor (ver `docs/02-armazenamento.md` na raiz) |
| `POSTGRES_PASSWORD` | senha nova (gere abaixo) |
| `DATABASE_URL` | a mesma senha no lugar de `troque_esta_senha` |
| `JWT_SECRET` | segredo novo (gere abaixo) |
| `OIDC_*`, `PASSWORD_LOGIN` | login pelo Authentik ([AUTHENTIK.md](AUTHENTIK.md), passo 3) |
| `SMTP_*`, `APP_URL` | e-mails de aviso, convite e "esqueci minha senha" (opcional; pode ser o SMTP do Authentik) |
| `DEEMIX_ARL` | cookie `arl` do deezer.com logado — conta **Premium** para MP3 320/FLAC (grátis = 128) |
| `LIDARR_API_KEY` | FLAC das playlists pela Usenet (passo 7); sem a chave o Lidarr fica de fora |

O Spotify não precisa de conta nem de chave (as antigas `SPOTIFY_CLIENT_ID/SECRET` podem sair do `.env`).

```bash
openssl rand -base64 36 | tr -d '/+=' | cut -c1-40   # rode duas vezes: senha do banco e JWT_SECRET
```

Use senhas só com letras e números (vão dentro da `DATABASE_URL`).

Confira se tudo resolveu (nenhum `${...}` vazio):

```bash
docker compose config | grep -E 'Host\(|/mnt/storage' | head
```

## 3. Subir

```bash
docker compose up -d --build      # 1ª vez: o build do app web leva ~5–10 min
docker compose ps                 # db/redis/api healthy, migrate "exited (0)"
docker compose logs migrate       # migrações aplicadas
docker logs traefik 2>&1 | grep -i bergastream   # sem erro de parsing das regras
```

## 4. Usuários

Com o Authentik configurado, as contas vêm de lá: quem está no grupo `bergastream_users` entra, e
a conta do Bergastream é criada (ou ligada à que já existia) no primeiro login. Para ligar as
contas antigas sem perder playlists e histórico, veja [AUTHENTIK.md](AUTHENTIK.md#4-contas-que-já-existem).

Sem Authentik (ou com `PASSWORD_LOGIN=true`), as contas com senha são criadas pela linha de
comando ([USUARIOS.md](USUARIOS.md)):

```bash
docker compose exec api python -m app.auth.cli create-user <usuario> --admin
docker compose exec api python -m app.auth.cli list-users
```

O usuário `demo` existe só no ambiente de desenvolvimento local; não vai para o servidor.

## 5. Testar

1. **Configuração do login** (de qualquer lugar):

   ```bash
   curl -s https://bergastream.example.com/api/auth/config
   # {"registration_enabled":false,"oidc_enabled":true,"password_login_enabled":false}
   ```

2. **Navegador:** https://bergastream.example.com → "Entrar com o Authentik" → login no Authentik
   → volta para o app já logado → buscar e tocar.
3. **App:** instale pela [release do GitHub](https://github.com/Agelinena/bergatrix/releases), servidor
   `bergastream.example.com` → "Entrar com o Authentik". O Android abre o navegador e volta ao app;
   no Windows/Linux, a aba do navegador diz "Pronto! Pode fechar esta aba". Teste também pelo 4G.
4. **App 0.3.x antigo** (enquanto a rota temporária existir):

   ```bash
   curl -s https://bergastream.example.com/api-access-bypass/api/auth/config
   ```

## 6. Atualizar o servidor depois

```bash
cd ~/bergatrix && git pull && cd 03-apps/bergastream
docker compose up -d --build      # as migrações novas rodam sozinhas (serviço migrate)
```

## 7. Qualidade: Deezer Premium e FLAC pela Usenet (Lidarr)

**Deezer Premium.** Depois de assinar, pegue o cookie `arl` de novo no deezer.com logado
(DevTools → Application → Cookies), troque `DEEMIX_ARL` no `.env` e:

```bash
docker compose up -d deemix api worker
```

Sob demanda as músicas passam a vir em MP3 320. As faixas de playlist tentam FLAC: se o plano
incluir (no Brasil o Premium costuma incluir; via operadora, como TIM, fica em 320), já resolve
pelo próprio Deemix. Se o log do worker disser "a conta do ARL não tem FLAC", fica o 320 e o
Lidarr cuida do FLAC.

**Lidarr** (serviço `bergastream-lidarr` deste compose; baixa pela Usenet com o SABnzbd e os
indexadores do Prowlarr do servidor, que ele alcança pela rede do Traefik):

1. Pastas com o dono certo **antes** de subir (senão o Docker cria como root e o Lidarr acusa
   "Folder '/music' is not writable"). Já estão no passo 1; se o servidor já existia:

   ```bash
   sudo mkdir -p $APPDATA_PATH/bergastream/lidarr $MEDIA_PATH/musica/lidarr
   sudo chown -R 1000:1000 $APPDATA_PATH/bergastream/lidarr $MEDIA_PATH/musica/lidarr
   ```

   O Lidarr monta `${MEDIA_PATH}/downloads` como `/downloads`, a mesma pasta do SABnzbd do stack
   jellyfin: ele precisa ver os downloads no mesmo caminho.
   `docker compose up -d` sobe o Lidarr junto.

2. Em `https://lidarr.<seu domínio>` (rede local/Tailscale), na primeira vez:
   - **Settings → General → Security:** crie usuário e senha (método "Forms").
   - **Settings → Media Management → Root Folders:** adicionar `/music`, perfil de qualidade
     **Lossless**, metadados **Standard**.
   - **Settings → Profiles → Metadata Profiles → Standard:** marcar **Album**, **EP** e **Single**.
   - **Settings → Download Clients → + → SABnzbd:** host `sabnzbd`, porta `8080`, API key do
     SABnzbd (SABnzbd → Config → General), categoria `music`. No SABnzbd: Config → Categories →
     criar `music`.
   - **Prowlarr → Settings → Apps → + → Lidarr:** Prowlarr Server `http://prowlarr:9696`,
     Lidarr Server `http://bergastream-lidarr:8686`, API key do Lidarr → Test → Save. Depois
     **Sync App Indexers**. Os indexadores precisam ter a categoria de música (3000).
   - **Settings → General → API Key:** copie.

3. No `.env` do Bergastream: `LIDARR_API_KEY=<a chave>` e:

   ```bash
   docker compose up -d worker
   docker compose logs worker | grep upgrade    # "[upgrade] iniciado (Lidarr ligado)"
   ```

Como funciona: faixa que entra numa playlist ganha uma fila de melhoria. O worker tenta o Deemix
no melhor formato e, sem FLAC, pede ao Lidarr o **álbum** da faixa (o Lidarr só baixa por álbum),
monitorando só esse álbum do artista. O álbum é o de estúdio da gravação (ISRC → MusicBrainz),
não a coletânea do Spotify. Busca na hora, todo dia nos primeiros 3 dias (`UPGRADE_DAILY_DAYS`)
e depois toda semana; entre uma e outra, o Lidarr vigia a Usenet sozinho (RSS). Para não estourar
o limite do indexador, no máximo 30 álbuns ficam na fase diária (`LIDARR_MAX_ACTIVE`) e são no
máximo 100 buscas por dia (`LIDARR_DAILY_SEARCHES`), das quais 30 ficam para pedidos novos
(`LIDARR_REQUEST_RESERVE`: as buscas repetidas não gastam tudo); as outras faixas esperam a vez.
Download travado na fila do Lidarr (importação bloqueada — ex.: release com `.exe` — ou falha) há
mais de 1 h é removido do SABnzbd, o release vai para a blocklist e o álbum é buscado de novo; a
cada 6 h o worker confere se os artistas e álbuns ainda esperados continuam monitorados. Ajuste ao
limite de API do seu indexador (Prowlarr → Indexers → o indexador → *Query Limit*). O worker
confere a cada 30 min se o Lidarr já baixou (isso não gasta o indexador). Quando o
álbum chega, o FLAC da faixa é copiado e substitui o arquivo; quando nenhuma outra faixa de
playlist espera aquele álbum, ele deixa de ser monitorado e os arquivos são apagados do Lidarr
(só a música fica, ~30 MB em FLAC). `LIDARR_KEEP_ALBUMS=true` mantém os álbuns. Situação:
`GET /api/server/status` → `quality`.

**O que cada aparelho recebe:** o servidor guarda um arquivo por música (o melhor que conseguiu)
e entrega no nível escolhido no app (Ajustes → Qualidade: Wi-Fi, dados móveis e downloads):
Original (o arquivo como está, FLAC quando houver), Alta (MP3 320), Normal (AAC 160) ou
Econômica (AAC 96). Versões menores são convertidas uma vez e guardadas em `music/variants`
(apagadas depois de 7 dias sem uso). Nunca aumenta: pedindo FLAC de uma música que só existe em
320, vai o 320 — e as cópias offline são trocadas sozinhas quando o servidor melhora a música.

## 8. Backup

Banco e configs em `${APPDATA_PATH}/bergastream` (entra no backup do servidor); músicas em
`${MEDIA_PATH}/musica` (sem backup). O banco é pequeno; as músicas podem ser
baixadas de novo, mas as playlists, o histórico e os usuários não:

```bash
docker compose exec -T db pg_dump -U bergastream bergastream | gzip > bergastream-$(date +%F).sql.gz
```

Restaurar num banco vazio:

```bash
gunzip -c bergastream-AAAA-MM-DD.sql.gz | docker compose exec -T db psql -U bergastream bergastream
```

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| App diz "Servidor não encontrado" | Confira o `curl` do passo 5.1. Se ele devolve HTML (página do Authentik), a rota ainda está atrás do forward-auth: suba o `docker-compose.yml` atual. |
| "Entrar com o Authentik" mostra "Login pelo Authentik não terminou" na volta | Veja `docker compose logs api \| grep oidc`. Causas comuns em [AUTHENTIK.md](AUTHENTIK.md#problemas-comuns). |
| 404 em tudo | Rede `bergatrix-proxy` errada ou regra descartada: `docker logs traefik 2>&1 \| grep -i bergastream`. |
| 502 no navegador | API parada ou reiniciando: `docker compose ps` e `docker compose logs api`. |
| Músicas não baixam do Deezer | ARL vencido: pegue o cookie de novo, troque no `.env`, `docker compose up -d deemix api worker`. O YouTube segue como alternativa. |
| Música falha no Deemix e também no YouTube; log do worker: "bloqueado pelo Modo Restrito" | O DNS da rede (AdGuard → "pesquisa segura") força o Modo Restrito do YouTube e barra músicas explícitas. No AdGuard Home: **Configurações → Configurações do cliente → Adicionar cliente** com o IP do servidor, desmarque "Usar configurações globais" e desligue a pesquisa segura só para ele. |
| Log do worker: "Sign in to confirm you're not a bot" em todos os clientes | O YouTube está bloqueando o IP. Confira se o `bergastream-pot` está de pé (`docker compose ps`); se persistir, use cookies de uma conta **secundária** (`YT_COOKIES_FILE`, ver `.env.example`). Muitos pedidos seguidos geram HTTP 429 por um tempo. |
| Aba Spotify da busca dá "O Spotify não respondeu" | O Spotify mudou o web player. O worker testa todo dia e instala a versão nova da biblioteca sozinho quando sai; para ver agora: `docker compose exec worker python -m app.search.spotify_health` e `GET /api/server/status` → `spotify`. |
| Log do worker: "Lidarr fora do ar: ReadTimeout" | O Lidarr demorou mais de 30 s (normal enquanto carrega discografias de artistas novos). A faixa é conferida de novo em 1 h. |
| Log do worker: "álbum … não encontrado no MusicBrainz" | O Lidarr não achou o álbum (nome diferente no MusicBrainz ou lançamento só digital). A faixa fica em 320 e o worker tenta de novo em 7 dias. |
| Log do worker: "arquivo do Lidarr não visível aqui" | O worker não vê `${MEDIA_PATH}/musica/lidarr` (volume do compose alterado?). |
| Lidarr não importa o que o SABnzbd baixou ("No files found" / caminho inexistente) | O Lidarr e o SABnzbd precisam montar a mesma `${MEDIA_PATH}/downloads` como `/downloads`; confira o `MEDIA_PATH` nos dois `.env`. |
| Navegador entra, mas tudo diz "Sessão expirada" | A rota ainda passa pelo forward-auth do Authentik, que apaga o `Authorization` (está em `authResponseHeaders` no `dynamic.yml`). Desde a 0.4 a rota do Bergastream não tem forward-auth: suba o compose atual. |
| App web antigo depois de atualizar o servidor | O nginx manda o navegador conferir os arquivos a cada abertura (`Cache-Control`). Uma aba aberta há tempo mostra "Nova versão do Bergastream → Recarregar". Se nem assim: Ctrl+Shift+R. |
| Bloqueios do CrowdSec ao reconectar os apps | A exceção em `02-security/crowdsec/whitelists/bergatrix.yaml` vale para `/api-access-bypass/api/`. Com a 0.4 os apps usam `/api/`: inclua esse caminho na expressão. |
| "Muitas tentativas" no login | 5 senhas erradas em 15 min para aquele usuário e IP: espere ou troque a senha (USUARIOS.md). |
