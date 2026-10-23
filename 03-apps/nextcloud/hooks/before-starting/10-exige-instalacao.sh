#!/bin/sh
# Roda a cada start do app, antes do Apache (hook before-starting da imagem).
#
# A imagem copia o version.php antes de instalar. Se a instalação automática
# falhar (senha do admin vazia, pasta de dados sem permissão, banco fora), o
# container reinicia achando que está instalado e abre o instalador web na
# internet, para quem chegar primeiro. Este script impede o Apache de subir
# nesse estado: um hook que falha derruba o container.
set -eu

if php /var/www/html/occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
  exit 0
fi

echo "ERRO: o Nextcloud não está instalado; o Apache não vai subir." >&2
echo "Veja o começo do log (docker compose logs app) e o README da stack." >&2
exit 1
