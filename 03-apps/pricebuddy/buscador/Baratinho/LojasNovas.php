<?php

namespace App\Baratinho;

use App\Actions\CreateStoreAction;
use App\Models\Store;
use App\Models\Url;
use App\Services\AutoCreateStore;
use App\Services\ScrapeUrl;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * Lojas novas automáticas: um site classificado como loja, que aparece com a
 * página de um produto, vira loja cadastrada no PriceBuddy, sem intervenção.
 *
 * Criação: lê a página (leitura simples ou navegador), exige preço em R$, deixa o
 * AutoCreateStore do PriceBuddy descobrir as regras de título, preço e imagem, e
 * valida lendo o produto duas vezes com a loja ainda não salva (título e o mesmo
 * preço nas duas). Só então salva, com uma nota de que foi criada aqui.
 *
 * Saúde: cada loja automática é testada uma vez por dia; depois de 3 dias seguidos
 * sem conseguir ler preço, é desativada: o buscador para de usá-la e tira dos
 * produtos as URLs que ele mesmo pôs nela (para não ficar preço velho). A loja
 * continua cadastrada, para consertar à mão.
 *
 * Tabela baratinho_lojas_auto, por host: 'ativa', 'desativada' ou 'recusada'
 * (não deu para criar; tenta de novo depois de 30 dias).
 */
class LojasNovas
{
    public const TABELA = 'baratinho_lojas_auto';

    protected const FALHAS_PARA_DESATIVAR = 3;

    protected const REFAZER_RECUSADA_DIAS = 30;

    protected int $criadas = 0;

    protected int $porRodada;

    /** @var callable(string): void */
    protected $log;

    public function __construct(?callable $log = null, ?int $porRodada = null)
    {
        $this->log = $log ?? fn (string $m) => null;
        $this->porRodada = $porRodada ?? (int) env('PRICEBUDDY_LOJAS_NOVAS_POR_RODADA', 3);
    }

    public static function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->string('host')->primary();
            $t->unsignedBigInteger('store_id')->nullable()->index();
            $t->string('status', 20)->index();
            $t->string('motivo')->nullable();
            $t->text('url_teste')->nullable();
            $t->integer('falhas')->default(0);
            $t->timestamp('criada_em')->nullable();
            $t->timestamp('verificada_em')->nullable();
            $t->timestamp('atualizado_em')->nullable();
        });
    }

    public function ligada(): bool
    {
        return $this->porRodada > 0;
    }

    /** Ids das lojas que o buscador não deve usar (desativadas). */
    public static function desativadas(): array
    {
        return DB::table(self::TABELA)->where('status', 'desativada')->whereNotNull('store_id')->pluck('store_id')->all();
    }

    /** Loja cadastrada para o host (com ou sem "www."), se houver. */
    public static function lojaDoHost(string $host): ?Store
    {
        $h = Listas::normalizarHost($host);

        return Store::query()->get()->first(fn (Store $s) => $s->hasDomain($h) || $s->hasDomain('www.'.$h));
    }

    /**
     * Cria a loja do site desta URL (página de produto), ou devolve a que já existe.
     * Null quando não dá (sem cota na rodada, recusada há pouco, sem preço em R$,
     * sem regra detectável ou leitura instável).
     */
    public function criar(string $url, ?int $userId = null): ?Store
    {
        $host = Listas::normalizarHost((string) parse_url($url, PHP_URL_HOST));
        if ($host === '' || Listas::tipoFixo($host)) {
            return null;
        }
        if ($existente = self::lojaDoHost($host)) {
            return $existente;
        }
        $registro = DB::table(self::TABELA)->where('host', $host)->first();
        if ($registro && $registro->status === 'recusada'
            && $registro->atualizado_em && now()->diffInDays($registro->atualizado_em, true) < self::REFAZER_RECUSADA_DIAS) {
            return null;
        }
        if ($this->criadas >= $this->porRodada) {
            return null;
        }
        $this->criadas++;

        try {
            [$pagina, $servico] = Rede::pagina($url);
        } catch (Throwable $e) {
            return $this->recusar($host, $url, 'não abriu: '.Str::limit($e->getMessage(), 80));
        }
        if ($b = $pagina->bloqueio()) {
            // Não é recusa: o site pode abrir na próxima.
            ($this->log)("  loja nova {$host}: {$b}, tenta depois");
            $this->criadas--;

            return null;
        }

        $moeda = $pagina->oferta()['moeda'];
        if ($moeda !== '' && $moeda !== 'BRL') {
            Dominios::decidir($host, 'outro', 'regra', "vende em {$moeda}");

            return $this->recusar($host, $url, "vende em {$moeda}");
        }
        if ($moeda === '' && ! preg_match('/R\$\s*\d/', $pagina->html)) {
            return $this->recusar($host, $url, 'sem preço em R$');
        }
        if ($pagina->naoNovo()) {
            return $this->recusar($host, $url, 'anúncio de usado (fica para outra página)');
        }

        $detectado = AutoCreateStore::new($url, $pagina->html, $servico)->setLogErrors(false)->detect();
        if (! $detectado) {
            return $this->recusar($host, $url, 'sem regra de título e preço detectável');
        }

        $atributos = AutoCreateStore::buildAttributes($url, $detectado['fields'], $userId);
        $atributos['name'] = self::nome($pagina, $host);
        $atributos['notes'] = sprintf('Criada automaticamente pelo Baratinho em %s, a partir de %s.', now()->format('d/m/Y'), $url);
        data_set($atributos, 'settings.scraper_service', $servico);
        data_set($atributos, 'settings.locale_settings', ['locale' => 'pt_BR', 'currency' => 'BRL']);

        // Valida com a loja ainda não salva; se a leitura simples do PriceBuddy
        // (outro navegador) falhar, tenta pelo navegador do scraper.
        $preco = $this->validar($url, $atributos);
        if (! $preco && $servico === 'http') {
            data_set($atributos, 'settings.scraper_service', 'api');
            $preco = $this->validar($url, $atributos);
        }
        if (! $preco) {
            return $this->recusar($host, $url, 'leitura instável (título ou preço faltando ou mudando)');
        }

        $loja = (new CreateStoreAction)($atributos);
        if (! $loja) {
            return $this->recusar($host, $url, 'o PriceBuddy recusou salvar a loja');
        }

        DB::table(self::TABELA)->updateOrInsert(['host' => $host], [
            'store_id' => $loja->getKey(), 'status' => 'ativa', 'motivo' => sprintf('R$ %.2f na validação', $preco),
            'url_teste' => $url, 'falhas' => 0, 'criada_em' => now(), 'verificada_em' => now(), 'atualizado_em' => now(),
        ]);
        ($this->log)(sprintf('  loja nova: %s (%s, %s, R$ %.2f)', $loja->name, $host, data_get($atributos, 'settings.scraper_service'), $preco));

        return $loja;
    }

    /** Lê o produto duas vezes com a loja não salva. Devolve o preço, ou null. */
    protected function validar(string $url, array $atributos): ?float
    {
        $loja = new Store($atributos);
        $precos = [];
        for ($i = 0; $i < 2; $i++) {
            try {
                $r = ScrapeUrl::new($url)->setMaxAttempts(1)->scrape(['store' => $loja, 'use_cache' => false]);
            } catch (Throwable) {
                return null;
            }
            $preco = Texto::numero($r['price'] ?? null);
            if (trim((string) ($r['title'] ?? '')) === '' || ! $preco || $preco <= 0) {
                return null;
            }
            $precos[] = $preco;
        }

        return abs($precos[0] - $precos[1]) <= max(0.01, $precos[0] * 0.01) ? $precos[0] : null;
    }

    /**
     * Nome da loja: og:site_name; senão o fim do título ("... | Medina
     * Distribuidora") quando bate com o domínio; senão o próprio domínio
     * ("zema.com" → "Zema").
     */
    public static function nome(Pagina $p, string $host): string
    {
        // Pula subdomínios genéricos: secure.livrariaunesp.com.br → livrariaunesp.
        $partes = explode('.', Listas::normalizarHost($host));
        $genericos = ['loja', 'lojas', 'secure', 'seguro', 'shop', 'store', 'm', 'mobile', 'compra', 'compras', 'checkout', 'app', 'site', 'br'];
        while (count($partes) > 2 && in_array($partes[0], $genericos, true)) {
            array_shift($partes);
        }
        $rotulo = $partes[0];
        $compacto = fn (string $s) => preg_replace('/[^a-z0-9]/', '', strtolower(Str::ascii($s)));

        $nome = trim((string) $p->meta('og:site_name'));
        if ($nome !== '' && mb_strlen($nome) <= 40 && ! str_contains($nome, '|')) {
            return $nome;
        }
        $pedacos = preg_split('/\s+[|–-]\s+/u', $p->titulo());
        $fim = trim((string) end($pedacos));
        $c = $compacto($fim);
        if (count($pedacos) > 1 && mb_strlen($fim) >= 3 && mb_strlen($fim) <= 40 && $c !== ''
            && (str_contains($compacto($rotulo), $c) || str_contains($c, $compacto($rotulo)))) {
            return $fim;
        }

        return ucfirst($rotulo);
    }

    protected function recusar(string $host, string $url, string $motivo): ?Store
    {
        DB::table(self::TABELA)->updateOrInsert(['host' => $host], [
            'status' => 'recusada', 'motivo' => Str::limit($motivo, 250, ''), 'url_teste' => $url, 'atualizado_em' => now(),
        ]);
        ($this->log)("  loja nova {$host}: recusada ({$motivo})");

        return null;
    }

    /**
     * Testa as lojas automáticas não verificadas há um dia (no máximo $limite).
     * Tenta a URL de teste e, se falhar, outra URL da loja; 3 dias seguidos sem
     * preço desativam a loja.
     */
    public function verificar(int $limite = 5): void
    {
        $lojas = DB::table(self::TABELA)->where('status', 'ativa')
            ->where(fn ($q) => $q->whereNull('verificada_em')->orWhere('verificada_em', '<', now()->subDay()))
            ->orderBy('verificada_em')->limit($limite)->get();

        foreach ($lojas as $l) {
            $loja = Store::find($l->store_id);
            if (! $loja) {
                DB::table(self::TABELA)->where('host', $l->host)->update(['status' => 'desativada', 'motivo' => 'loja apagada à mão', 'atualizado_em' => now()]);

                continue;
            }
            $urls = array_values(array_unique(array_filter([
                $l->url_teste,
                Url::query()->where('store_id', $loja->getKey())->latest('id')->value('url'),
            ])));
            $ok = false;
            foreach ($urls as $u) {
                try {
                    $r = ScrapeUrl::new($u)->setMaxAttempts(1)->scrape(['store' => $loja, 'use_cache' => false]);
                    if (Texto::numero($r['price'] ?? null)) {
                        $ok = true;
                        break;
                    }
                } catch (Throwable) {
                    // Próxima URL.
                }
            }

            if ($ok) {
                DB::table(self::TABELA)->where('host', $l->host)->update(['falhas' => 0, 'verificada_em' => now()]);

                continue;
            }
            $falhas = $l->falhas + 1;
            DB::table(self::TABELA)->where('host', $l->host)->update(['falhas' => $falhas, 'verificada_em' => now()]);
            ($this->log)("Loja automática {$loja->name}: sem preço ({$falhas}/".self::FALHAS_PARA_DESATIVAR.')');
            if ($falhas >= self::FALHAS_PARA_DESATIVAR) {
                $this->desativar($l->host, $loja, self::FALHAS_PARA_DESATIVAR.' dias seguidos sem preço');
            }
        }
    }

    /** Para de usar a loja e tira dos produtos as URLs que o buscador pôs nela. */
    public function desativar(string $host, Store $loja, string $motivo): void
    {
        $doBuscador = [];
        foreach (DB::table('baratinho_buscas')->pluck('adicionadas') as $json) {
            foreach ((array) json_decode((string) $json, true) as $u) {
                $doBuscador[$u] = true;
            }
        }
        $tiradas = 0;
        foreach (Url::query()->where('store_id', $loja->getKey())->get() as $url) {
            if (isset($doBuscador[$url->url]) || isset($doBuscador[Texto::semRastreio($url->url)])) {
                $url->delete();
                $tiradas++;
            }
        }
        $loja->notes = trim((string) $loja->notes."\nDesativada pelo Baratinho em ".now()->format('d/m/Y').": {$motivo}.");
        $loja->save();
        DB::table(self::TABELA)->where('host', $host)->update(['status' => 'desativada', 'motivo' => $motivo, 'atualizado_em' => now()]);
        ($this->log)("Loja automática {$loja->name} desativada ({$motivo}); {$tiradas} URL(s) tirada(s) dos produtos.");
    }
}
