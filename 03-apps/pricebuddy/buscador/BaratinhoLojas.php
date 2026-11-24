<?php

namespace App\Console\Commands;

use App\Baratinho\Listas;
use App\Baratinho\LojasNovas;
use App\Models\Store;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Lojas criadas automaticamente pelo buscador.
 *
 *   php artisan baratinho:lojas                          lista (ativas, desativadas e recusadas)
 *   php artisan baratinho:lojas --status=recusada        só um status
 *   php artisan baratinho:lojas reativar exemplo.com.br  volta a usar (depois de consertar a loja)
 *   php artisan baratinho:lojas tentar exemplo.com.br    recusada: tenta criar de novo na próxima vez
 *   php artisan baratinho:lojas desativar exemplo.com.br não usa mais (site que não é loja de verdade)
 */
class BaratinhoLojas extends Command
{
    protected $signature = 'baratinho:lojas {acao?} {host?} {--status=} {--limite=50}';

    protected $description = 'Lista, reativa ou libera de novo as lojas criadas automaticamente';

    public function handle(): int
    {
        LojasNovas::garantirTabela();
        $acao = $this->argument('acao');
        $host = $this->argument('host') ? Listas::normalizarHost($this->argument('host')) : null;

        if ($acao) {
            $linha = $host ? DB::table(LojasNovas::TABELA)->where('host', $host)->first() : null;
            if (! $linha) {
                $this->error('Host não encontrado na lista de lojas automáticas.');

                return self::FAILURE;
            }
            if ($acao === 'reativar') {
                if (! $linha->store_id || ! Store::find($linha->store_id)) {
                    $this->error('Essa loja não existe mais no PriceBuddy.');

                    return self::FAILURE;
                }
                DB::table(LojasNovas::TABELA)->where('host', $host)->update(['status' => 'ativa', 'falhas' => 0, 'verificada_em' => null, 'motivo' => 'reativada à mão', 'atualizado_em' => now()]);
                $this->info("{$host} reativada; será testada na próxima rodada.");

                return self::SUCCESS;
            }
            if ($acao === 'tentar') {
                DB::table(LojasNovas::TABELA)->where('host', $host)->where('status', 'recusada')->delete();
                $this->info("{$host} liberada: o buscador tenta criar de novo quando o site aparecer.");

                return self::SUCCESS;
            }
            if ($acao === 'desativar') {
                $loja = $linha->store_id ? Store::find($linha->store_id) : null;
                if (! $loja) {
                    $this->error('Essa loja não existe mais no PriceBuddy.');

                    return self::FAILURE;
                }
                (new LojasNovas(fn (string $m) => $this->line($m)))->desativar($host, $loja, 'desativada à mão');

                return self::SUCCESS;
            }
            $this->error('Ação inválida: use reativar, tentar ou desativar.');

            return self::FAILURE;
        }

        $q = DB::table(LojasNovas::TABELA)->orderByDesc('atualizado_em')->limit((int) $this->option('limite'));
        if ($this->option('status')) {
            $q->where('status', $this->option('status'));
        }
        $nomes = Store::query()->pluck('name', 'id');
        $this->table(
            ['site', 'loja', 'status', 'falhas', 'quando', 'motivo'],
            $q->get()->map(fn ($l) => [
                $l->host, $nomes[$l->store_id] ?? '-', $l->status, $l->falhas,
                $l->atualizado_em ? substr((string) $l->atualizado_em, 0, 16) : '-', Str::limit((string) $l->motivo, 60),
            ])->all()
        );
        $this->line(DB::table(LojasNovas::TABELA)->selectRaw('status, count(*) as n')->groupBy('status')->pluck('n', 'status')
            ->map(fn ($n, $s) => "{$s}: {$n}")->implode('  '));

        return self::SUCCESS;
    }
}
