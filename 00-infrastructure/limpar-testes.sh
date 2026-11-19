#!/usr/bin/env bash
# Apaga tudo o que um teste deixou: containers, volumes, redes e imagens dos
# projetos compose `teste-*`, e as pastas de dados em ~/.cache/bergatrix-teste.
# Nunca toca em stack de verdade (só projetos que começam com "teste-").
#
# Uso: ./00-infrastructure/limpar-testes.sh          (apaga)
#      ./00-infrastructure/limpar-testes.sh --ver    (só mostra o que apagaria)
# Regras dos testes: docs/04-rotina-de-trabalho.md
set -uo pipefail

PASTA="${BERGATRIX_TESTE_DIR:-$HOME/.cache/bergatrix-teste}"
ver=false
[ "${1:-}" = "--ver" ] && ver=true

rodar() { if $ver; then echo "   (faria) $*"; else "$@"; fi; }

projetos=$( {
  docker ps -a --format '{{.Label "com.docker.compose.project"}}'
  docker volume ls --format '{{.Label "com.docker.compose.project"}}'
  docker network ls --format '{{.Label "com.docker.compose.project"}}'
} 2>/dev/null | grep '^teste-' | sort -u)

if [ -n "$projetos" ]; then
  for p in $projetos; do
    echo "==> $p"
    rodar docker compose -p "$p" down -v --remove-orphans --rmi local
    # O que o down não achou (projeto sem arquivo compose por perto).
    for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$p"); do rodar docker volume rm "$v"; done
    for n in $(docker network ls -q --filter "label=com.docker.compose.project=$p"); do rodar docker network rm "$n"; done
  done
else
  echo "Nenhum projeto teste-* no Docker."
fi

# Pastas de dados dos testes. Um container pode ter gravado como root, então
# apaga por dentro de um container, sem sudo.
if [ -d "$PASTA" ] && [ -n "$(ls -A "$PASTA" 2>/dev/null)" ]; then
  echo "==> $PASTA ($(du -sh "$PASTA" 2>/dev/null | cut -f1))"
  rodar docker run --rm -v "$PASTA:/d" alpine:3.20 sh -c 'rm -rf /d/* /d/.[!.]*'
fi

# Imagens sem nome (builds de teste trocados).
if $ver; then
  echo "Imagens sem nome: $(docker images -qf dangling=true | wc -l)"
else
  docker image prune -f >/dev/null
fi

# Sobra perigosa: mount dentro do scratchpad do Claude (o Docker recria a pasta
# como root a cada boot e o Claude Code para de funcionar).
presos=$(docker ps -a --format '{{.Names}} {{.Mounts}}' | grep '/tmp/claude-' || true)
if [ -n "$presos" ]; then
  echo
  echo "!! Containers com mount em /tmp/claude-* (apague-os):"
  echo "$presos"
fi

echo
$ver && echo "Nada foi apagado (--ver)." || echo "Testes limpos."
