<?php

namespace App\Baratinho;

use App\Models\Product;
use App\Models\User;
use App\Services\Insights\ProductInsights;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Throwable;

/**
 * Ofertas de verdade x desconto de fachada, a partir do histórico que o
 * PriceBuddy já guarda (série diária do menor preço entre as lojas do produto,
 * por unidade quando o produto usa preço por unidade).
 *
 *   - menor preço em 90 dias: o preço de hoje é o menor da janela (com pelo
 *     menos 14 dias de histórico, senão qualquer preço novo seria "o menor");
 *   - caiu de verdade: caiu 5% ou mais em 7 dias e está abaixo da mediana de 90 dias;
 *   - desconto de fachada: caiu 5% ou mais em 7 dias, mas continua na mediana
 *     de 90 dias ou acima (subiu antes para "cair" depois, típico de Black Friday).
 */
class Ofertas
{
    public const QUEDA_MINIMA = 0.05;

    public const DIAS_MINIMOS = 14;

    /**
     * Análise pura de uma série diária ['AAAA-MM-DD' => preço], para testes.
     *
     * @return array{atual: float, min90: float, mediana90: float, preco7: ?float, queda7: float, dias: int, minimo: bool, caiu: bool, fachada: bool}|null
     */
    public static function analisarSerie(array $serie, ?Carbon $hoje = null): ?array
    {
        $hoje ??= now();
        ksort($serie);
        $janela = array_filter($serie, fn ($p, $d) => $p > 0 && Carbon::parse($d)->gte($hoje->copy()->subDays(90)->startOfDay()), ARRAY_FILTER_USE_BOTH);
        if (! $janela) {
            return null;
        }
        $datas = array_keys($janela);
        $atual = (float) end($janela);
        $valores = array_values($janela);
        $ordenados = $valores;
        sort($ordenados);
        $n = count($ordenados);
        $mediana = $n % 2 ? $ordenados[intdiv($n, 2)] : ($ordenados[$n / 2 - 1] + $ordenados[$n / 2]) / 2;

        // Preço de 7 dias atrás: o último dia com preço até essa data.
        $preco7 = null;
        foreach ($janela as $d => $p) {
            if (Carbon::parse($d)->lte($hoje->copy()->subDays(7)->endOfDay())) {
                $preco7 = (float) $p;
            }
        }
        $dias = Carbon::parse($datas[0])->diffInDays($hoje, true);
        $queda7 = $preco7 ? ($preco7 - $atual) / $preco7 : 0.0;
        $caiuNaSemana = $queda7 >= self::QUEDA_MINIMA;
        $fachada = $caiuNaSemana && $dias >= 21 && $atual >= $mediana * 0.98;

        return [
            'atual' => $atual,
            'min90' => (float) min($valores),
            'mediana90' => (float) $mediana,
            'preco7' => $preco7,
            'queda7' => $queda7,
            'dias' => (int) $dias,
            'minimo' => $dias >= self::DIAS_MINIMOS && $atual <= min($valores) + 0.005 && count(array_unique($valores)) > 1,
            'caiu' => $caiuNaSemana && ! $fachada,
            'fachada' => $fachada,
        ];
    }

    /** Análise de um produto, com a loja mais barata e o veredito do próprio PriceBuddy. */
    public static function analisar(Product $p): ?array
    {
        try {
            $ins = ProductInsights::for($p);
        } catch (Throwable) {
            return null;
        }
        $a = self::analisarSerie($ins->dailyBest->all());
        if (! $a) {
            return null;
        }

        return $a + [
            'produto' => $p,
            'loja' => $ins->bestStore,
            'veredito' => $ins->dealScore->lowConfidence ? null : $ins->dealScore->verdictKey,
        ];
    }

    /** Texto do e-mail de ofertas de uma pessoa, ou null se não há nada a contar. */
    public static function texto(User $u, Carbon $desde): ?string
    {
        $produtos = Product::query()->where('user_id', $u->getKey())->with('urls')->get();
        $analises = $produtos->map(fn (Product $p) => self::analisar($p))->filter();

        $minimos = $analises->filter(fn ($a) => $a['minimo'] && ! $a['fachada'])->sortBy('atual');
        $caiu = $analises->filter(fn ($a) => $a['caiu'] && ! $a['minimo'])->sortByDesc('queda7');
        $fachada = $analises->filter(fn ($a) => $a['fachada'])->sortByDesc('queda7');
        $novas = $produtos->map(fn (Product $p) => [$p, $p->urls->filter(fn ($url) => $url->created_at && $url->created_at->gte($desde))->count()])
            ->filter(fn ($x) => $x[1] > 0 && $x[0]->urls->count() > $x[1]);

        if ($minimos->isEmpty() && $caiu->isEmpty() && $fachada->isEmpty() && $novas->isEmpty()) {
            return null;
        }

        $base = rtrim((string) config('app.url'), '/');
        $link = fn (Product $p) => $base.'/admin/products/'.$p->getKey();
        $preco = fn (float $v) => 'R$ '.number_format($v, 2, ',', '.');
        $nome = fn (Product $p) => Str::limit((string) $p->title, 70);
        $l = ["Olá, {$u->name}! Ofertas dos seus produtos no Baratinho, de ".$desde->format('d/m').' a '.now()->format('d/m/Y').'.', ''];

        if ($minimos->isNotEmpty()) {
            $l[] = 'MENOR PREÇO DOS ÚLTIMOS 90 DIAS';
            foreach ($minimos as $a) {
                $l[] = '  * '.$nome($a['produto']).': '.$preco($a['atual']).($a['loja'] ? ' na '.$a['loja'] : '')
                    .($a['caiu'] ? sprintf(', -%.0f%% na semana', $a['queda7'] * 100) : '')
                    .' (mediana: '.$preco($a['mediana90']).')';
                $l[] = '    '.$link($a['produto']);
            }
            $l[] = '';
        }
        if ($caiu->isNotEmpty()) {
            $l[] = 'CAÍRAM NA SEMANA';
            foreach ($caiu as $a) {
                $l[] = sprintf('  * %s: %s → %s (-%.0f%%)%s', $nome($a['produto']), $preco($a['preco7']), $preco($a['atual']), $a['queda7'] * 100, $a['loja'] ? ' na '.$a['loja'] : '');
                $l[] = '    '.$link($a['produto']);
            }
            $l[] = '';
        }
        if ($fachada->isNotEmpty()) {
            $l[] = 'DESCONTO DE FACHADA (caiu na semana, mas não está barato)';
            foreach ($fachada as $a) {
                $l[] = sprintf('  ! %s: "-%.0f%%" para %s, mas a mediana de 90 dias é %s e o mínimo foi %s', $nome($a['produto']), $a['queda7'] * 100, $preco($a['atual']), $preco($a['mediana90']), $preco($a['min90']));
            }
            $l[] = '';
        }
        if ($novas->isNotEmpty()) {
            $l[] = 'LOJAS NOVAS NOS SEUS PRODUTOS';
            foreach ($novas as [$p, $n]) {
                $l[] = '  + '.$nome($p).": {$n} loja(s) a mais";
            }
            $l[] = '';
        }
        $l[] = 'Alertas por produto (preço-alvo, queda em %, volta ao estoque): no produto, em Notifications.';

        return implode("\n", $l);
    }
}
