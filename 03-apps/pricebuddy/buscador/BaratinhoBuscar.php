<?php

namespace App\Console\Commands;

use App\Baratinho\Comparador;
use App\Baratinho\Dominios;
use App\Baratinho\Ia;
use App\Baratinho\Identificadores;
use App\Baratinho\Listas;
use App\Baratinho\LojasNovas;
use App\Baratinho\Pagina;
use App\Baratinho\Rede;
use App\Baratinho\Texto;
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
 * docker-compose.yml no serviço "buscador", com as classes de buscador/Baratinho).
 *
 * A cada rodada:
 *
 *   1. Testa as lojas criadas automaticamente (uma vez por dia cada); as que
 *      falham 3 dias seguidos são desativadas (LojasNovas).
 *   2. Classifica alguns sites desconhecidos que apareceram nas buscas (loja,
 *      notícia, comparador...): regras da página e, na dúvida, a IA local. Site
 *      que é loja vira loja nova, já testada no produto em que apareceu.
 *   3. Para cada produto ainda não procurado:
 *      a. lê a primeira URL dele (ISBN, EAN, código do fabricante);
 *      b. busca no SearXNG pelo ISBN ou título, e também dentro das lojas que
 *         vendem coisas parecidas (site:loja ...);
 *      c. fica com páginas de produto (não listagens) de lojas cadastradas que o
 *         produto ainda não tem; site já classificado como loja vira loja nova;
 *         anota os sites desconhecidos;
 *      d. lê cada candidata e compara (Comparador): sim entra, não fica de fora,
 *         dúvida vai para a IA;
 *      e. acrescenta com Url::createFromUrl, como a tela do app.
 *
 * O que já foi procurado fica em baratinho_buscas; depois de
 * PRICEBUDDY_BUSCA_REFAZER_DIAS, o produto é procurado de novo.
 */
class BaratinhoBuscar extends Command
{
    protected $signature = 'baratinho:buscar
        {--produto= : Procura só este produto (id), mesmo que já tenha sido procurado}
        {--simular : Mostra o que acrescentaria, sem gravar nada}
        {--so-dominios : Só classifica os sites pendentes}';

    protected $description = 'Procura o mesmo produto nas outras lojas e acrescenta as que baterem';

    protected const TABELA = 'baratinho_buscas';

    protected const SEARXNG = 'http://searxng:8080/search';

    /** Endereço do filtro da pesquisa do app (buscador/filtro.php), que esconde o que não é loja. */
    protected const FILTRO = 'http://buscador:8081/search';

    protected Ia $ia;

    protected LojasNovas $lojasNovas;

    /** @var array<int, array> Dados do original por produto, nesta rodada. */
    protected array $originais = [];

    public function handle(): int
    {
        $this->garantirTabela();
        Dominios::garantirTabela();
        Ia::garantirTabela();
        LojasNovas::garantirTabela();
        $this->configurarSearxng();
        $this->ia = new Ia;
        // Simulando, não cria loja nenhuma.
        $this->lojasNovas = new LojasNovas(fn (string $m) => $this->line($m), $this->option('simular') ? 0 : null);

        if (! $this->option('simular')) {
            $this->lojasNovas->verificar((int) env('PRICEBUDDY_LOJAS_VERIFICAR_POR_RODADA', 5));
        }
        $this->classificarDominios();
        if ($this->option('so-dominios')) {
            return self::SUCCESS;
        }

        $produtos = $this->option('produto')
            ? Product::query()->whereKey($this->option('produto'))->get()
            : $this->fila();

        $lojas = Store::query()->get();

        foreach ($produtos as $produto) {
            try {
                $this->buscarProduto($produto, $lojas);
            } catch (Throwable $e) {
                $this->warn("Produto {$produto->getKey()}: erro {$e->getMessage()}");
                $this->registrar($produto, null, null, [], 'erro: '.Str::limit($e->getMessage(), 200));
            }
        }

        if ($this->ia->usadas()) {
            $this->line("IA: {$this->ia->usadas()} consulta(s) nesta rodada.");
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

        $orig = $this->dadosOriginal($produto);
        $titulo = $orig['titulo'];
        $isbn = $orig['isbn'];
        $termo = $isbn ?: ($orig['gtins'] ? ltrim($orig['gtins'][0], '0') : null);

        // Lojas que o produto já tem, e URLs que a pessoa tirou ou dispensou.
        $jaTem = $produto->urls()->pluck('store_id')->filter()->all();
        $ignoradas = collect(array_merge((array) $produto->ignored_urls, (array) $produto->ignored_search_urls))
            ->map(fn ($u) => is_array($u) ? ($u['url'] ?? null) : $u)
            ->filter()->map(fn ($u) => Texto::semRastreio($u))->all();

        // Busca geral, e busca dentro das lojas que vendem coisas parecidas.
        $consultas = array_values(array_filter(array_unique([
            $termo,
            $isbn ? null : $titulo,
            $isbn && $titulo ? $titulo.' '.$isbn : null,
        ])));
        foreach ($this->lojasProvaveis($produto, $titulo, $lojas, $jaTem) as $loja) {
            $dominio = data_get($loja->domains, '0.domain');
            if ($dominio) {
                $consultas[] = 'site:'.$dominio.' '.($isbn ?: Texto::tituloCurto($titulo));
            }
        }

        $candidatos = [];
        $novas = [];
        $desconhecidos = 0;
        $fora = LojasNovas::desativadas();
        foreach ($consultas as $consulta) {
            foreach ($this->searxng($consulta, str_starts_with($consulta, 'site:') ? 1 : 2) as $resultado) {
                $url = Texto::semRastreio((string) ($resultado['url'] ?? ''));
                $host = strtolower((string) parse_url($url, PHP_URL_HOST));
                if ($host === '' || in_array($url, $ignoradas, true) || Listas::pareceListagem($url)) {
                    continue;
                }
                $loja = $lojas->first(fn (Store $s) => $s->hasDomain($host));
                if (! $loja) {
                    $tipo = Dominios::tipo($host);
                    if ($tipo === 'loja') {
                        $novas[Listas::normalizarHost($host)] ??= $url;
                    } elseif (! $tipo && ! $this->option('simular')) {
                        Dominios::anotar($host, $url, $produto->getKey());
                        $desconhecidos++;
                    }

                    continue;
                }
                if (in_array($loja->getKey(), $jaTem) || in_array($loja->getKey(), $fora) || isset($candidatos[$loja->getKey()])) {
                    continue;
                }
                $candidatos[$loja->getKey()] = ['url' => $url, 'loja' => $loja];
            }
        }

        // Sites já classificados como loja, ainda sem cadastro: vira loja nova.
        foreach ($novas as $url) {
            $loja = $this->lojasNovas->criar($url, $produto->user_id);
            if (! $loja || in_array($loja->getKey(), $jaTem) || in_array($loja->getKey(), $fora) || isset($candidatos[$loja->getKey()])) {
                continue;
            }
            if (! $lojas->contains(fn (Store $s) => $s->is($loja))) {
                $lojas->push($loja);
            }
            $candidatos[$loja->getKey()] = ['url' => $url, 'loja' => $loja];
        }

        $max = (int) env('PRICEBUDDY_BUSCA_MAX_LOJAS', 8);
        $adicionadas = [];

        foreach (array_slice($candidatos, 0, max(1, $max * 2), true) as $c) {
            if (count($adicionadas) >= $max) {
                break;
            }

            [$ok, $motivo] = $this->avaliar($orig, $c);
            $this->line(sprintf('  %s %s: %s', $ok ? '+' : '-', $c['loja']->name, $motivo));
            if ($this->getOutput()->isVerbose()) {
                $this->line('      '.$c['url']);
            }
            if (! $ok) {
                continue;
            }

            if ($this->acrescentar($produto, $c['url'])) {
                $adicionadas[] = $c['url'];
            }
        }

        $resumo = sprintf('%d consulta(s), %d candidata(s), %d acrescentada(s), %d site(s) novo(s) anotado(s)', count($consultas), count($candidatos), count($adicionadas), $desconhecidos);
        $this->line('  '.$resumo);

        if (! $this->option('simular')) {
            $this->registrar($produto, implode(' | ', $consultas), $isbn, $adicionadas, $resumo);
        }
    }

    /**
     * Título, preço e identificadores da primeira URL do produto (lida sem cache:
     * o resultado guardado pelo app não traz o HTML). Guardado nesta rodada.
     */
    protected function dadosOriginal(Product $produto): array
    {
        if (isset($this->originais[$produto->getKey()])) {
            return $this->originais[$produto->getKey()];
        }
        $original = $produto->urls()->orderBy('id')->first();
        $r = $original ? ScrapeUrl::new($original->url)->setMaxAttempts(1)->scrape(['use_cache' => false]) : [];
        $pagina = new Pagina((string) $original?->url, (string) ($r['body'] ?? ''));

        return $this->originais[$produto->getKey()] = [
            'titulo' => Texto::limparTitulo((string) ($produto->title ?: ($r['title'] ?? ''))),
            'preco' => (float) ($produto->current_price ?: Texto::numero($r['price'] ?? null)),
            'isbn' => $pagina->isbn(),
            'gtins' => $pagina->gtins(),
            'mpn' => $pagina->mpn(),
            'nao_novo' => $pagina->naoNovo(),
            'texto' => $pagina->texto(500),
        ];
    }

    /** Acrescenta a URL ao produto (simulando, só finge). */
    protected function acrescentar(Product $produto, string $url): bool
    {
        if ($this->option('simular')) {
            return true;
        }

        return (bool) Url::createFromUrl($url, $produto->getKey(), $produto->user_id, false);
    }

    /**
     * Site recém-classificado como loja: cria a loja e testa a página em que ele
     * apareceu no produto daquela busca.
     */
    protected function lojaNovaNoProduto(int $produtoId, string $url): void
    {
        $produto = Product::find($produtoId);
        if (! $produto || $url === '' || Listas::pareceListagem($url) || ! $this->lojasNovas->ligada()) {
            return;
        }
        $loja = $this->lojasNovas->criar($url, $produto->user_id);
        if (! $loja || in_array($loja->getKey(), LojasNovas::desativadas())
            || $produto->urls()->where('store_id', $loja->getKey())->exists()) {
            return;
        }
        [$ok, $motivo] = $this->avaliar($this->dadosOriginal($produto), ['url' => $url, 'loja' => $loja]);
        $this->line(sprintf('  %s %s no produto %d: %s', $ok ? '+' : '-', $loja->name, $produtoId, $motivo));
        if ($ok && $this->acrescentar($produto, $url) && ! $this->option('simular')) {
            $this->registrarAdicionada($produto, $url);
        }
    }

    /**
     * Lê a candidata com a configuração da loja e compara com o original.
     *
     * @return array{0: bool, 1: string}
     */
    protected function avaliar(array $orig, array $c): array
    {
        $r = ScrapeUrl::new($c['url'])->setMaxAttempts(1)->scrape(['store' => $c['loja'], 'use_cache' => false]);
        $corpo = (string) ($r['body'] ?? '');
        $pagina = new Pagina($c['url'], $corpo);
        $cand = [
            'loja' => (string) $c['loja']->name,
            'titulo' => trim((string) ($r['title'] ?? '')) ?: $pagina->titulo(),
            'preco' => Texto::numero($r['price'] ?? null),
            'isbn_na_pagina' => $orig['isbn'] ? Identificadores::temIsbn($corpo, $orig['isbn']) : false,
            'gtins' => $pagina->gtins(),
            'mpn' => $pagina->mpn(),
            'nao_novo' => $pagina->naoNovo(),
            'texto' => $pagina->texto(500),
        ];

        [$decisao, $motivo] = Comparador::decidir($orig, $cand);
        if ($decisao !== 'duvida') {
            return [$decisao === 'sim', $motivo];
        }

        $ia = $this->ia->mesmoProduto($orig + ['loja' => 'original'], $cand);
        if ($ia === null) {
            return [false, $motivo.'; sem IA, fica de fora'];
        }

        return [$ia['mesmo'], sprintf('%s; IA: %s (%s)', $motivo, $ia['mesmo'] ? 'mesmo produto' : 'outro produto', Str::limit($ia['motivo'], 120))];
    }

    /**
     * Lojas com mais chance de ter o produto: as que já vendem produtos de
     * títulos parecidos (para cada produto com palavras em comum, as lojas dele
     * somam pontos). Sem histórico, as lojas com mais produtos.
     */
    protected function lojasProvaveis(Product $produto, string $titulo, Collection $lojas, array $jaTem): Collection
    {
        $max = (int) env('PRICEBUDDY_BUSCA_SITE_LOJAS', 4);
        if ($max < 1) {
            return collect();
        }
        $palavras = Texto::palavras($titulo);
        $pontos = [];
        $total = [];
        Product::query()->whereKeyNot($produto->getKey())->with('urls:id,product_id,store_id')->select('id', 'title')
            ->chunk(200, function ($outros) use ($palavras, &$pontos, &$total) {
                foreach ($outros as $p) {
                    $comuns = count(array_intersect($palavras, Texto::palavras((string) $p->title)));
                    foreach ($p->urls->pluck('store_id')->filter()->unique() as $loja) {
                        $total[$loja] = ($total[$loja] ?? 0) + 1;
                        if ($comuns >= 2) {
                            $pontos[$loja] = ($pontos[$loja] ?? 0) + $comuns;
                        }
                    }
                }
            });

        arsort($pontos);
        arsort($total);
        $ordem = array_unique(array_merge(array_keys($pontos), array_keys($total)));
        $ordem = array_values(array_diff($ordem, $jaTem, LojasNovas::desativadas()));

        return collect(array_slice($ordem, 0, $max))
            ->map(fn ($id) => $lojas->firstWhere('id', $id))
            ->filter();
    }

    /**
     * Classifica alguns sites desconhecidos por rodada: lê a página de exemplo,
     * decide pelas regras e, na dúvida, pela IA (sem IA, fica para depois).
     */
    protected function classificarDominios(): void
    {
        $limite = (int) env('PRICEBUDDY_BUSCA_DOMINIOS_POR_RODADA', 5);
        foreach (Dominios::pendentes($limite, $this->ia->ligada()) as $d) {
            if ($fixo = Listas::tipoFixo($d->host)) {
                Dominios::decidir($d->host, $fixo, 'lista', 'lista fixa');

                continue;
            }
            try {
                [$html] = Rede::baixar((string) $d->exemplo_url);
            } catch (Throwable $e) {
                Dominios::falhou($d->host, Str::limit($e->getMessage(), 100));
                $this->line("Site {$d->host}: não abriu ({$e->getMessage()})");

                continue;
            }

            $pagina = new Pagina((string) $d->exemplo_url, $html);
            if ($pagina->bloqueio()) {
                // Site que só funciona com JavaScript ou recusou a leitura simples: pelo navegador.
                try {
                    $pagina = new Pagina((string) $d->exemplo_url, Rede::baixar((string) $d->exemplo_url, true)[0]);
                } catch (Throwable) {
                    // Fica com a página que já tem.
                }
            }
            if ($bloqueio = $pagina->bloqueio()) {
                Dominios::falhou($d->host, $bloqueio);
                $this->line("Site {$d->host}: {$bloqueio}, tenta de novo depois");

                continue;
            }
            [$tipo, $motivo] = $pagina->veredito();
            $origem = 'regra';
            if ($tipo === 'duvida') {
                $ia = $this->ia->classificarPagina($pagina);
                if (! $ia) {
                    Dominios::decidir($d->host, 'duvida', 'regra', $motivo);
                    $this->line("Site {$d->host}: dúvida ({$motivo}), fica para a IA");

                    continue;
                }
                if ($ia['tipo'] === 'bloqueio') {
                    Dominios::falhou($d->host, 'IA: '.$ia['motivo']);
                    $this->line("Site {$d->host}: bloqueio ou erro (IA), tenta de novo depois");

                    continue;
                }
                [$tipo, $motivo, $origem] = [$ia['tipo'], $ia['motivo'], 'ia'];
            }
            Dominios::decidir($d->host, $tipo, $origem, $motivo);
            $this->line("Site {$d->host}: {$tipo} ({$origem}: {$motivo})");
            if ($tipo === 'loja' && $d->produto_id) {
                try {
                    $this->lojaNovaNoProduto((int) $d->produto_id, (string) $d->exemplo_url);
                } catch (Throwable $e) {
                    $this->warn("  loja nova {$d->host}: erro {$e->getMessage()}");
                }
            }
        }
    }

    protected function searxng(string $consulta, int $paginas = 2): array
    {
        $resultados = [];
        for ($pagina = 1; $pagina <= $paginas; $pagina++) {
            try {
                // Motor com captcha ou lento atrasa a resposta: espera mais e tenta de novo uma vez.
                $resposta = Http::timeout(60)->retry(2, 5000, throw: false)->get(self::SEARXNG, [
                    'q' => $consulta,
                    'format' => 'json',
                    'language' => 'pt-BR',
                    'pageno' => $pagina,
                ]);
                $resultados = array_merge($resultados, (array) $resposta->json('results', []));
            } catch (Throwable $e) {
                $this->warn('  SearXNG: '.Str::limit($e->getMessage(), 120));
            }
        }

        return $resultados;
    }

    protected function registrar(Product $produto, ?string $consulta, ?string $isbn, array $adicionadas, string $resumo): void
    {
        // Soma às de rodadas anteriores: a desativação de loja usa essa lista.
        $antes = (array) json_decode((string) DB::table(self::TABELA)->where('product_id', $produto->getKey())->value('adicionadas'), true);
        $adicionadas = array_values(array_unique(array_merge($antes, $adicionadas)));
        DB::table(self::TABELA)->updateOrInsert(
            ['product_id' => $produto->getKey()],
            [
                'consulta' => Str::limit((string) $consulta, 500, ''),
                'isbn' => $isbn,
                'adicionadas' => json_encode($adicionadas),
                'resumo' => Str::limit($resumo, 250, ''),
                'buscado_em' => now(),
            ]
        );
    }

    /** Uma URL acrescentada fora da busca do produto (loja nova). */
    protected function registrarAdicionada(Product $produto, string $url): void
    {
        $linha = DB::table(self::TABELA)->where('product_id', $produto->getKey())->first();
        if (! $linha) {
            $this->registrar($produto, null, null, [$url], 'loja nova');

            return;
        }
        $lista = array_values(array_unique(array_merge((array) json_decode((string) $linha->adicionadas, true), [$url])));
        DB::table(self::TABELA)->where('product_id', $produto->getKey())->update(['adicionadas' => json_encode($lista)]);
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
     * Aponta a pesquisa do app para o filtro (buscador/filtro.php, que esconde
     * notícias, comparadores e listagens) e completa os campos vazios do SearXNG
     * com os padrões do app. Um max_pages nulo (salvo pela tela de Settings)
     * derruba a pesquisa com "getMaxPages(): Return value must be of type int".
     * Um endereço posto à mão (outro que não o SearXNG da stack) é respeitado.
     */
    protected function configurarSearxng(): void
    {
        try {
            $settings = AppSettings::new();
            $servicos = (array) $settings->integrated_services;
            $atual = (array) data_get($servicos, 'searxng', []);
            $novo = $atual;
            if (in_array(data_get($atual, 'url'), [null, '', self::SEARXNG], true)) {
                $novo['url'] = self::FILTRO;
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
            $this->line('Pesquisa do app configurada ('.$novo['url'].').');
        } catch (Throwable $e) {
            $this->warn('Não deu para configurar a pesquisa do app: '.$e->getMessage());
        }
    }
}
