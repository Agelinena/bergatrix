<?php

namespace App\Console\Commands;

use App\Models\Product;
use App\Models\Store;
use App\Models\Url;
use App\Services\ScrapeUrl;
use App\Settings\AppSettings;
use Illuminate\Console\Command;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * Buscador automático do Baratinho (não faz parte do PriceBuddy; montado pelo
 * docker-compose.yml no serviço "buscador").
 *
 * Para cada produto ainda não procurado, acha o mesmo item nas outras lojas
 * cadastradas e acrescenta as URLs ao produto, sem intervenção:
 *
 *   1. Lê a página da primeira URL do produto. Se for livro, tira o ISBN.
 *   2. Procura no SearXNG pelo ISBN (livros) e pelo título.
 *   3. Fica só com resultados de lojas cadastradas que o produto ainda não tem
 *      (e que a pessoa não removeu do produto).
 *   4. Lê cada candidato com a configuração da loja e só aceita se for o mesmo
 *      item: mesmo ISBN, ou título parecido com os mesmos números de modelo e
 *      capacidade, e preço plausível.
 *   5. Acrescenta com Url::createFromUrl, como a tela do app faz.
 *
 * O que já foi procurado fica na tabela baratinho_buscas. Depois de
 * PRICEBUDDY_BUSCA_REFAZER_DIAS, o produto é procurado de novo.
 */
class BaratinhoBuscar extends Command
{
    protected $signature = 'baratinho:buscar
        {--produto= : Procura só este produto (id), mesmo que já tenha sido procurado}
        {--simular : Mostra o que acrescentaria, sem gravar nada}';

    protected $description = 'Procura o mesmo produto nas outras lojas cadastradas e acrescenta as que baterem';

    protected const TABELA = 'baratinho_buscas';

    protected const SEARXNG = 'http://searxng:8080/search';

    /** Palavras que não ajudam a comparar títulos. */
    protected const VAZIAS = [
        'de', 'da', 'do', 'das', 'dos', 'e', 'a', 'o', 'as', 'os', 'em', 'com', 'para', 'por', 'um', 'uma', 'no', 'na',
        'the', 'and', 'of', 'for', 'with', 'kit', 'novo', 'nova', 'original', 'oficial', 'frete', 'gratis', 'cor',
        'amazon', 'br', 'com', 'loja', 'comprar', 'compre', 'oferta', 'promocao', 'preco', 'livro', 'livros', 'edicao',
    ];

    /** Unidades de capacidade, tamanho e potência: valores diferentes = produtos diferentes. */
    protected const UNIDADES = 'gb|tb|mb|ml|l|kg|g|t|mg|mm|cm|m|w|v|hz|mah|pol|polegadas|pcs|un|unidades|lugares|pessoas';

    public function handle(): int
    {
        $this->garantirTabela();
        $this->configurarSearxng();

        $produtos = $this->option('produto')
            ? Product::query()->whereKey($this->option('produto'))->get()
            : $this->fila();

        if ($produtos->isEmpty()) {
            return self::SUCCESS;
        }

        $lojas = Store::query()->get();

        foreach ($produtos as $produto) {
            try {
                $this->buscarProduto($produto, $lojas);
            } catch (Throwable $e) {
                $this->warn("Produto {$produto->getKey()}: erro {$e->getMessage()}");
                $this->registrar($produto, null, null, [], 'erro: '.Str::limit($e->getMessage(), 200));
            }
        }

        return self::SUCCESS;
    }

    /** Produtos nunca procurados (os mais novos primeiro) ou procurados há muito tempo. */
    protected function fila(): Collection
    {
        $dias = (int) env('PRICEBUDDY_BUSCA_REFAZER_DIAS', 30);
        $limite = (int) env('PRICEBUDDY_BUSCA_POR_RODADA', 5);

        return Product::query()
            ->whereHas('urls')
            ->whereNotIn('id', DB::table(self::TABELA)
                ->where('buscado_em', '>', now()->subDays(max(1, $dias)))
                ->select('product_id'))
            ->orderByDesc('id')
            ->limit(max(1, $limite))
            ->get();
    }

    protected function buscarProduto(Product $produto, Collection $lojas): void
    {
        $original = $produto->urls()->orderBy('id')->first();
        if (! $original) {
            return;
        }

        $this->line("Produto {$produto->getKey()}: {$produto->title}");

        $pagina = ScrapeUrl::new($original->url)->setMaxAttempts(1)->scrape();
        $isbn = $this->acharIsbn((string) ($pagina['body'] ?? ''));
        $titulo = $this->limparTitulo((string) ($produto->title ?: ($pagina['title'] ?? '')));
        $precoRef = (float) ($produto->current_price ?: ($pagina['price'] ?? 0));

        $consultas = array_values(array_filter(array_unique([
            $isbn,
            $isbn ? null : $titulo,
            $isbn && $titulo ? $titulo.' '.$isbn : null,
        ])));

        // Lojas que o produto já tem, e URLs que a pessoa tirou ou dispensou.
        $jaTem = $produto->urls()->pluck('store_id')->filter()->all();
        $ignoradas = collect(array_merge((array) $produto->ignored_urls, (array) $produto->ignored_search_urls))
            ->map(fn ($u) => is_array($u) ? ($u['url'] ?? null) : $u)
            ->filter()->map(fn ($u) => $this->semRastreio($u))->all();

        $candidatos = [];
        foreach ($consultas as $consulta) {
            foreach ($this->searxng($consulta) as $resultado) {
                $url = $this->semRastreio((string) ($resultado['url'] ?? ''));
                $host = strtolower((string) parse_url($url, PHP_URL_HOST));
                if ($host === '' || in_array($url, $ignoradas, true)) {
                    continue;
                }
                $loja = $lojas->first(fn (Store $s) => $s->hasDomain($host));
                if (! $loja || in_array($loja->getKey(), $jaTem) || isset($candidatos[$loja->getKey()])) {
                    continue;
                }
                $candidatos[$loja->getKey()] = ['url' => $url, 'loja' => $loja];
            }
        }

        $max = (int) env('PRICEBUDDY_BUSCA_MAX_LOJAS', 8);
        $adicionadas = [];

        foreach (array_slice($candidatos, 0, max(1, $max * 2), true) as $c) {
            if (count($adicionadas) >= $max) {
                break;
            }

            $r = ScrapeUrl::new($c['url'])->setMaxAttempts(1)->scrape(['store' => $c['loja'], 'use_cache' => false]);
            $tituloC = trim((string) ($r['title'] ?? ''));
            $precoC = $this->numero($r['price'] ?? null);

            [$ok, $motivo] = $this->mesmoProduto($isbn, $titulo, $precoRef, $tituloC, $precoC, (string) ($r['body'] ?? ''), (string) $c['loja']->name);
            $this->line(sprintf('  %s %s: %s', $ok ? '+' : '-', $c['loja']->name, $motivo));
            if ($this->getOutput()->isVerbose()) {
                $this->line('      '.$c['url'].' | '.Str::limit($tituloC, 90));
            }

            if (! $ok) {
                continue;
            }

            if ($this->option('simular')) {
                $adicionadas[] = $c['url'];

                continue;
            }

            $nova = Url::createFromUrl($c['url'], $produto->getKey(), $produto->user_id, false);
            if ($nova) {
                $adicionadas[] = $c['url'];
            }
        }

        $resumo = sprintf('%d candidato(s), %d acrescentada(s)', count($candidatos), count($adicionadas));
        $this->line('  '.$resumo);

        if (! $this->option('simular')) {
            $this->registrar($produto, implode(' | ', $consultas), $isbn, $adicionadas, $resumo);
        }
    }

    /** @return array{0: bool, 1: string} */
    protected function mesmoProduto(?string $isbn, string $titulo, float $precoRef, string $tituloC, ?float $precoC, string $corpo, string $nomeLoja = ''): array
    {
        if ($tituloC === '' || ! $precoC) {
            return [false, 'sem título ou preço'];
        }

        if ($precoRef > 0 && ($precoC < $precoRef * 0.3 || $precoC > $precoRef * 3)) {
            return [false, sprintf('preço fora da faixa (R$ %.2f contra R$ %.2f)', $precoC, $precoRef)];
        }

        if ($isbn) {
            return $this->temIsbn($corpo, $isbn)
                ? [true, sprintf('mesmo ISBN, R$ %.2f', $precoC)]
                : [false, 'ISBN diferente ou ausente'];
        }

        $a = $this->palavras($titulo);
        $b = array_values(array_diff($this->palavras($tituloC), $this->palavras($nomeLoja)));
        if (! $a || ! $b) {
            return [false, 'título vazio'];
        }

        $comuns = count(array_intersect($a, $b));
        $semelhanca = $comuns / min(count($a), count($b));
        if ($semelhanca < 0.6 || $comuns < 3) {
            return [false, sprintf('título diferente (%.0f%%)', $semelhanca * 100)];
        }

        // Números de modelo (rtx 5060, sa400s37, a400): os do original precisam aparecer.
        $modeloA = array_filter($a, fn ($p) => preg_match('/\d/', $p) && ! $this->unidade($p));
        $modeloB = array_filter($b, fn ($p) => preg_match('/\d/', $p) && ! $this->unidade($p));
        if ($modeloA && ! array_intersect($modeloA, $modeloB)) {
            return [false, 'modelo diferente'];
        }

        // Capacidade e tamanho (240gb x 480gb, 110v x 220v): mesma unidade, valores sem nada em comum = outro produto.
        $ua = $this->medidas($a);
        $ub = $this->medidas($b);
        foreach ($ua as $u => $valores) {
            if (isset($ub[$u]) && ! array_intersect($valores, $ub[$u])) {
                return [false, "medida diferente ({$u})"];
            }
        }

        return [true, sprintf('título %.0f%% igual, R$ %.2f', $semelhanca * 100, $precoC)];
    }

    protected function searxng(string $consulta): array
    {
        $resultados = [];
        foreach ([1, 2] as $pagina) {
            try {
                $resposta = Http::timeout(30)->get(self::SEARXNG, [
                    'q' => $consulta,
                    'format' => 'json',
                    'language' => 'pt-BR',
                    'pageno' => $pagina,
                ]);
                $resultados = array_merge($resultados, (array) $resposta->json('results', []));
            } catch (Throwable $e) {
                $this->warn('  SearXNG: '.$e->getMessage());
            }
        }

        return $resultados;
    }

    /** ISBN-13 da página (JSON-LD, metadados ou o texto "ISBN"), conferido pelo dígito verificador. */
    protected function acharIsbn(string $html): ?string
    {
        $achados = [];
        if (preg_match_all('/"isbn"\s*:\s*"([0-9Xx\- ]{10,20})"/', $html, $m)) {
            $achados = array_merge($achados, $m[1]);
        }
        if (preg_match_all('/(?:book:isbn|itemprop="isbn")[^>]*content="([0-9Xx\- ]{10,20})"/i', $html, $m)) {
            $achados = array_merge($achados, $m[1]);
        }
        $texto = html_entity_decode(strip_tags(preg_replace('/<(script|style)\b.*?<\/\1>/is', ' ', $html)));
        if (preg_match_all('/ISBN(?:-1[03])?\s*[:\x{A0} ]*\s*((?:97[89][\-\x{A0} ]?)?[0-9][0-9\-\x{A0} ]{8,15}[0-9Xx])/iu', $texto, $m)) {
            $achados = array_merge($achados, $m[1]);
        }

        foreach ($achados as $bruto) {
            if ($isbn = $this->isbn13($bruto)) {
                return $isbn;
            }
        }

        return null;
    }

    protected function isbn13(string $bruto): ?string
    {
        $d = strtoupper(preg_replace('/[^0-9Xx]/', '', $bruto));
        if (strlen($d) === 10) {
            $d = '978'.substr($d, 0, 9);
            $soma = 0;
            for ($i = 0; $i < 12; $i++) {
                $soma += (int) $d[$i] * ($i % 2 ? 3 : 1);
            }

            return $d.((10 - $soma % 10) % 10);
        }
        if (strlen($d) !== 13 || ! preg_match('/^97[89]\d{10}$/', $d)) {
            return null;
        }
        $soma = 0;
        for ($i = 0; $i < 12; $i++) {
            $soma += (int) $d[$i] * ($i % 2 ? 3 : 1);
        }

        return ((10 - $soma % 10) % 10) === (int) $d[12] ? $d : null;
    }

    /** A página tem o mesmo ISBN (13 ou 10 dígitos, com ou sem separadores)? */
    protected function temIsbn(string $html, string $isbn): bool
    {
        $isbn10 = substr($isbn, 0, 3) === '978' ? substr($isbn, 3, 9) : null;
        foreach (array_filter([$isbn, $isbn10]) as $alvo) {
            $padrao = '/(?<![0-9])'.implode('[\-\s.]?', str_split($alvo)).($alvo === $isbn10 ? '[\-\s.]?[0-9Xx]' : '').'(?![0-9])/';
            if (preg_match($padrao, $html)) {
                return true;
            }
        }

        return false;
    }

    protected function limparTitulo(string $titulo): string
    {
        $titulo = preg_replace('/\s*[|–-]\s*(Amazon\.com\.br|Amazon|Magazine Luiza|Americanas|KaBuM!?|Mercado Livre).*$/iu', '', $titulo);

        return Str::limit(trim(preg_replace('/\s+/', ' ', $titulo)), 120, '');
    }

    /** @return array<int, string> */
    protected function palavras(string $texto): array
    {
        $texto = strtolower(Str::ascii($texto));
        // "240 GB" e "240GB" viram a mesma palavra.
        $texto = preg_replace('/(\d)\s+('.self::UNIDADES.')\b/', '$1$2', $texto);
        // Apelidos: 240G = 240GB, 2T = 2TB, 55" = 55 polegadas.
        $texto = preg_replace(['/(\d)gb\b/', '/(\d)tb\b/', '/(\d)(?:polegadas|")/', '/(\d)unidades\b/'], ['$1g', '$1t', '$1pol', '$1un'], $texto);
        $partes = preg_split('/[^a-z0-9]+/', $texto, -1, PREG_SPLIT_NO_EMPTY);

        return array_values(array_unique(array_filter(
            $partes,
            fn ($p) => strlen($p) >= 2 && ! in_array($p, self::VAZIAS, true)
        )));
    }

    protected function unidade(string $palavra): ?string
    {
        return preg_match('/^\d+(?:[.,]\d+)?('.self::UNIDADES.')$/', $palavra, $m) ? $m[1] : null;
    }

    /** @return array<string, array<int, string>> */
    protected function medidas(array $palavras): array
    {
        $out = [];
        foreach ($palavras as $p) {
            if ($u = $this->unidade($p)) {
                $out[$u][] = $p;
            }
        }

        return $out;
    }

    protected function numero(mixed $preco): ?float
    {
        if (is_numeric($preco)) {
            return (float) $preco;
        }
        $s = preg_replace('/[^0-9,.]/', '', (string) $preco);
        if ($s === '') {
            return null;
        }
        // Formato brasileiro (1.234,56) ou com ponto decimal (1234.56).
        if (str_contains($s, ',')) {
            $s = str_replace(['.', ','], ['', '.'], $s);
        }

        return is_numeric($s) ? (float) $s : null;
    }

    /** Tira parâmetros de rastreio, que mudam a cada busca. */
    protected function semRastreio(string $url): string
    {
        $partes = parse_url($url);
        if (! $partes || empty($partes['host'])) {
            return $url;
        }
        parse_str($partes['query'] ?? '', $q);
        $q = array_filter($q, fn ($k) => ! preg_match('/^(utm_|srsltid|gclid|fbclid|msockid|ref|tag|psc|smid|spm|scm)/i', (string) $k), ARRAY_FILTER_USE_KEY);

        return ($partes['scheme'] ?? 'https').'://'.$partes['host'].($partes['path'] ?? '/').($q ? '?'.http_build_query($q) : '');
    }

    protected function registrar(Product $produto, ?string $consulta, ?string $isbn, array $adicionadas, string $resumo): void
    {
        DB::table(self::TABELA)->updateOrInsert(
            ['product_id' => $produto->getKey()],
            [
                'consulta' => Str::limit((string) $consulta, 500, ''),
                'isbn' => $isbn,
                'adicionadas' => json_encode($adicionadas),
                'resumo' => $resumo,
                'buscado_em' => now(),
            ]
        );
    }

    protected function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->unsignedBigInteger('product_id')->primary();
            $t->string('consulta', 500)->nullable();
            $t->string('isbn', 13)->nullable();
            $t->text('adicionadas')->nullable();
            $t->string('resumo')->nullable();
            $t->timestamp('buscado_em');
        });
    }

    /**
     * Liga o SearXNG nas configurações do app (tela "criar por busca"), se ainda não
     * estiver ligado, e completa os campos vazios com os padrões do app. Um
     * max_pages nulo (salvo pela tela de Settings) derruba a pesquisa com
     * "getMaxPages(): Return value must be of type int, null returned".
     */
    protected function configurarSearxng(): void
    {
        try {
            $settings = AppSettings::new();
            $servicos = (array) $settings->integrated_services;
            $atual = (array) data_get($servicos, 'searxng', []);
            $novo = $atual;
            if (! data_get($atual, 'url')) {
                $novo['url'] = self::SEARXNG;
                $novo['enabled'] = true;
            }
            $padroes = [
                'max_pages' => \App\Services\SearchService::DEFAULT_MAX_PAGES,
                'max_priced_results' => \App\Services\SearchService::DEFAULT_MAX_PRICED_RESULTS,
                'prune_days' => \App\Models\UrlResearch::DEFAULT_PRUNE_DAYS,
            ];
            foreach ($padroes as $campo => $padrao) {
                if (! is_numeric($novo[$campo] ?? null)) {
                    $novo[$campo] = $padrao;
                }
            }
            if ($novo == $atual) {
                return;
            }
            $servicos['searxng'] = $novo;
            $settings->integrated_services = $servicos;
            $settings->save();
            $this->line('Configuração do SearXNG no app completada ('.$novo['url'].').');
        } catch (Throwable $e) {
            $this->warn('Não deu para ligar o SearXNG nas configurações: '.$e->getMessage());
        }
    }
}
