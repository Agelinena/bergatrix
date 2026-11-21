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
$trecho = fn ($i, $n = 60) => preg_replace("/\s+/", " ", substr($corpo, max(0, $i - $n), 2 * $n));
foreach (["account-verification", "suspicious", "requires JavaScript"] as $marca) {
    if (($i = strpos($corpo, $marca)) !== false) {
        echo "Sinal de verificação de robô (\"{$marca}\"): …" . $trecho($i) . "…\n";
    }
}
// Sem preço: mostra onde a página tem preço, para escolher a regra certa da loja.
if (! ($r["price"] ?? null)) {
    echo "\nPágina: " . strlen($corpo) . " bytes. Onde aparece preço:\n";
    $padroes = [
        "meta itemprop=price"      => "~<meta[^>]+itemprop=.?price.?[^>]*>~i",
        "meta product:price"       => "~<meta[^>]+product:price:amount[^>]*>~i",
        "JSON \"price\""            => "~\"price\"\s*:\s*\"?[\d.,]+~",
        "andes-money-amount"       => "~andes-money-amount__fraction[^>]*>[^<]+~",
        "R$ no texto"              => "~R\\$\s*[\d.]+(,\d{2})?~",
    ];
    foreach ($padroes as $nome => $re) {
        preg_match_all($re, $corpo, $m);
        $achados = array_slice(array_unique($m[0]), 0, 3);
        echo "  {$nome}: " . ($achados ? implode("  |  ", array_map(fn ($a) => substr($a, 0, 120), $achados)) : "nada") . "\n";
    }
}
' 2>&1 | grep -v DEPRECATED
