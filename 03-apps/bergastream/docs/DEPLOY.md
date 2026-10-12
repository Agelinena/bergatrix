# Bergastream — subir no servidor

Endereço final: **https://bergastream.daberga.com**

| Quem acessa | Caminho | Proteção |
|---|---|---|
| Navegador fora de casa | `bergastream.daberga.com` | Authentik → login do Bergastream |
| Notebook, celular e firewall de confiança | `bergastream.daberga.com` | direto → login do Bergastream |
| Apps Android/Windows/Linux (qualquer rede) | `bergastream.daberga.com/api-access-bypass/api/…` | só o login do Bergastream (JWT + limite de tentativas) |

Os apps só pedem `bergastream.daberga.com` e descobrem o prefixo `/api-access-bypass` sozinhos.
O bypass libera **só a API**: o app web continua atrás do Authentik.

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
  `crowdsec-bouncer`, `public-auth` e `api-access-bypass` (os mesmos do Bitwarden).
- DNS de `bergastream.daberga.com` apontando para o servidor (o curinga `*.daberga.com` já resolve).
- **Pare a versão antiga** (`03-apps/bergastream02`) se ela estiver rodando: ela usa os mesmos
  nomes de container e o mesmo domínio.

  ```bash
  cd ~/bergatrix/03-apps/bergastream02 && docker compose down   # os dados dela ficam onde estão
  ```

  A versão nova usa outra pasta de dados (`/mnt/storage/docker_volumes/bergastream`) e outro banco:
  nada da antiga é reaproveitado nem apagado.

## 1. Código e pastas

```bash
cd ~/bergatrix && git pull
cd 03-apps/bergastream

sudo mkdir -p /mnt/storage/docker_volumes/bergastream/{db,redis,music,pydeps,lidarr/config,lidarr/music,deemix/config,deemix/downloads}
sudo chown -R 1000:1000 /mnt/storage/docker_volumes/bergastream/{music,pydeps,lidarr,deemix}
```

## 2. `.env`

```bash
cp .env.example .env
nano .env
```

| Variável | O que pôr |
|---|---|
| `STORAGE_PATH` | `/mnt/storage/docker_volumes/bergastream` (já vem assim) |
| `DOMAIN` | `daberga.com` (já vem assim) |
| `POSTGRES_PASSWORD` | senha nova (gere abaixo) |
| `DATABASE_URL` | a mesma senha no lugar de `troque_esta_senha` |
| `JWT_SECRET` | segredo novo (gere abaixo) |
| `DEEMIX_ARL` | cookie `arl` do deezer.com logado — conta **Premium** para MP3 320/FLAC (grátis = 128) |
| `LIDARR_API_KEY`, `USENET_DOWNLOADS_DIR` | FLAC das playlists pela Usenet (passo 7); sem a chave o Lidarr fica de fora |

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

## 4. Criar os usuários

Não há cadastro aberto (`ALLOW_REGISTRATION=false`). A senha é pedida no terminal (mínimo 8 caracteres).
Detalhes e outros comandos em [USUARIOS.md](USUARIOS.md).

```bash
docker compose exec api python -m app.auth.cli create-user lucas --admin
docker compose exec api python -m app.auth.cli create-user marina
docker compose exec api python -m app.auth.cli list-users
```

O usuário `demo` existe só no ambiente de desenvolvimento local; não vai para o servidor.

## 5. Testar

1. **Navegador de um aparelho de confiança:** https://bergastream.daberga.com → login `lucas` → buscar e tocar.
2. **Navegador pelo 4G:** pede o Authentik antes e depois o login do Bergastream.
3. **API pelo bypass** (de qualquer lugar):

   ```bash
   curl -s https://bergastream.daberga.com/api-access-bypass/api/auth/config
   # {"registration_enabled":false}
   ```

4. **App:** instale pela [release do GitHub](https://github.com/Agelinena/bergatrix/releases)
   e entre com servidor `bergastream.daberga.com`, usuário e senha. Teste também pelo 4G.

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
   sudo mkdir -p /mnt/storage/docker_volumes/bergastream/lidarr/{config,music}
   sudo chown -R 1000:1000 /mnt/storage/docker_volumes/bergastream/lidarr
   ```

   No `.env`: `USENET_DOWNLOADS_DIR=/mnt/storage/docker_volumes/jellyflix/downloads` (a pasta que
   o SABnzbd monta como `/downloads`: o Lidarr precisa ver os downloads no mesmo caminho).
   `docker compose up -d` sobe o Lidarr junto.

2. Em `https://lidarr.daberga.com` (rede local/Tailscale), na primeira vez:
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
máximo 100 buscas por dia (`LIDARR_DAILY_SEARCHES`); as outras faixas esperam a vez. Ajuste ao
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

Tudo está em `/mnt/storage/docker_volumes/bergastream`. O banco é pequeno; as músicas podem ser
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
| App diz "Servidor não encontrado" | Bypass não está casando: confira o `curl` do passo 5.3 e o middleware `api-access-bypass@file`. |
| 404 em tudo | Rede `bergatrix-proxy` errada ou regra descartada: `docker logs traefik 2>&1 \| grep -i bergastream`. |
| 502 no navegador | API parada ou reiniciando: `docker compose ps` e `docker compose logs api`. |
| Músicas não baixam do Deezer | ARL vencido: pegue o cookie de novo, troque no `.env`, `docker compose up -d deemix api worker`. O YouTube segue como alternativa. |
| Música falha no Deemix e também no YouTube; log do worker: "bloqueado pelo Modo Restrito" | O DNS da rede (AdGuard → "pesquisa segura") força o Modo Restrito do YouTube e barra músicas explícitas. No AdGuard Home: **Configurações → Configurações do cliente → Adicionar cliente** com o IP do servidor, desmarque "Usar configurações globais" e desligue a pesquisa segura só para ele. |
| Log do worker: "Sign in to confirm you're not a bot" em todos os clientes | O YouTube está bloqueando o IP. Confira se o `bergastream-pot` está de pé (`docker compose ps`); se persistir, use cookies de uma conta **secundária** (`YT_COOKIES_FILE`, ver `.env.example`). Muitos pedidos seguidos geram HTTP 429 por um tempo. |
| Aba Spotify da busca dá "O Spotify não respondeu" | O Spotify mudou o web player. O worker testa todo dia e instala a versão nova da biblioteca sozinho quando sai; para ver agora: `docker compose exec worker python -m app.search.spotify_health` e `GET /api/server/status` → `spotify`. |
| Log do worker: "Lidarr fora do ar: ReadTimeout" | O Lidarr demorou mais de 30 s (normal enquanto carrega discografias de artistas novos). A faixa é conferida de novo em 1 h. |
| Log do worker: "álbum … não encontrado no MusicBrainz" | O Lidarr não achou o álbum (nome diferente no MusicBrainz ou lançamento só digital). A faixa fica em 320 e o worker tenta de novo em 7 dias. |
| Log do worker: "arquivo do Lidarr não visível aqui" | O worker não vê `${STORAGE_PATH}/lidarr/music` (volume do compose alterado?). |
| Lidarr não importa o que o SABnzbd baixou ("No files found" / caminho inexistente) | `USENET_DOWNLOADS_DIR` não é a pasta que o SABnzbd monta como `/downloads`. |
| "Muitas tentativas" no login | 5 senhas erradas em 15 min para aquele usuário e IP: espere ou troque a senha (USUARIOS.md). |
