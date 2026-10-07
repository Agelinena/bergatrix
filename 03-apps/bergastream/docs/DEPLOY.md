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

  A versão nova usa outra pasta de dados (`/mnt/storage/docker_data/bergastream`) e outro banco:
  nada da antiga é reaproveitado nem apagado.

## 1. Código e pastas

```bash
cd ~/bergatrix && git pull
cd 03-apps/bergastream

sudo mkdir -p /mnt/storage/docker_data/bergastream/{db,redis,music,deemix/config,deemix/downloads}
sudo chown -R 1000:1000 /mnt/storage/docker_data/bergastream/{music,deemix}
```

## 2. `.env`

```bash
cp .env.example .env
nano .env
```

| Variável | O que pôr |
|---|---|
| `STORAGE_PATH` | `/mnt/storage/docker_data/bergastream` (já vem assim) |
| `DOMAIN` | `daberga.com` (já vem assim) |
| `POSTGRES_PASSWORD` | senha nova (gere abaixo) |
| `DATABASE_URL` | a mesma senha no lugar de `troque_esta_senha` |
| `JWT_SECRET` | segredo novo (gere abaixo) |
| `DEEMIX_ARL` | cookie `arl` do deezer.com logado |
| `SPOTIFY_CLIENT_ID/SECRET` | opcional (sem eles a busca usa só o YouTube Music) |

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

## 7. Backup

Tudo está em `/mnt/storage/docker_data/bergastream`. O banco é pequeno; as músicas podem ser
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
| "Muitas tentativas" no login | 5 senhas erradas em 15 min para aquele usuário e IP: espere ou troque a senha (USUARIOS.md). |
