#!/usr/bin/env bash
# Instala o timer de atualização automática de um ou mais apps.
# Uso (no servidor, com sudo): sudo ./00-infrastructure/auto-deploy/instalar.sh tarantec
# Desligar: sudo systemctl disable --now bergatrix-auto-deploy@<app>.timer
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "rode com sudo" >&2; exit 1; }
[ $# -gt 0 ] || { echo "uso: sudo $0 <app> [<app>...]" >&2; exit 2; }

DIR=$(cd "$(dirname "$0")" && pwd)
# Roda como o dono do repositório (que está no grupo docker), não como root.
DONO=$(stat -c %U "$DIR/auto-deploy.sh")

sed -e "s#@DONO@#$DONO#" -e "s#@SCRIPT@#$DIR/auto-deploy.sh#" \
  "$DIR/bergatrix-auto-deploy@.service" > /etc/systemd/system/bergatrix-auto-deploy@.service
install -m 0644 "$DIR/bergatrix-auto-deploy@.timer" /etc/systemd/system/bergatrix-auto-deploy@.timer
chmod 0644 /etc/systemd/system/bergatrix-auto-deploy@.service
systemctl daemon-reload

for app in "$@"; do
  systemctl enable --now "bergatrix-auto-deploy@$app.timer"
  echo "ligado: bergatrix-auto-deploy@$app.timer"
done
systemctl list-timers 'bergatrix-auto-deploy@*' --no-pager
