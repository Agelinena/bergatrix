#!/usr/bin/env bash
# Migra o servidor para os apps em repositório próprio (submódulos), uma vez.
# Ver docs/03-padrao-stacks.md ("Apps com repositório próprio").
#
#   cd ~/bergatrix && ./00-infrastructure/migrar-submodulos.sh
#
# Para cada app: guarda o .env fora da pasta, puxa o Bergatrix, baixa o
# submódulo, devolve o .env, acrescenta o COMPOSE_FILE (compose do app + o
# ajuste deste servidor) e sobe a stack de novo. Os dados (APPDATA, CACHE,
# MEDIA) ficam fora das pastas e não são tocados.
#
# Repositórios ainda privados: o servidor precisa de acesso ao GitHub (ex.:
# `gh auth login` + `gh auth setup-git`, ou um token no credential helper).
set -euo pipefail
cd "$(dirname "$0")/.."

APPS=(03-apps/bergastream 03-apps/berganews 03-apps/doberga 03-apps/transcriptor)
BACKUP="$HOME/.bergatrix-migracao-env"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"

echo "== Conferindo que nenhum dado mora dentro das pastas dos apps"
for app in "${APPS[@]}"; do
  if [ -d "$app/data" ]; then
    echo "!! $app/data existe: mova os dados para fora (APPDATA_PATH) antes. Nada foi alterado."
    exit 1
  fi
done

echo "== Guardando os .env"
for app in "${APPS[@]}"; do
  name=$(basename "$app")
  if [ -f "$app/.env" ]; then
    cp -p "$app/.env" "$BACKUP/$name.env"
    echo "   $app/.env -> $BACKUP/$name.env"
  else
    echo "   $app: sem .env (stack não instalada aqui?)"
  fi
done

echo "== Parando as stacks (os dados ficam onde estão)"
for app in "${APPS[@]}"; do
  if [ -f "$app/docker-compose.yml" ] && [ -f "$app/.env" ]; then
    (cd "$app" && docker compose down) || true
  fi
done

echo "== Tirando as pastas antigas (código antigo; o .env já está guardado)"
for app in "${APPS[@]}"; do
  rm -rf "$app"
done

echo "== Atualizando o Bergatrix e os submódulos"
git pull --ff-only
git submodule update --init
git config submodule.recurse true

echo "== Devolvendo os .env e ligando o ajuste do servidor"
for app in "${APPS[@]}"; do
  name=$(basename "$app")
  [ -f "$BACKUP/$name.env" ] || continue
  cp -p "$BACKUP/$name.env" "$app/.env"
  line="COMPOSE_FILE=docker-compose.yml:../$name.bergatrix.yml"
  if ! grep -q '^COMPOSE_FILE=' "$app/.env"; then
    printf '\n# Compose do app + ajuste deste servidor (Bergatrix)\n%s\n' "$line" >> "$app/.env"
  fi
  echo "   $app: .env de volta, $line"
done

echo "== Conferindo a configuração (sem subir nada ainda)"
for app in "${APPS[@]}"; do
  [ -f "$app/.env" ] || continue
  (cd "$app" && docker compose config --quiet) && echo "   $app: ok"
done

echo "== Subindo"
for app in "${APPS[@]}"; do
  [ -f "$app/.env" ] || continue
  echo "-- $app"
  (cd "$app" && docker compose up -d --build)
done

echo
echo "Pronto. Confira os apps no navegador. Cópia dos .env em $BACKUP (apague depois de conferir)."
