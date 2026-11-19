#!/usr/bin/env bash
# Atualiza o servidor a partir do GitHub: puxa o Bergatrix e os submódulos
# (apps com repositório próprio) e recria só as stacks que mudaram.
#
# Uso: ./00-infrastructure/atualizar.sh            (só o que mudou)
#      ./00-infrastructure/atualizar.sh --ver      (mostra o que faria, sem mexer)
#      ./00-infrastructure/atualizar.sh --tudo     (pull + up em todas as stacks)
#      ./00-infrastructure/atualizar.sh 03-apps/x  (só essas stacks, mudadas ou não)
# Guia: docs/07-ligar-e-desligar.md
#
# Uma stack "mudou" quando o commit novo mexe na pasta dela, no ponteiro do
# submódulo ou no ajuste do servidor (03-apps/<stack>.bergatrix.yml). As
# versões das imagens são fixas nos composes: imagem nova chega por commit
# (PR do Dependabot), nunca sozinha.
set -uo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
cd "$RAIZ"
mapfile -t STACKS < <(grep -vE '^[[:space:]]*(#|$)' 00-infrastructure/stacks.txt)

modo=mudou
escolhidas=()
for arg in "$@"; do
  case "$arg" in
    --ver) modo=ver ;;
    --tudo) modo=tudo ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) escolhidas+=("${arg%/}") ;;
  esac
done

antes=$(git rev-parse HEAD)
if [ "$modo" = ver ]; then
  git fetch --quiet || { echo "Falhou o git fetch." >&2; exit 1; }
  depois=$(git rev-parse '@{u}')
else
  if ! git pull --ff-only --quiet; then
    echo "Falhou o git pull (mudança local no servidor?). Nada foi recriado." >&2
    exit 1
  fi
  git submodule sync --quiet
  if ! git submodule update --init --quiet; then
    echo "Falhou ao baixar os submódulos. Nada foi recriado." >&2
    exit 1
  fi
  depois=$(git rev-parse HEAD)
fi

mudados=$(git diff --name-only "$antes" "$depois")
if [ "$antes" != "$depois" ]; then
  echo "==> Commits novos:"
  git log --oneline "$antes..$depois" | sed 's/^/    /'
fi

# Quais stacks recriar
alvo=()
if [ ${#escolhidas[@]} -gt 0 ]; then
  alvo=("${escolhidas[@]}")
else
  for stack in "${STACKS[@]}"; do
    if [ "$modo" = tudo ] || grep -qE "^($stack(/|$)|$stack\.bergatrix\.yml$)" <<<"$mudados"; then
      alvo+=("$stack")
    fi
  done
fi
redes=false
grep -q '^01-network/redes/' <<<"$mudados" && redes=true

if [ ${#alvo[@]} -eq 0 ] && [ "$redes" = false ]; then
  echo "Nenhuma stack mudou."
  exit 0
fi

if [ "$modo" = ver ]; then
  [ "$redes" = true ] && echo "Recriaria as redes (01-network/redes)."
  echo "Recriaria: ${alvo[*]:-nada}"
  exit 0
fi

if [ "$redes" = true ]; then
  echo "==> Redes (01-network/redes)"
  (cd 01-network/redes && docker compose run --rm redes) || {
    echo "Falhou ao criar as redes. Nenhuma stack foi recriada." >&2
    exit 1
  }
fi

falhas=()
feitas=()
for stack in "${alvo[@]}"; do
  if [ ! -f "$stack/docker-compose.yml" ]; then
    echo "!!  $stack: pasta ou docker-compose.yml não existe"
    falhas+=("$stack")
    continue
  fi
  if [ ! -f "$stack/.env" ]; then
    echo "--  $stack: sem .env, pulando (não configurada neste servidor)"
    continue
  fi
  echo "==> $stack"
  if (cd "$stack" &&
      docker compose pull --ignore-buildable --quiet &&
      docker compose up -d --build); then
    feitas+=("$stack")
  else
    falhas+=("$stack")
  fi
done

# Só as imagens sem nome (as versões antigas que acabaram de ser trocadas).
docker image prune -f >/dev/null

echo
[ ${#feitas[@]} -gt 0 ] && echo "Recriadas: ${feitas[*]}"
if [ ${#falhas[@]} -gt 0 ]; then
  echo "Falhou em: ${falhas[*]}"
  exit 1
fi
echo "Pronto."
