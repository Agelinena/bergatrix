# Migrações no servidor

Mudanças que precisam de passo manual **uma vez** no servidor (mover pasta, ordem de containers, rede nova). O `atualizar.sh` não faz isso sozinho: aplique a migração antes de rodá-lo. Cada uma diz como conferir se já foi aplicada.

Depois de aplicada e conferida, a migração pode sair deste arquivo (fica no histórico do git).

## Ajustes dos apps em `03-apps/submodulos` (nov/2026)

**Conferir se já foi aplicada:** `grep COMPOSE_FILE ~/bergatrix/03-apps/*/.env` mostra `../submodulos/<app>.bergatrix.yml` em todos.

Os arquivos `<app>.bergatrix.yml` saíram da raiz de `03-apps` e foram para `03-apps/submodulos/`. As pastas dos apps não mudaram. Só a linha `COMPOSE_FILE` do `.env` de cada app precisa acompanhar; os containers não são recriados.

Rode `git pull` (não o `atualizar.sh`, que tentaria recriar os apps com o caminho antigo) e logo depois:

```bash
cd ~/bergatrix
for a in bergastream berganews doberga transcriptor drop legendarr; do
  f=03-apps/$a/.env
  [ -f "$f" ] || continue
  sed -i "s#^COMPOSE_FILE=docker-compose.yml:../$a.bergatrix.yml#COMPOSE_FILE=docker-compose.yml:../submodulos/$a.bergatrix.yml#" "$f"
  (cd 03-apps/$a && docker compose config --quiet && echo "$a: ok")
done
```

Cada app instalado deve responder `ok`. Se algum der erro de arquivo não encontrado, a linha `COMPOSE_FILE` dele está diferente: corrija à mão.

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