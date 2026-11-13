#!/bin/bash
# Instala o monitoramento na VPS (Debian/Ubuntu). Rode como root, nesta pasta:
#
#   SERVIDOR=<ip-do-servidor-pelo-túnel> ./instalar.sh
#
# SERVIDOR é o IP pelo qual a VPS chega ao bergaserver pelo túnel (o mesmo
# para onde o HAProxy manda o tráfego). O que faz:
#   1. node_exporter escutando só no IP do túnel (TUNEL_IP, padrão 10.100.0.1)
#   2. metricas-vps.sh a cada 15 s (WireGuard, nftables, CAKE)
#   3. rsyslog mandando os logs para o Alloy do servidor (porta 5141)
# O HAProxy e a regra do nftables são passos manuais (README da stack).
set -euo pipefail

: "${SERVIDOR:?Informe SERVIDOR=<ip-do-servidor-pelo-túnel>}"
TUNEL_IP=${TUNEL_IP:-10.100.0.1}
WG_IF=${WG_IF:-wg0}
AQUI=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = 0 ] || { echo "Rode como root."; exit 1; }

echo "== Pacotes"
apt-get update -q
apt-get install -y -q --no-install-recommends prometheus-node-exporter jq rsyslog

echo "== node_exporter só no IP do túnel ($TUNEL_IP)"
cat > /etc/default/prometheus-node-exporter <<EOF
# Gerado por bergatrix/04-monitoring/monitor/hosts/vps/instalar.sh
ARGS="--web.listen-address=${TUNEL_IP}:9100 --collector.textfile.directory=/var/lib/prometheus/node-exporter --collector.systemd"
EOF
mkdir -p /var/lib/prometheus/node-exporter
# Sobe depois do túnel (o IP só existe com ele no ar) e tenta de novo se cair
mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
cat > /etc/systemd/system/prometheus-node-exporter.service.d/bergatrix.conf <<EOF
[Unit]
After=wg-quick@${WG_IF}.service
Wants=wg-quick@${WG_IF}.service

[Service]
Restart=always
RestartSec=10
EOF

echo "== Métricas do túnel, nftables e CAKE"
install -D -m 755 "$AQUI/metricas-vps.sh" /usr/local/lib/bergatrix/metricas-vps.sh
cat > /etc/systemd/system/bergatrix-metricas.service <<'EOF'
[Unit]
Description=Bergatrix: métricas do WireGuard, nftables e CAKE para o node_exporter

[Service]
Type=oneshot
ExecStart=/usr/local/lib/bergatrix/metricas-vps.sh
EOF
cat > /etc/systemd/system/bergatrix-metricas.timer <<'EOF'
[Unit]
Description=Bergatrix: métricas da VPS a cada 15 s

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

echo "== Logs para o servidor ($SERVIDOR:5141)"
cat > /etc/rsyslog.d/90-bergatrix.conf <<EOF
# Gerado por bergatrix/04-monitoring/monitor/hosts/vps/instalar.sh
# Manda tudo para o Alloy do bergaserver (RFC 5424 por TCP). Se o túnel cair,
# guarda em disco (até 100 MB) e manda quando voltar.
*.* action(type="omfwd" target="${SERVIDOR}" port="5141" protocol="tcp"
           template="RSYSLOG_SyslogProtocol23Format" TCP_Framing="octet-counted"
           queue.type="LinkedList" queue.filename="bergatrix" queue.maxDiskSpace="100m"
           queue.saveOnShutdown="on" action.resumeRetryCount="-1")
EOF

systemctl daemon-reload
systemctl enable --now bergatrix-metricas.timer
systemctl restart prometheus-node-exporter rsyslog
/usr/local/lib/bergatrix/metricas-vps.sh

echo
echo "== Conferir"
sleep 2
curl -s "http://${TUNEL_IP}:9100/metrics" | grep -E '^(wireguard_latest|qdisc_cake_drops|nftables_rule_packets)' | head -5 || true
echo
echo "Feito. Falta (README): liberar 9100 e 8405 no nftables só pelo ${WG_IF},"
echo "e o frontend de métricas do HAProxy."
