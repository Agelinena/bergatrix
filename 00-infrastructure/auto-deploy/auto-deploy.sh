#!/usr/bin/env bash
# Atualiza sozinho um app de imagem pronta (ex.: Tarantec): puxa a imagem do
# registro e recria o container só se ela mudou. Roda pelo timer
# bergatrix-auto-deploy@<app>.timer, a cada 5 minutos. Guia: README.md desta pasta.
#
# Uso: ./00-infrastructure/auto-deploy/auto-deploy.sh <app>   (pasta 03-apps/<app>)
#
# Só para apps cujo compose usa image: (sem build:) e que pediram isso no
# repositório deles. Os outros seguem o caminho normal: Dependabot + atualizar.sh.
set -euo pipefail

app="${1:?uso: auto-deploy.sh <app>}"
case "$app" in
  *[!a-z0-9-]*) echo "nome de app inválido: $app" >&2; exit 2 ;;
esac

RAIZ=$(cd "$(dirname "$0")/../.." && pwd)
pasta="$RAIZ/03-apps/$app"
cd "$pasta"
[ -f .env ] || { echo "$app: sem .env, nada a fazer (não configurado neste servidor)"; exit 0; }

antes=$(docker compose images --quiet 2>/dev/null | sort | tr '\n' ' ')
docker compose pull --quiet
# up só recria o que mudou (imagem ou configuração).
docker compose up -d --remove-orphans --quiet-pull
depois=$(docker compose images --quiet | sort | tr '\n' ' ')

if [ "$antes" != "$depois" ]; then
  echo "$app: imagem nova no ar ($depois)"
  docker image prune -f >/dev/null
fi
