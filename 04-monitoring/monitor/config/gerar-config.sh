#!/bin/sh
# Roda no serviço "config" a cada subida da stack. Gera os arquivos que precisam
# de valores do .env e grava em /gerado (${CACHE_PATH}/monitor/gerado).
set -eu

if [ -z "${DOMAIN:-}" ]; then
  echo "config: DOMAIN vazio no .env" >&2
  exit 1
fi

if ! touch /gerado/.teste 2>/dev/null; then
  echo "config: sem permissão para gravar em \${CACHE_PATH}/monitor/gerado (usuário $(id -u):$(id -g))." >&2
  echo "config: no servidor, rode: sudo chown -R ${PUID:-1000}:${PGID:-1000} /srv/cache/monitor /srv/appdata/monitor" >&2
  exit 1
fi
rm -f /gerado/.teste

# Sites testados pelo blackbox: o modelo usa example.com
sed "s/example\.com/${DOMAIN}/g" /modelos/sites.yml > /gerado/sites.yml.tmp
mv /gerado/sites.yml.tmp /gerado/sites.yml

# Token do pve-exporter (só leitura, papel PVEAuditor). Sem ele a stack sobe
# do mesmo jeito; só o Proxmox fica sem dados até o token entrar no .env.
if [ -z "${PVE_TOKEN_VALUE:-}" ]; then
  echo "config: AVISO: PVE_TOKEN_VALUE vazio; o Proxmox fica sem dados (README, passo 2)." >&2
fi
cat > /gerado/pve.yml.tmp <<EOF
default:
  user: ${PVE_USER}
  token_name: ${PVE_TOKEN_NAME}
  token_value: "${PVE_TOKEN_VALUE:-}"
  # Certificado autoassinado do Proxmox, conexão só na rede local
  verify_ssl: false
EOF
chmod 644 /gerado/pve.yml.tmp
mv /gerado/pve.yml.tmp /gerado/pve.yml

echo "config: sites.yml e pve.yml gerados"
