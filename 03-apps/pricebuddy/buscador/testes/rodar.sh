#!/usr/bin/env bash
# Roda os testes das regras do buscador na mesma imagem do app (não precisa da
# stack no ar). Use depois de mexer em buscador/Baratinho/.
#
#   ./buscador/testes/rodar.sh
set -euo pipefail
cd "$(dirname "$0")/.."
imagem=$(sed -n 's/^ *image: \(jez500\/pricebuddy:.*\)$/\1/p' ../docker-compose.yml | head -1)
docker run --rm --network none \
  -v "$PWD/Baratinho:/app/app/Baratinho:ro" \
  -v "$PWD/testes:/testes:ro" \
  --entrypoint php "$imagem" /testes/regras.php
