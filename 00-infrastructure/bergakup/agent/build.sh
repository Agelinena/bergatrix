#!/usr/bin/env bash
# Compila o bergakup-agent dentro de um container Go (não precisa de Go no host).
# Gera agent/bergakup-agent (binário estático, linux/amd64).
#
# Uso: ./00-infrastructure/bergakup/agent/build.sh
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
VERSION=$(git -C "$DIR" describe --tags --always --dirty 2>/dev/null || echo dev)

docker run --rm \
  -v "$DIR":/src -w /src \
  -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="${GOARCH:-amd64}" \
  -e GOFLAGS=-buildvcs=false \
  golang:1.23.4-bookworm \
  sh -c "go mod tidy && go vet ./... && go build -trimpath -ldflags '-s -w -X main.version=$VERSION' -o bergakup-agent ."

# O go.sum gerado deve ir para o git (dependências conferidas).
echo "Pronto: $DIR/bergakup-agent ($VERSION)"
