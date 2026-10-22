#!/usr/bin/env bash
# Sobe a Bergatrix inteira na ordem certa: primeiro as redes, depois cada
# stack do stacks.txt. Pode rodar de novo a qualquer momento: o que já está no
# ar e sem mudança fica como está.
#
# Uso: ./00-infrastructure/subir-tudo.sh
# Guia: docs/07-ligar-e-desligar.md
set -uo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
mapfile -t STACKS < <(grep -vE '^[[:space:]]*(#|$)' "$RAIZ/00-infrastructure/stacks.txt")

echo "==> Redes (01-network/redes)"
if ! (cd "$RAIZ/01-network/redes" && docker compose run --rm redes); then
  echo "Falhou ao criar as redes. Nada mais foi feito." >&2
  exit 1
fi

falhas=()
for stack in "${STACKS[@]}"; do
  pasta="$RAIZ/$stack"
  if [ ! -f "$pasta/docker-compose.yml" ]; then
    echo "!!  $stack: pasta ou docker-compose.yml não existe"
    falhas+=("$stack")
    continue
  fi
  if [ ! -f "$pasta/.env" ]; then
    echo "--  $stack: sem .env, pulando (não configurada neste servidor)"
    continue
  fi
  echo "==> $stack"
  (cd "$pasta" && docker compose up -d) || falhas+=("$stack")
done

# Containers no ar que não pertencem a nenhuma stack da lista: ou a stack
# falta no stacks.txt, ou é sobra de uma stack removida.
projetos=" redes "
for stack in "${STACKS[@]}"; do projetos+="$(basename "$stack") "; done
fora=$(docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}' |
  while read -r nome projeto; do
    [[ "$projetos" == *" ${projeto:--} "* ]] || echo "    $nome (projeto: ${projeto:-nenhum})"
  done)
if [ -n "$fora" ]; then
  echo
  echo "Containers no ar fora do stacks.txt:"
  echo "$fora"
fi

echo
if [ ${#falhas[@]} -gt 0 ]; then
  echo "Terminou com falha em: ${falhas[*]}"
  exit 1
fi
echo "Tudo no ar."
