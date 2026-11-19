# Migrações no servidor

Mudanças que precisam de passo manual **uma vez** no servidor (mover pasta, ordem de containers, rede nova). O `atualizar.sh` não faz isso sozinho: aplique a migração antes de rodá-lo. Cada uma diz como conferir se já foi aplicada.

Depois de aplicada e conferida, a migração pode sair deste arquivo (fica no histórico do git).

## Apps em repositório próprio e Legendarr fora do Jellyfin (nov/2026)

**Conferir se já foi aplicada:** `git -C ~/bergatrix submodule status` lista os seis apps sem `-` na frente, e `docker ps --filter name=legendarr-web --format '{{.Label "com.docker.compose.project"}}'` mostra `legendarr`.

O Bergastream, o Berganews, o Doberga, o Transcriptor, o Drop e o Legendarr agora são submódulos (veja [03-padrao-stacks.md](03-padrao-stacks.md#apps-com-repositório-próprio-submódulo)). No servidor, as pastas ainda têm o código antigo, e o `.env` mora dentro delas, então um `git pull` simples deixa o submódulo sem conseguir baixar. O script faz tudo na ordem, e confere antes de mexer:

```bash
# Enquanto os repositórios dos apps forem privados, o servidor precisa entrar no GitHub:
gh auth login && gh auth setup-git

cd ~/bergatrix && git fetch
git show origin/main:00-infrastructure/migrar-submodulos.sh > /tmp/migrar.sh
bash /tmp/migrar.sh
```

O que ele faz:

1. **Confere** que não há mudança local, que o pull é possível e que o servidor alcança os seis repositórios. Se algo falhar, para sem mexer em nada.
2. **Guarda os `.env`** em `~/.bergatrix-migracao-env`.
3. **Bergastream, Berganews e Doberga:** para, troca a pasta pelo submódulo, devolve o `.env` com `COMPOSE_FILE=docker-compose.yml:../<app>.bergatrix.yml` e sobe de novo.
4. **Transcriptor e Drop:** só troca a pasta e devolve o `.env`. As versões novas pedem um `.env` novo (README de cada um), então os containers antigos ficam no ar até você subir os novos.
5. **Legendarr:** derruba os três containers antigos da stack do Jellyfin (`--remove-orphans`), move `${APPDATA_PATH}/jellyfin/legendarr` para `${APPDATA_PATH}/legendarr` e `${CACHE_PATH}/jellyfin/optimizer` para `${CACHE_PATH}/legendarr/optimizer` (pede `sudo`), copia o `.env` do Jellyfin para `03-apps/legendarr` e sobe.

O Jellyfin é recriado no passo 5 com as versões fixas novas das imagens (sonarr, radarr, prowlarr, bazarr, sabnzbd, flaresolverr, torrent-indexer). Depois de conferir os apps, apague `~/.bergatrix-migracao-env` e, se quiser, as variáveis do Legendarr do `.env` do Jellyfin. A partir daí, o dia a dia é o `./00-infrastructure/atualizar.sh` ([07-ligar-e-desligar.md](07-ligar-e-desligar.md#atualizar)).

## Versões fixas das imagens (nov/2026)

**Conferir:** `docker inspect crowdsec --format '{{.Config.Image}}'` mostra `crowdsecurity/crowdsec:v1.8.2` (ou mais nova).

Depois da migração acima, uma vez: `./00-infrastructure/atualizar.sh --tudo`. Ele baixa as versões fixas de todas as stacks e recria o que mudou. **Atenção:** o `--tudo` recria toda stack que tem `.env`, inclusive o Transcriptor e o Drop. Configure os dois antes (seção abaixo), ou passe a lista de stacks sem eles.

## Transcriptor e Drop nas versões novas (nov/2026)

**Conferir:** `cd ~/bergatrix/03-apps/transcriptor && docker compose ps` mostra `transcriptor-db`, `transcriptor-api`, `transcriptor-worker` e `transcriptor-egress` no ar, e o login em `transcriptor.${DOMAIN}` passa pelo Authentik. O Drop abre em `drop.${DOMAIN}` e o container `drop` está só na rede `bergatrix-drop`.

- **Transcriptor:** a versão nova tem Postgres, login OIDC e worker isolado. O `.env` antigo não serve. Siga o [README](https://github.com/Agelinena/transcriptor#subir): aplicação no Authentik, `.env` com `POSTGRES_*` e `TRANSCRIPTOR_OIDC_ISSUER`, `TRANSCRIPTOR_SSO_CLIENT_ID` e `TRANSCRIPTOR_SSO_CLIENT_SECRET`, pastas com dono 1000. Mantenha a linha `COMPOSE_FILE`. As variáveis `TRANSCRIPTOR_API_KEY`, `TRANSCRIPTOR_SECRET_KEY` e `HF_TOKEN` não são mais usadas. O histórico antigo (`${APPDATA_PATH}/transcriptor/data`) não é migrado.
- **Drop:** só precisa do `DOMAIN` e do `COMPOSE_FILE` no `.env` e da rede `bergatrix-drop` (`cd ~/bergatrix/01-network/redes && docker compose run --rm redes`).

## Redes segmentadas (out/2026)

Antes, quase tudo ficava na `bergatrix-proxy`, e a rede de mídia (`media-internal`) era criada pela stack do jellyfin. Para aplicar no servidor:

```bash
cd ~/bergatrix
./00-infrastructure/derrubar-tudo.sh
# Recriar a bergatrix-proxy pelo arquivo de redes (antes era criada à mão)
# e apagar a rede de mídia antiga
docker network rm bergatrix-proxy media-internal
./00-infrastructure/subir-tudo.sh
```

Se a `bergatrix-proxy` não for recriada, tudo funciona do mesmo jeito. O Compose só avisa, a cada subida, que ela não foi criada por ele.

## Rede `bergatrix-auth` (nov/2026)

Antes, as APIs do Bergastream, Berganews e Doberga ficavam na `bergatrix-proxy` sem rota, só para falar com o Authentik. A ordem importa: o Authentik precisa estar na rede nova antes de as APIs saírem da antiga.

```bash
cd ~/bergatrix && git pull

# 1. Criar a rede
cd ~/bergatrix/01-network/redes && docker compose run --rm redes

# 2. Authentik entra na rede (o login fica fora por alguns segundos)
cd ~/bergatrix/02-security/authentik && docker compose up -d server

# 3. Os apps com login OIDC
for s in 03-apps/bergastream 03-apps/berganews 03-apps/doberga 03-apps/transcriptor \
         00-infrastructure/bergakup 04-monitoring/monitor; do
  (cd ~/bergatrix/$s && docker compose up -d)
done
```

Conferir:

```bash
# Esperado: authentik-server e os seis apps (bergastream-api, berganews-api, doberga-api,
# transcriptor-api, bergakup-app e monitor-grafana, ou como estiverem nomeados)
docker network inspect bergatrix-auth --format '{{range .Containers}}{{.Name}} {{end}}'

# As três APIs sem rota não podem mais aparecer aqui
docker network inspect bergatrix-proxy --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n' | grep -E 'bergastream-api|berganews-api|doberga-api'
```

Depois, sair e entrar de novo em cada app. Se o login de algum der "Authentik indisponível", o container dele não está na `bergatrix-auth`.

## Rede `bergatrix-office` (out/2026)

Antes, o Collabora ficava na `bergatrix-proxy`. A ordem importa: o Traefik precisa do alias antes de o Collabora sair da rede antiga.

```bash
# 1. Criar a rede (depois de acrescentá-la ao 01-network/redes/docker-compose.yml)
cd ~/bergatrix/01-network/redes && docker compose run --rm redes

# 2. Traefik entra na rede com o alias (interrompe as rotas por alguns segundos)
cd ~/bergatrix/01-network/traefik && docker compose up -d

# 3. Testar o caminho que o Collabora vai usar, antes de movê-lo (esperado: 200)
docker run --rm --network bergatrix-office curlimages/curl \
  -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://storange.<domínio>/status.php

# 4. Mover o Collabora (só ele)
cd ~/bergatrix/03-apps/nextcloud && docker compose up -d collabora
```

Conferir: `docker inspect nextcloud-collabora --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'` deve listar só `bergatrix-office`. Depois, abrir e salvar um documento.

Se o passo 3 não responder 200, o Traefik não está aceitando a conexão interna. Como alternativa, tire o `internal: true` da `bergatrix-office` e o alias: o Collabora continua isolado dos outros containers e chega ao Nextcloud pelo caminho público.