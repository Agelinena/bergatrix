#!/usr/bin/env bash
# Migra o servidor para os apps em repositório próprio (submódulos), uma vez.
# Ver docs/migracoes.md ("Apps em repositório próprio").
#
# Rode ANTES do git pull (o script faz o pull no momento certo). Como ele
# ainda não existe no servidor, pegue direto do GitHub:
#
#   cd ~/bergatrix && git fetch
#   git show origin/main:00-infrastructure/migrar-submodulos.sh > /tmp/migrar.sh
#   bash /tmp/migrar.sh
#
# O que faz:
#   1. Confere tudo antes de mexer: repositório sem mudança local, pull
#      possível, acesso aos repositórios dos apps (privados: precisa de
#      `gh auth login` + `gh auth setup-git`).
#   2. Guarda os .env fora das pastas, para as stacks que vão subir de novo,
#      troca as pastas pelos submódulos e devolve os .env com o COMPOSE_FILE.
#   3. Bergastream, Berganews e Doberga: sobem de novo.
#      Transcriptor e Drop: só a troca de pasta. As versões novas pedem um
#      .env novo (README de cada um); os containers antigos seguem no ar.
#   4. Legendarr: sai da stack do Jellyfin para 03-apps/legendarr, com as
#      pastas renomeadas, e sobe.
# Os dados (APPDATA, CACHE, MEDIA, USERDATA) ficam fora das pastas.
set -euo pipefail
RAIZ=$(git rev-parse --show-toplevel)
cd "$RAIZ"

SOBEM=(03-apps/bergastream 03-apps/berganews 03-apps/doberga)
SO_PASTA=(03-apps/transcriptor 03-apps/drop)
APPS=("${SOBEM[@]}" "${SO_PASTA[@]}")
BACKUP="$HOME/.bergatrix-migracao-env"

echo "== 1. Conferindo antes de mexer"
git fetch --quiet
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "!! O main local tem commits que o GitHub não tem. Nada foi alterado." >&2; exit 1
fi
mudancas=$(git status --porcelain --untracked-files=no)
if [ -n "$mudancas" ]; then
  echo "!! Mudança local em arquivo rastreado (resolva antes; nada foi alterado):" >&2
  echo "$mudancas" >&2; exit 1
fi
modulos=$(mktemp)
git show origin/main:.gitmodules > "$modulos"
for app in "${APPS[@]}" 03-apps/legendarr; do
  url=$(git config -f "$modulos" "submodule.$app.url")
  if ! git ls-remote --quiet "$url" HEAD >/dev/null 2>&1; then
    echo "!! Sem acesso a $url (repositório privado? gh auth login && gh auth setup-git). Nada foi alterado." >&2; exit 1
  fi
done
rm -f "$modulos"
for app in "${APPS[@]}"; do
  if [ -d "$app/data" ]; then
    echo "!! $app/data existe: mova os dados para fora (APPDATA_PATH) antes. Nada foi alterado." >&2; exit 1
  fi
done
echo "   ok"

echo "== 2. Guardando os .env em $BACKUP"
mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
for app in "${APPS[@]}" 03-apps/jellyfin; do
  name=$(basename "$app")
  if [ -f "$app/.env" ]; then
    cp -p "$app/.env" "$BACKUP/$name.env"
    echo "   $app/.env"
  fi
done

echo "== 3. Parando as stacks que vão subir de novo"
for app in "${SOBEM[@]}"; do
  if [ -f "$app/docker-compose.yml" ] && [ -f "$app/.env" ]; then
    (cd "$app" && docker compose down) || true
  fi
done

echo "== 4. Trocando as pastas pelos submódulos"
for app in "${APPS[@]}"; do
  rm -rf "$app"
done
git pull --ff-only --quiet
git submodule update --init
git config submodule.recurse true

for app in "${APPS[@]}"; do
  name=$(basename "$app")
  [ -f "$BACKUP/$name.env" ] || continue
  cp -p "$BACKUP/$name.env" "$app/.env"
  if ! grep -q '^COMPOSE_FILE=' "$app/.env"; then
    printf '\n# Compose do app + ajuste deste servidor (Bergatrix)\nCOMPOSE_FILE=docker-compose.yml:../%s.bergatrix.yml\n' "$name" >> "$app/.env"
  fi
  echo "   $app: .env de volta, com o COMPOSE_FILE"
done

echo "== 5. Subindo Bergastream, Berganews e Doberga"
falhas=()
for app in "${SOBEM[@]}"; do
  [ -f "$app/.env" ] || { echo "   $app: sem .env, pulando"; continue; }
  echo "-- $app"
  (cd "$app" && docker compose config --quiet && docker compose up -d --build) || falhas+=("$app")
done

echo "== 6. Legendarr: da stack do Jellyfin para 03-apps/legendarr"
if [ -f "$BACKUP/jellyfin.env" ] && [ ! -f 03-apps/legendarr/.env ]; then
  ler() { grep -E "^$1=" "$BACKUP/jellyfin.env" | tail -n1 | cut -d= -f2- | tr -d "\"'"; }
  APPDATA=$(ler APPDATA_PATH); CACHE=$(ler CACHE_PATH)
  # Os três containers antigos saem do projeto jellyfin.
  (cd 03-apps/jellyfin && docker compose up -d --remove-orphans)
  if [ -d "$APPDATA/jellyfin/legendarr" ] && [ ! -e "$APPDATA/legendarr" ]; then
    sudo mv "$APPDATA/jellyfin/legendarr" "$APPDATA/legendarr"
  fi
  if [ -d "$CACHE/jellyfin/optimizer" ] && [ ! -e "$CACHE/legendarr/optimizer" ]; then
    sudo mkdir -p "$CACHE/legendarr"
    sudo mv "$CACHE/jellyfin/optimizer" "$CACHE/legendarr/optimizer"
  fi
  # O .env do Jellyfin já tem todas as variáveis do Legendarr.
  cp -p "$BACKUP/jellyfin.env" 03-apps/legendarr/.env
  printf '\n# Compose do app + ajuste deste servidor (Bergatrix)\nCOMPOSE_FILE=docker-compose.yml:../legendarr.bergatrix.yml\n' >> 03-apps/legendarr/.env
  (cd 03-apps/legendarr && docker compose config --quiet && docker compose up -d --build) || falhas+=(03-apps/legendarr)
else
  echo "   pulando (sem .env do Jellyfin, ou o Legendarr já tem .env)"
fi

echo
for app in "${SO_PASTA[@]}"; do
  if [ -f "$app/.env" ]; then
    echo "Falta: $app está na versão nova, mas não subiu. Siga o README dele e depois: cd $app && docker compose up -d --build"
  fi
done
if [ ${#falhas[@]} -gt 0 ]; then
  echo "Falhou em: ${falhas[*]} (os .env originais estão em $BACKUP)"
  exit 1
fi
echo "Pronto. Confira os apps no navegador e apague $BACKUP depois."
