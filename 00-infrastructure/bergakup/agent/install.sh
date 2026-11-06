#!/usr/bin/env bash
# Instala o bergakup-agent e o restic no host (a VM Docker).
#
#   cd ~/bergatrix/00-infrastructure/bergakup/agent
#   ./build.sh              # compila o agente (usa o Docker)
#   sudo ./install.sh       # instala restic, binário e serviço
#   sudo bergakup-agent enroll --code bkc_... --name servidor --repo-root ~/bergatrix
#   sudo systemctl enable --now bergakup-agent
#
# Guia: 00-infrastructure/bergakup/README.md
set -euo pipefail

RESTIC_VERSION="${RESTIC_VERSION:-0.17.3}"
DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
  echo "Rode com sudo." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Arquitetura não suportada: $(uname -m)" >&2; exit 1 ;;
esac

# ── restic (release oficial, conferida pelo SHA256SUMS da mesma release) ──
if ! command -v restic >/dev/null || ! restic version | grep -q "restic ${RESTIC_VERSION} "; then
  echo "==> restic ${RESTIC_VERSION}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}"
  file="restic_${RESTIC_VERSION}_linux_${ARCH}.bz2"
  curl -fsSL -o "$tmp/$file" "$base/$file"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$tmp" && grep " ${file}\$" SHA256SUMS | sha256sum -c -)
  bunzip2 -c "$tmp/$file" > "$tmp/restic"
  install -m 0755 "$tmp/restic" /usr/local/bin/restic
fi
restic version

# ── agente ──────────────────────────────────────────────────────────
if [ ! -x "$DIR/bergakup-agent" ]; then
  echo "Compile antes: $DIR/build.sh" >&2
  exit 1
fi
echo "==> bergakup-agent"
install -m 0755 "$DIR/bergakup-agent" /usr/local/bin/bergakup-agent
install -d -m 0700 /etc/bergakup /var/lib/bergakup /var/cache/bergakup
install -m 0644 "$DIR/bergakup-agent.service" /etc/systemd/system/bergakup-agent.service
systemctl daemon-reload
bergakup-agent version

if [ -f /etc/bergakup/agent.json ]; then
  echo "Agente já registrado. Reiniciando o serviço."
  systemctl restart bergakup-agent
else
  repo_root=$(cd "$DIR/../../.." && pwd)
  cat <<EOF

Falta registrar o agente. Na interface do Bergakup, gere um código em
Agente → Instalar e rode:

  sudo bergakup-agent enroll --code <código> --name servidor --repo-root $repo_root
  sudo systemctl enable --now bergakup-agent
EOF
fi
