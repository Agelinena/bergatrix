#!/bin/sh
# Laço do buscador: uma rodada a cada PRICEBUDDY_BUSCA_INTERVALO segundos.
# O depends_on espera o app ficar saudável (migrações feitas) antes de começar.
cd /app || exit 1
while true; do
  php artisan baratinho:buscar || echo "buscador: rodada terminou com erro"
  sleep "${PRICEBUDDY_BUSCA_INTERVALO:-600}"
done
