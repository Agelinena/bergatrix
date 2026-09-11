#!/bin/sh
set -eu

mkdir -p /tmp/traefik-dynamic

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\\\&/g'
}

dashboard_host=$(escape_sed_replacement "${SUBDOMAIN_TRAEFIK_DASHBOARD:-}")
traefik_user=$(escape_sed_replacement "${TRAEFIK_USER:-}")
traefik_password=$(escape_sed_replacement "${TRAEFIK_PASSWORD:-}")
crowdsec_key=$(escape_sed_replacement "${CROWDSEC_BOUNCER_KEY:-}")

sed \
  -e "s|\${SUBDOMAIN_TRAEFIK_DASHBOARD}|${dashboard_host}|g" \
  -e "s|\${TRAEFIK_USER}|${traefik_user}|g" \
  -e "s|\${TRAEFIK_PASSWORD}|${traefik_password}|g" \
  /config-source/config.yml > /tmp/traefik-dynamic/config.yml

sed \
  -e "s|\${CROWDSEC_BOUNCER_KEY}|${crowdsec_key}|g" \
  /config-source/dynamic.yml > /tmp/traefik-dynamic/dynamic.yml

exec traefik --configFile=/traefik.yml
