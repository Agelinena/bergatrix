#!/usr/bin/env bash
# Testa uma URL de produto com a configuração da loja cadastrada (estratégia,
# scraper e cookies), sem gravar nada. Serve para conferir uma loja nova ou o
# Mercado Livre depois de colar os cookies.
#
#   ./lojas/testar-loja.sh 'https://www.mercadolivre.com.br/.../p/MLB...'
set -euo pipefail
url="${1:?Uso: $0 <url do produto>}"

docker exec -e URL="$url" pricebuddy php artisan tinker --execute '
$url = getenv("URL");
$host = parse_url($url, PHP_URL_HOST);
$loja = App\Models\Store::all()->first(fn ($s) => $s->hasDomain($host));
if (! $loja) { echo "Nenhuma loja cadastrada para {$host}.\n"; return; }
echo "Loja: {$loja->name} (scraper: {$loja->scraper_service}, cookies: " . ($loja->cookies ? "sim" : "não") . ")\n";
if ($loja->cookies && (str_contains($loja->cookies, "\n") || str_contains($loja->cookies, "\t"))) {
    echo "Os cookies estão em várias linhas (arquivo cookies.txt colado inteiro). Grave com ./lojas/cookies-loja.sh.\n";
}
try {
    $r = App\Services\ScrapeUrl::new($url)->setMaxAttempts(1)->scrape(["use_cache" => false]);
} catch (Throwable $e) {
    echo "Erro: " . $e->getMessage() . "\n"; return;
}
foreach ((array) ($r["errors"] ?? []) as $erro) { echo "Erro do scraper: " . (is_string($erro) ? $erro : json_encode($erro)) . "\n"; }
$corpo = (string) ($r["body"] ?? "");
echo "Título: " . (trim((string) ($r["title"] ?? "")) ?: "(vazio)") . "\n";
echo "Preço:  " . (($r["price"] ?? null) ?: "(vazio)") . "\n";
if (str_contains($corpo, "account-verification") || str_contains($corpo, "suspicious") || str_contains($corpo, "requires JavaScript")) {
    echo "A loja pediu verificação de robô: os cookies estão faltando, vencidos ou não foram aceitos.\n";
}
' 2>&1 | grep -v DEPRECATED
