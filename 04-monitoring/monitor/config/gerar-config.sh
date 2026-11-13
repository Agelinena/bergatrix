#!/bin/sh
# Roda no serviço "config" a cada subida da stack. Gera os arquivos que precisam
# de valores do .env e grava em /gerado (${CACHE_PATH}/monitor/gerado).
set -eu

: "${DOMAIN:?DOMAIN vazio no .env}"
: "${PVE_TOKEN_VALUE:?PVE_TOKEN_VALUE vazio no .env (README, passo do Proxmox)}"

# Sites testados pelo blackbox: o modelo usa example.com
sed "s/example\.com/${DOMAIN}/g" /modelos/sites.yml > /gerado/sites.yml.tmp
mv /gerado/sites.yml.tmp /gerado/sites.yml

# Token do pve-exporter (só leitura, papel PVEAuditor)
umask 077
cat > /gerado/pve.yml.tmp <<EOF
default:
  user: ${PVE_USER}
  token_name: ${PVE_TOKEN_NAME}
  token_value: ${PVE_TOKEN_VALUE}
  # Certificado autoassinado do Proxmox, conexão só na rede local
  verify_ssl: false
EOF
chmod 644 /gerado/pve.yml.tmp
mv /gerado/pve.yml.tmp /gerado/pve.yml

echo "config: sites.yml e pve.yml gerados"
