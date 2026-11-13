#!/bin/bash
# Instala o node_exporter na VM do OpenMediaVault (Debian). Rode como root:
#
#   ./instalar.sh
#
# Dá uso do HD de 4 TB, NFS servido, CPU, memória e rede da VM. O SMART do HD
# é lido no Proxmox (hosts/proxmox), que enxerga o disco físico.
set -euo pipefail

# Lê uma URL com o que houver na máquina (o OMV não vem com curl)
baixar() {
  if command -v curl >/dev/null; then curl -s "$1"
  elif command -v wget >/dev/null; then wget -qO- "$1"
  else echo "(sem curl nem wget aqui: confira do bergaserver)" >&2
  fi
}

[ "$(id -u)" = 0 ] || { echo "Rode como root."; exit 1; }

apt-get update -q
apt-get install -y -q --no-install-recommends prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

sleep 2
baixar http://localhost:9100/metrics | grep -E '^node_filesystem_size_bytes' | head -5 || true
echo "Feito."
