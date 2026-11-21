#!/usr/bin/env bash
# Grava os cookies do navegador numa loja (padrão: Mercado Livre).
#
# Aceita o arquivo cookies.txt (formato Netscape, o que extensões como
# "Get cookies.txt LOCALLY" exportam) ou a linha do cabeçalho Cookie copiada do
# F12. Converte para "nome=valor; nome2=valor2", que é o que o PriceBuddy manda
# no cabeçalho Cookie, descarta os vencidos e os de outros domínios, e grava
# direto no banco sem mostrar os valores na tela.
#
#   ./lojas/cookies-loja.sh ~/cookies.txt
#   ./lojas/cookies-loja.sh ~/cookies.txt 'Mercado Livre' mercadolivre.com.br
#
# Apague o arquivo depois: ele é a sua sessão.
set -euo pipefail
arquivo="${1:?Uso: $0 <cookies.txt> [nome da loja] [domínio]}"
loja="${2:-Mercado Livre}"
dominio="${3:-mercadolivre.com.br}"
[ -r "$arquivo" ] || { echo "Não consegui ler $arquivo." >&2; exit 1; }

if grep -q $'\t' "$arquivo"; then
  # Formato Netscape: domínio, subdomínios, caminho, seguro, validade, nome, valor.
  # Linhas "#HttpOnly_" são cookies de verdade (só marcados como HttpOnly).
  cabecalho=$(awk -F'\t' -v agora="$(date +%s)" -v dom="$dominio" '
    { sub(/\r$/, "") }
    /^#HttpOnly_/ { sub(/^#HttpOnly_/, "") }
    /^#/ || NF < 7 { next }
    { d = $1; sub(/^\./, "", d) }
    d != dom && substr(d, length(d) - length(dom)) != "." dom { next }
    $5 != 0 && $5 < agora { next }
    { saida = saida (saida == "" ? "" : "; ") $6 "=" $7; n++ }
    END { print saida; print n " cookies" > "/dev/stderr" }
  ' "$arquivo")
else
  # Já é a linha do cabeçalho: junta tudo numa linha e tira um "Cookie:" na frente.
  cabecalho=$(tr -d '\r\n' < "$arquivo" | sed -E 's/^[[:space:]]*[Cc]ookie:[[:space:]]*//')
fi
[ -n "$cabecalho" ] || { echo "Nenhum cookie de $dominio no arquivo." >&2; exit 1; }

printf '%s' "$cabecalho" | docker exec -i -e LOJA="$loja" pricebuddy php artisan tinker --execute '
$loja = App\Models\Store::where("name", getenv("LOJA"))->first();
if (! $loja) { echo "Loja \"" . getenv("LOJA") . "\" não encontrada.\n"; return; }
$loja->cookies = trim(file_get_contents("php://stdin"));
$loja->save();
echo "Cookies gravados em {$loja->name} (" . strlen($loja->cookies) . " caracteres).\n";
' 2>&1 | grep -v DEPRECATED
