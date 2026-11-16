#!/bin/bash
# Instala o monitoramento no host Proxmox. Rode como root, nesta pasta:
#
#   ./instalar.sh
#
#   1. node_exporter (CPU, memória, discos, rede, temperaturas do host)
#   2. SMART dos discos físicos (smartmon, a cada 15 min, pelo textfile collector)
#   3. Usuário monitor@pve só leitura (PVEAuditor) e um token para o pve-exporter.
#      O segredo do token aparece UMA vez no fim: copie para PVE_TOKEN_VALUE no
#      .env da stack monitor.
set -euo pipefail

# Lê uma URL com o que houver na máquina (o OMV não vem com curl)
baixar() {
  if command -v curl >/dev/null; then curl -s "$1"
  elif command -v wget >/dev/null; then wget -qO- "$1"
  else echo "(sem curl nem wget aqui: confira do bergaserver)" >&2
  fi
}

[ "$(id -u)" = 0 ] || { echo "Rode como root."; exit 1; }

echo "== Pacotes"
apt-get update -q
apt-get install -y -q prometheus-node-exporter prometheus-node-exporter-collectors smartmontools nvme-cli

echo "== SMART e NVMe a cada 15 min"
# O pacote de coletores traz os timers; liga os que existirem
for t in prometheus-node-exporter-smartmon.timer prometheus-node-exporter-nvme.timer; do
  if systemctl list-unit-files "$t" >/dev/null 2>&1; then
    systemctl enable --now "$t"
  fi
done

echo "== Autotestes SMART (smartd)"
# Curto toda madrugada às 02h; longo todo dia 1º às 03h (num HD de 4 TB leva
# horas, mas roda em segundo plano). O resultado aparece na saúde SMART.
if [ -f /etc/smartd.conf ] && ! grep -q "bergatrix" /etc/smartd.conf; then
  cp /etc/smartd.conf /etc/smartd.conf.antes-bergatrix
  sed -i "s/^DEVICESCAN/#DEVICESCAN/" /etc/smartd.conf
  cat >> /etc/smartd.conf <<'EOF'
# bergatrix: monitora todos os discos e agenda os autotestes
DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././02|L/../01/./03)
EOF
  systemctl restart smartd 2>/dev/null || systemctl restart smartmontools
fi

systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

echo "== Usuário e token do pve-exporter"
if ! pveum user list --output-format json | grep -q '"userid":"monitor@pve"'; then
  pveum user add monitor@pve --comment "Bergatrix monitor (só leitura)"
fi
pveum acl modify / --users monitor@pve --roles PVEAuditor
if pveum user token list monitor@pve --output-format json | grep -q '"tokenid":"prometheus"'; then
  echo "O token monitor@pve!prometheus já existe. Para gerar outro segredo:"
  echo "  pveum user token remove monitor@pve prometheus && ./instalar.sh"
else
  # --privsep 0: o token herda as permissões do usuário (PVEAuditor)
  pveum user token add monitor@pve prometheus --privsep 0 --comment "pve-exporter"
  echo
  echo ">>> Copie o 'value' acima para PVE_TOKEN_VALUE no .env da stack monitor."
fi

echo
echo "== Conferir"
sleep 2
baixar http://localhost:9100/metrics | grep -E '^(node_hwmon_temp_celsius|smartmon_device_smart_healthy)' | head -5 || true
echo "(smartmon aparece depois da primeira rodada do timer, em até 15 min)"
