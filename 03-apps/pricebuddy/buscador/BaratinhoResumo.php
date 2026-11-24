<?php

namespace App\Console\Commands;

use App\Baratinho\Dominios;
use App\Baratinho\Ia;
use App\Baratinho\LojasNovas;
use App\Enums\Role;
use App\Models\Store;
use App\Models\User;
use App\Services\Helpers\NotificationsHelper;
use Illuminate\Console\Command;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Schema;
use Throwable;

/**
 * Resumo semanal do buscador por e-mail, para os admins do PriceBuddy, pelo
 * mesmo SMTP do app (Settings → Notifications → Email).
 *
 *   php artisan baratinho:resumo                mostra o resumo dos últimos 7 dias
 *   php artisan baratinho:resumo --enviar       envia agora
 *   php artisan baratinho:resumo --se-for-hora  envia se o último foi há 7 dias ou mais
 *                                               (o laço do buscador chama assim)
 */
class BaratinhoResumo extends Command
{
    protected $signature = 'baratinho:resumo {--enviar} {--se-for-hora}';

    protected $description = 'Resumo semanal do buscador (lojas novas, desativadas, sites classificados)';

    protected const ESTADO = 'baratinho_estado';

    public function handle(): int
    {
        $this->garantirEstado();
        LojasNovas::garantirTabela();
        Dominios::garantirTabela();
        Ia::garantirTabela();

        $ultimo = DB::table(self::ESTADO)->where('chave', 'resumo_enviado_em')->value('valor');
        if ($this->option('se-for-hora')) {
            if (! $ultimo) {
                // Primeira vez: começa a contar a semana agora.
                $this->marcar();

                return self::SUCCESS;
            }
            if (Carbon::parse($ultimo)->gt(now()->subDays(7))) {
                return self::SUCCESS;
            }
        }

        $desde = now()->subDays(7);
        $texto = $this->montar($desde);

        if (! $this->option('enviar') && ! $this->option('se-for-hora')) {
            $this->line($texto);

            return self::SUCCESS;
        }

        if (! NotificationsHelper::isEnabled('mail')) {
            $this->warn('E-mail desligado em Settings → Notifications: resumo não enviado.');
            $this->marcar();

            return self::SUCCESS;
        }
        $para = User::query()->where('role', Role::Admin->value)->pluck('email')->filter()->all();
        if (! $para) {
            $this->warn('Nenhum admin com e-mail: resumo não enviado.');

            return self::SUCCESS;
        }
        try {
            Mail::raw($texto, fn ($m) => $m->to($para)->subject('Baratinho: resumo da semana'));
            $this->line('Resumo enviado para '.count($para).' admin(s).');
        } catch (Throwable $e) {
            $this->warn('Resumo não enviado: '.$e->getMessage());
        }
        $this->marcar();

        return self::SUCCESS;
    }

    protected function montar(Carbon $desde): string
    {
        $l = [];
        $l[] = 'Resumo do buscador do Baratinho, de '.$desde->format('d/m').' a '.now()->format('d/m/Y').'.';
        $l[] = '';

        $nomes = Store::query()->pluck('name', 'id');
        $criadas = DB::table(LojasNovas::TABELA)->where('status', 'ativa')->where('criada_em', '>=', $desde)->orderBy('criada_em')->get();
        $l[] = 'LOJAS NOVAS ('.$criadas->count().')';
        foreach ($criadas as $c) {
            $l[] = '  + '.($nomes[$c->store_id] ?? $c->host).' ('.$c->host.') - '.$c->url_teste;
        }
        if ($criadas->isEmpty()) {
            $l[] = '  nenhuma';
        }
        $l[] = '';

        $desativadas = DB::table(LojasNovas::TABELA)->where('status', 'desativada')->where('atualizado_em', '>=', $desde)->get();
        if ($desativadas->isNotEmpty()) {
            $l[] = 'LOJAS DESATIVADAS ('.$desativadas->count().') - consertar em Stores e reativar com baratinho:lojas reativar <site>';
            foreach ($desativadas as $d) {
                $l[] = '  - '.($nomes[$d->store_id] ?? $d->host).': '.$d->motivo;
            }
            $l[] = '';
        }

        $recusadas = DB::table(LojasNovas::TABELA)->where('status', 'recusada')->where('atualizado_em', '>=', $desde)->get();
        if ($recusadas->isNotEmpty()) {
            $l[] = 'LOJAS QUE NÃO DEU PARA CRIAR ('.$recusadas->count().') - dá para cadastrar à mão em Stores';
            foreach ($recusadas->take(15) as $r) {
                $l[] = '  ? '.$r->host.': '.$r->motivo;
            }
            $l[] = '';
        }

        $sites = DB::table(Dominios::TABELA)->where('decidido_em', '>=', $desde)
            ->selectRaw('tipo, count(*) as n')->groupBy('tipo')->pluck('n', 'tipo');
        $l[] = 'SITES CLASSIFICADOS: '.($sites->isEmpty() ? 'nenhum' : $sites->map(fn ($n, $t) => "{$t} {$n}")->implode(', '));
        $l[] = 'Pendentes na fila: '.DB::table(Dominios::TABELA)->whereIn('tipo', ['pendente', 'duvida'])->count();

        if (Schema::hasTable('baratinho_buscas')) {
            $l[] = 'Produtos procurados nas outras lojas: '.DB::table('baratinho_buscas')->where('buscado_em', '>=', $desde)->count();
        }
        $l[] = 'Perguntas à IA local: '.DB::table(Ia::TABELA)->where('criado_em', '>=', $desde)->count();
        $l[] = '';
        $l[] = 'Detalhes: docker exec pricebuddy-buscador php artisan baratinho:lojas (e baratinho:dominio).';

        return implode("\n", $l);
    }

    protected function marcar(): void
    {
        DB::table(self::ESTADO)->updateOrInsert(['chave' => 'resumo_enviado_em'], ['valor' => now()->toIso8601String()]);
    }

    protected function garantirEstado(): void
    {
        if (! Schema::hasTable(self::ESTADO)) {
            Schema::create(self::ESTADO, function ($t) {
                $t->string('chave')->primary();
                $t->text('valor')->nullable();
            });
        }
    }
}
