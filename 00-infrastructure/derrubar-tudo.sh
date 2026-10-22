#!/usr/bin/env bash
# Derruba todas as stacks do stacks.txt, na ordem inversa da subida.
# Só para e remove os containers: dados, imagens e redes ficam.
#
# Uso: ./00-infrastructure/derrubar-tudo.sh      (pede confirmação)
#      ./00-infrastructure/derrubar-tudo.sh -y   (sem perguntar)
# Guia: docs/07-ligar-e-desligar.md
set -uo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
mapfile -t STACKS < <(grep -vE '^[[:space:]]*(#|$)' "$RAIZ/00-infrastructure/stacks.txt")

if [ "${1:-}" != "-y" ]; then
  read -r -p "Derrubar todas as stacks da Bergatrix? [s/N] " resposta
  [[ "$resposta" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

falhas=()
for ((i = ${#STACKS[@]} - 1; i >= 0; i--)); do
  stack="${STACKS[i]}"
  projeto=$(basename "$stack")
  echo "==> $stack"
  # Pelo nome do projeto, fora da pasta: não depende do .env nem do compose
  # estar igual ao que subiu.
  (cd / && docker compose -p "$projeto" down) || falhas+=("$stack")
done

restantes=$(docker ps --format '{{.Names}} (projeto: {{.Label "com.docker.compose.project"}})' | sed 's/^/    /')
if [ -n "$restantes" ]; then
  echo
  echo "Ainda no ar (fora do stacks.txt):"
  echo "$restantes"
fi

echo
if [ ${#falhas[@]} -gt 0 ]; then
  echo "Terminou com falha em: ${falhas[*]}"
  exit 1
fi
echo "Tudo derrubado. As redes continuam criadas."
