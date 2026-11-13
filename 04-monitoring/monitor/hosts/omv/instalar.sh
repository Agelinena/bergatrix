#!/bin/bash
# Instala o node_exporter na VM do OpenMediaVault (Debian). Rode como root:
#
#   ./instalar.sh
#
# Dá uso do HD de 4 TB, NFS servido, CPU, memória e rede da VM. O SMART do HD
# é lido no Proxmox (hosts/proxmox), que enxerga o disco físico.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Rode como root."; exit 1; }

apt-get update -q
apt-get install -y -q --no-install-recommends prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

sleep 2
curl -s http://localhost:9100/metrics | grep -E '^node_filesystem_size_bytes' | head -5
echo "Feito."
