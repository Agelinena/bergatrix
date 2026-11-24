<?php

namespace App\Baratinho;

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * O que cada site é: 'loja', 'noticia', 'comparador', 'outro' ou 'pendente'
 * (ainda não classificado). Tabela baratinho_dominios, por host (sem "www.").
 *
 * Entram como pendentes os sites que aparecem nas buscas e não são lojas
 * cadastradas; o buscador classifica alguns por rodada (regras da página e, na
 * dúvida, a IA). O filtro da pesquisa do app esconde os que não são loja.
 *
 * Correção à mão: docker exec pricebuddy-buscador php artisan baratinho:dominio <host> <tipo>
 */
class Dominios
{
    public const TABELA = 'baratinho_dominios';

    /** 'duvida': as regras não decidiram e a IA estava desligada; volta quando ela estiver no ar. */
    public const TIPOS = ['loja', 'noticia', 'comparador', 'outro', 'pendente', 'duvida'];

    /** Tentativas de leitura antes de desistir de um site que não abre. */
    protected const MAX_TENTATIVAS = 3;

    public static function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            // Coluna nova (fase 3): o produto em que o site apareceu por último.
            if (! Schema::hasColumn(self::TABELA, 'produto_id')) {
                Schema::table(self::TABELA, fn (Blueprint $t) => $t->unsignedBigInteger('produto_id')->nullable());
            }

            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->string('host')->primary();
            $t->string('tipo', 20)->index();
            $t->string('origem', 20)->nullable();
            $t->string('motivo')->nullable();
            $t->text('exemplo_url')->nullable();
            $t->integer('vezes')->default(1);
            $t->integer('tentativas')->default(0);
            $t->timestamp('visto_em')->nullable();
            $t->timestamp('decidido_em')->nullable();
            $t->unsignedBigInteger('produto_id')->nullable();
        });
    }

    /** Tipo conhecido do host (lista fixa ou decisão guardada), ou null. */
    public static function tipo(string $host): ?string
    {
        $host = Listas::normalizarHost($host);
        if ($fixo = Listas::tipoFixo($host)) {
            return $fixo;
        }
        $tipo = DB::table(self::TABELA)->where('host', $host)->value('tipo');

        return $tipo && ! in_array($tipo, ['pendente', 'duvida'], true) ? $tipo : null;
    }

    /**
     * Anota um site desconhecido para classificar depois (ou conta mais uma
     * aparição). Com o produto, a loja nova (se o site for loja) já é testada nele.
     */
    public static function anotar(string $host, string $url, ?int $produtoId = null): void
    {
        $host = Listas::normalizarHost($host);
        if ($host === '' || Listas::tipoFixo($host)) {
            return;
        }
        $agora = now();
        $n = DB::table(self::TABELA)->where('host', $host)->increment('vezes', 1, ['visto_em' => $agora]);
        // Ainda sem decisão: o exemplo passa a ser o endereço mais recente (o
        // anterior pode ter sido uma página de erro ou de bloqueio).
        DB::table(self::TABELA)->where('host', $host)->whereIn('tipo', ['pendente', 'duvida'])
            ->update(array_filter(['exemplo_url' => $url, 'produto_id' => $produtoId]));
        if (! $n) {
            DB::table(self::TABELA)->insertOrIgnore([
                'host' => $host, 'tipo' => 'pendente', 'exemplo_url' => $url, 'vezes' => 1, 'visto_em' => $agora,
                'produto_id' => $produtoId,
            ]);
        }
    }

    public static function decidir(string $host, string $tipo, string $origem, string $motivo): void
    {
        DB::table(self::TABELA)->updateOrInsert(
            ['host' => Listas::normalizarHost($host)],
            ['tipo' => $tipo, 'origem' => $origem, 'motivo' => Str::limit($motivo, 250, ''), 'decidido_em' => now()]
        );
    }

    /** Pendentes mais vistos primeiro (e os em dúvida, quando a IA está no ar). */
    public static function pendentes(int $limite, bool $comIa = false): \Illuminate\Support\Collection
    {
        return DB::table(self::TABELA)
            ->whereIn('tipo', $comIa ? ['pendente', 'duvida'] : ['pendente'])
            ->where('tentativas', '<', self::MAX_TENTATIVAS)
            ->orderByDesc('vezes')
            ->limit($limite)
            ->get();
    }

    /** Uma tentativa falhou (site não abriu); na última, desiste como 'outro'. */
    public static function falhou(string $host, string $erro): void
    {
        $host = Listas::normalizarHost($host);
        DB::table(self::TABELA)->where('host', $host)->increment('tentativas');
        $t = (int) DB::table(self::TABELA)->where('host', $host)->value('tentativas');
        if ($t >= self::MAX_TENTATIVAS) {
            self::decidir($host, 'outro', 'erro', 'não abriu: '.$erro);
        }
    }
}
