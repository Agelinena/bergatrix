<?php

namespace App\Baratinho;

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Ritmo por site: o buscador não dispara vários acessos seguidos à mesma loja,
 * que é o que faz as lojas pedirem verificação de robô.
 *
 *   - intervalo mínimo entre dois acessos ao mesmo site (PRICEBUDDY_RITMO_SEGUNDOS, 20);
 *   - teto de acessos por site por dia (PRICEBUDDY_RITMO_TETO_DIA, 150);
 *   - depois de um bloqueio, o site fica em pausa (PRICEBUDDY_RITMO_PAUSA_HORAS, 6).
 *
 * Vale só para o buscador; a atualização de preços do próprio PriceBuddy tem o
 * agendamento dela. Tabela baratinho_ritmo, por host.
 */
class Ritmo
{
    public const TABELA = 'baratinho_ritmo';

    /** Espera máxima numa chamada (s): acima disso, o site fica para depois. */
    protected const ESPERA_MAXIMA = 60;

    public static function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->string('host')->primary();
            $t->double('ultimo')->default(0);
            $t->date('dia')->nullable();
            $t->integer('acessos')->default(0);
            $t->timestamp('pausa_ate')->nullable();
            $t->integer('bloqueios')->default(0);
        });
    }

    /**
     * Pede licença para acessar o site da URL: espera o intervalo, se preciso.
     * Devolve null se pode, ou o motivo para não acessar agora (pausa, teto).
     */
    public static function licenca(string $url): ?string
    {
        $host = Listas::normalizarHost((string) parse_url($url, PHP_URL_HOST));
        if ($host === '') {
            return null;
        }
        $hoje = now()->toDateString();
        $r = DB::table(self::TABELA)->where('host', $host)->first();

        if ($r && $r->pausa_ate && now()->lt($r->pausa_ate)) {
            return 'site em pausa até '.substr((string) $r->pausa_ate, 11, 5).' (bloqueou antes)';
        }
        $acessos = $r && $r->dia === $hoje ? (int) $r->acessos : 0;
        $teto = (int) env('PRICEBUDDY_RITMO_TETO_DIA', 150);
        if ($teto > 0 && $acessos >= $teto) {
            return "teto de {$teto} acessos por dia neste site";
        }

        $intervalo = (float) env('PRICEBUDDY_RITMO_SEGUNDOS', 20);
        $espera = $r ? ($r->ultimo + $intervalo) - microtime(true) : 0;
        if ($espera > self::ESPERA_MAXIMA) {
            return 'site acessado há pouco';
        }
        if ($espera > 0) {
            usleep((int) ($espera * 1_000_000));
        }

        DB::table(self::TABELA)->updateOrInsert(['host' => $host], [
            'ultimo' => microtime(true), 'dia' => $hoje, 'acessos' => $acessos + 1,
        ]);

        return null;
    }

    /** O site pediu verificação de robô: pausa. */
    public static function bloqueou(string $url): void
    {
        $host = Listas::normalizarHost((string) parse_url($url, PHP_URL_HOST));
        if ($host === '') {
            return;
        }
        $horas = max(1, (int) env('PRICEBUDDY_RITMO_PAUSA_HORAS', 6));
        $atual = (int) DB::table(self::TABELA)->where('host', $host)->value('bloqueios');
        DB::table(self::TABELA)->updateOrInsert(['host' => $host], [
            'pausa_ate' => now()->addHours($horas), 'bloqueios' => $atual + 1,
        ]);
    }
}
