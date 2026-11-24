#!/bin/sh
# Container do buscador:
#   - filtro da pesquisa do app (filtro.php) em http://buscador:8081/search,
#     reiniciado se cair;
#   - laço do buscador: uma rodada a cada PRICEBUDDY_BUSCA_INTERVALO segundos,
#     e o resumo por e-mail quando fizer uma semana do último.
# O depends_on espera o app ficar saudável (migrações feitas) antes de começar.
cd /app || exit 1

(
  while true; do
    # Sem as linhas de acesso (levariam o que cada pessoa pesquisa para o log):
    # ficam os erros.
    PHP_CLI_SERVER_WORKERS=4 php -S 0.0.0.0:8081 /buscador/filtro.php 2>&1 \
      | grep --line-buffered -v -E 'Accepted$|Closing$|\[[0-9]{3}\]: [A-Z]+ /'
    echo "filtro: parou, reiniciando"
    sleep 2
  done
) &

while true; do
  php artisan baratinho:buscar || echo "buscador: rodada terminou com erro"
  php artisan baratinho:resumo --se-for-hora || echo "buscador: resumo terminou com erro"
  sleep "${PRICEBUDDY_BUSCA_INTERVALO:-600}"
done
