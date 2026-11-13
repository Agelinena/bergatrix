#!/bin/bash
# Métricas da VPS que o node_exporter não tem: túnel WireGuard, contadores do
# nftables e fila CAKE. Grava no formato do Prometheus na pasta do textfile
# collector; o node_exporter publica junto com as outras métricas.
# Roda como root pelo timer bergatrix-metricas.timer (a cada 15 s).
set -euo pipefail

PASTA=${PASTA:-/var/lib/prometheus/node-exporter}
# Interfaces com CAKE (a de saída e, se houver, a ifb de entrada)
IFACES_CAKE=${IFACES_CAKE:-"eth0 ifb4eth0"}

tmp=$(mktemp "$PASTA/.vps.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
  # ── WireGuard ─────────────────────────────────────────────────
  # wg show all dump, linhas de peer (9 campos):
  # interface chave-pública psk endpoint allowed-ips último-handshake rx tx keepalive
  echo "# HELP wireguard_latest_handshake_seconds Hora (unix) do último handshake com o peer"
  echo "# TYPE wireguard_latest_handshake_seconds gauge"
  echo "# HELP wireguard_received_bytes_total Bytes recebidos do peer"
  echo "# TYPE wireguard_received_bytes_total counter"
  echo "# HELP wireguard_sent_bytes_total Bytes enviados ao peer"
  echo "# TYPE wireguard_sent_bytes_total counter"
  wg show all dump | awk -F'\t' 'NF == 9 {
    l = sprintf("interface=\"%s\",allowed_ips=\"%s\"", $1, $5)
    printf "wireguard_latest_handshake_seconds{%s} %s\n", l, $6
    printf "wireguard_received_bytes_total{%s} %s\n", l, $7
    printf "wireguard_sent_bytes_total{%s} %s\n", l, $8
  }'

  # ── nftables ──────────────────────────────────────────────────
  # Toda regra com "counter". O nome da regra é o comentário dela; sem
  # comentário, o handle (muda quando o ruleset é recarregado).
  # Dica: nft add rule ... counter drop comment "geo-bloqueio"
  echo "# HELP nftables_rule_packets_total Pacotes que casaram com a regra"
  echo "# TYPE nftables_rule_packets_total counter"
  echo "# HELP nftables_rule_bytes_total Bytes que casaram com a regra"
  echo "# TYPE nftables_rule_bytes_total counter"
  nft -j list ruleset | jq -r '
    .nftables[] | select(.rule) | .rule as $r
    | (($r.expr // []) | map(select(type == "object" and has("counter"))) | first | .counter?) as $c
    | select(($c | type) == "object")
    | ((($r.expr // []) | map(select(type == "object" and (has("drop") or has("accept") or has("reject") or has("jump") or has("goto")))) | first) // {} | keys[0] // "continua") as $v
    | (($r.comment // ("handle " + ($r.handle | tostring))) | gsub("\""; "")) as $nome
    | "family=\"\($r.family)\",table=\"\($r.table)\",chain=\"\($r.chain)\",rule=\"\($nome)\",verdict=\"\($v)\"" as $l
    | "nftables_rule_packets_total{\($l)} \($c.packets)\nnftables_rule_bytes_total{\($l)} \($c.bytes)"'

  # ── CAKE (anti-bufferbloat) ───────────────────────────────────
  echo "# HELP qdisc_cake_sent_bytes_total Bytes enviados pela fila"
  echo "# TYPE qdisc_cake_sent_bytes_total counter"
  echo "# HELP qdisc_cake_drops_total Pacotes descartados pela fila"
  echo "# TYPE qdisc_cake_drops_total counter"
  echo "# HELP qdisc_cake_backlog_bytes Bytes esperando na fila"
  echo "# TYPE qdisc_cake_backlog_bytes gauge"
  echo "# HELP qdisc_cake_tin_avg_delay_seconds Atraso médio na fila, por tin"
  echo "# TYPE qdisc_cake_tin_avg_delay_seconds gauge"
  echo "# HELP qdisc_cake_tin_peak_delay_seconds Atraso de pico na fila, por tin"
  echo "# TYPE qdisc_cake_tin_peak_delay_seconds gauge"
  for dev in $IFACES_CAKE; do
    [ -e "/sys/class/net/$dev" ] || continue
    tc -s -j qdisc show dev "$dev" | jq -r --arg d "$dev" '
      .[] | select(.kind == "cake")
      | "qdisc_cake_sent_bytes_total{device=\"\($d)\"} \(.bytes)",
        "qdisc_cake_drops_total{device=\"\($d)\"} \(.drops)",
        "qdisc_cake_backlog_bytes{device=\"\($d)\"} \(.backlog)",
        (.tins // [] | to_entries[]
          | "qdisc_cake_tin_avg_delay_seconds{device=\"\($d)\",tin=\"\(.key)\"} \((.value.avg_delay_us // 0) / 1000000)",
            "qdisc_cake_tin_peak_delay_seconds{device=\"\($d)\",tin=\"\(.key)\"} \((.value.peak_delay_us // 0) / 1000000)")'
  done
} > "$tmp"

chmod 644 "$tmp"
mv "$tmp" "$PASTA/vps.prom"
trap - EXIT
