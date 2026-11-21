#!/usr/bin/env bash
# Troca as lojas pré-cadastradas dos EUA e da Austrália pelas brasileiras (lojas/brasil.php).
#
#   ./lojas/trocar-lojas.sh          remove as lojas de lá sem produto e cria/atualiza as daqui
#   ./lojas/trocar-lojas.sh --ver    só mostra o que faria
#
# Pode rodar de novo a qualquer momento: as lojas que já existem são atualizadas pelo
# brasil.php (mesmo slug), e as que você criou à mão ficam como estão. Loja dos EUA ou
# da Austrália com produto cadastrado fica, com um aviso.
set -euo pipefail
cd "$(dirname "$0")/.."

ver=false
[ "${1:-}" = "--ver" ] && ver=true

if ! docker exec pricebuddy test -f /app/database/seeders/Stores/brasil.php; then
  echo "O container não tem o lojas/brasil.php montado. Rode antes: docker compose up -d app" >&2
  exit 1
fi

docker exec -e VER="$ver" pricebuddy php artisan tinker --execute '
use App\Models\Store;
$fora = collect(["usa", "australia"])
    ->flatMap(fn ($c) => require "/app/database/seeders/Stores/$c.php")
    ->map(fn ($s) => $s["slug"] ?? Illuminate\Support\Str::slug($s["name"]));
foreach (Store::whereIn("slug", $fora)->withCount("urls")->get() as $s) {
    if ($s->urls_count > 0) {
        echo "Mantida (tem {$s->urls_count} produto(s)): {$s->name}\n";
        continue;
    }
    echo (getenv("VER") === "true" ? "Removeria: " : "Removida: ") . $s->name . "\n";
    if (getenv("VER") !== "true") { $s->delete(); }
}
$br = collect(require "/app/database/seeders/Stores/brasil.php");
$novas = $br->reject(fn ($s) => Store::where("slug", $s["slug"])->exists())->pluck("name");
echo "Lojas brasileiras: {$br->count()} no arquivo, " . $novas->count() . " novas" .
    ($novas->isNotEmpty() ? " (" . $novas->implode(", ") . ")" : "") . "\n";
'

if [ "$ver" = false ]; then
  docker exec pricebuddy php artisan buddy:create-stores brasil --update
fi
