<?php

namespace App\Baratinho;

use App\Models\Store;
use App\Models\Url;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * Saúde das lojas cadastradas (todas, menos as automáticas, que LojasNovas testa
 * todo dia): uma vez por semana, cada loja lê a URL de teste dela (ou a URL mais
 * recente de um produto) com a própria configuração. Sem preço = a regra pode ter
 * quebrado (o site mudou). As quebradas vão para o resumo dos admins.
 *
 * Não desativa nada: loja cadastrada à mão (ou do lojas/brasil.php) é decisão de
 * quem cuida da stack. Tabela baratinho_saude, por loja.
 */
class Saude
{
    public const TABELA = 'baratinho_saude';

    protected const DIAS = 7;

    public static function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->unsignedBigInteger('store_id')->primary();
            $t->boolean('ok')->nullable();
            $t->string('motivo')->nullable();
            $t->text('url')->nullable();
            $t->integer('falhas')->default(0);
            $t->timestamp('testado_em')->nullable();
        });
    }

    /**
     * Testa até $limite lojas não testadas há uma semana. Devolve quantas
     * estão quebradas agora (depois dos testes desta rodada).
     */
    public static function verificar(int $limite, ?callable $log = null): int
    {
        $log ??= fn (string $m) => null;
        $automaticas = DB::table(LojasNovas::TABELA)->whereNotNull('store_id')->pluck('store_id')->all();
        $testadas = DB::table(self::TABELA)->where('testado_em', '>', now()->subDays(self::DIAS))->pluck('store_id')->all();
        $lojas = Store::query()->whereNotIn('id', array_merge($automaticas, $testadas, [0]))->orderBy('id')->limit(max(0, $limite))->get();

        foreach ($lojas as $loja) {
            $url = (string) (data_get($loja->settings, 'test_url') ?: Url::query()->where('store_id', $loja->getKey())->latest('id')->value('url'));
            if ($url === '') {
                self::anotar($loja, null, 'sem URL de teste nem produto', null);

                continue;
            }
            try {
                $r = Rede::ler($url, $loja);
            } catch (Throwable $e) {
                self::anotar($loja, false, 'erro: '.Str::limit($e->getMessage(), 120), $url);

                continue;
            }
            if (isset($r['ritmo'])) {
                // Fica para a próxima rodada.
                continue;
            }
            if (isset($r['bloqueio'])) {
                self::anotar($loja, null, 'pediu verificação de robô ('.$r['bloqueio'].')', $url);

                continue;
            }
            $preco = Texto::numero($r['price'] ?? null);
            $titulo = trim((string) ($r['title'] ?? ''));
            if ($preco && $titulo !== '') {
                self::anotar($loja, true, sprintf('R$ %.2f', $preco), $url);
            } else {
                self::anotar($loja, false, $titulo === '' ? 'sem título nem preço' : 'sem preço', $url);
                $log("Loja {$loja->name}: {$url} sem preço; a regra pode ter quebrado");
            }
        }

        return DB::table(self::TABELA)->where('ok', false)->count();
    }

    protected static function anotar(Store $loja, ?bool $ok, string $motivo, ?string $url): void
    {
        $falhas = (int) DB::table(self::TABELA)->where('store_id', $loja->getKey())->value('falhas');
        DB::table(self::TABELA)->updateOrInsert(['store_id' => $loja->getKey()], [
            'ok' => $ok, 'motivo' => Str::limit($motivo, 250, ''), 'url' => $url,
            'falhas' => $ok === false ? $falhas + 1 : ($ok ? 0 : $falhas), 'testado_em' => now(),
        ]);
    }
}
