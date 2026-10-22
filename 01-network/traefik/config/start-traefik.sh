#!/bin/sh
set -eu

# Os arquivos de config do Traefik não expandem variáveis de ambiente. Este
# script gera cópias com os valores do .env antes de iniciar o Traefik.
: "${DOMAIN:?defina DOMAIN no .env}"

mkdir -p /tmp/traefik-dynamic

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\\\&/g'
}

domain=$(escape_sed_replacement "${DOMAIN}")
traefik_user=$(escape_sed_replacement "${TRAEFIK_USER:-}")
traefik_password=$(escape_sed_replacement "${TRAEFIK_PASSWORD:-}")
crowdsec_key=$(escape_sed_replacement "${CROWDSEC_BOUNCER_KEY:-}")

sed \
  -e "s|\${DOMAIN}|${domain}|g" \
  /config-source/traefik.yml > /tmp/traefik.yml

sed \
  -e "s|\${DOMAIN}|${domain}|g" \
  -e "s|\${TRAEFIK_USER}|${traefik_user}|g" \
  -e "s|\${TRAEFIK_PASSWORD}|${traefik_password}|g" \
  /config-source/config.yml > /tmp/traefik-dynamic/config.yml

sed \
  -e "s|\${CROWDSEC_BOUNCER_KEY}|${crowdsec_key}|g" \
  /config-source/dynamic.yml > /tmp/traefik-dynamic/dynamic.yml

exec traefik --configFile=/tmp/traefik.yml
