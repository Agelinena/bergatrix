#!/bin/sh
# Roda no serviço "geoip" a cada subida da stack. Baixa as bases gratuitas da
# DB-IP (país/cidade e operadora/ASN; formato MaxMind, licença CC BY 4.0) para
# ${CACHE_PATH}/monitor/geoip, que o Alloy usa no access.log do Traefik.
# Só baixa de novo quando a base tem mais de 32 dias (a DB-IP publica uma por mês).
set -eu

cd /geoip

baixar() {
  tipo=$1
  destino="dbip-$tipo-lite.mmdb"

  if [ -s "$destino" ] && [ -n "$(find "$destino" -mtime -32)" ]; then
    echo "geoip: $destino em dia"
    return 0
  fi

  # A do mês atual pode ainda não ter saído nos primeiros dias: tenta a anterior
  for mes in "$(date +%Y-%m)" "$(date -d "@$(( $(date +%s) - 20 * 86400 ))" +%Y-%m)"; do
    url="https://download.db-ip.com/free/dbip-$tipo-lite-$mes.mmdb.gz"
    if wget -q -T 60 -O "$destino.gz.tmp" "$url" && gunzip -c "$destino.gz.tmp" > "$destino.tmp" && [ -s "$destino.tmp" ]; then
      mv "$destino.tmp" "$destino"
      rm -f "$destino.gz.tmp"
      echo "geoip: $destino atualizada ($mes)"
      return 0
    fi
    rm -f "$destino.gz.tmp" "$destino.tmp"
  done

  if [ -s "$destino" ]; then
    echo "geoip: AVISO: não consegui atualizar $destino; sigo com a antiga" >&2
    return 0
  fi
  echo "geoip: ERRO: não consegui baixar $destino e não há cópia antiga." >&2
  echo "geoip: sem ela o Alloy não sobe. Confira a internet do servidor e rode de novo." >&2
  return 1
}

baixar city
baixar asn
