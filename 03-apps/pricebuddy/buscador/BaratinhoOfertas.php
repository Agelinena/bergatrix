<?php

namespace App\Console\Commands;

use App\Baratinho\Ofertas;
use App\Models\User;
use App\Services\Helpers\NotificationsHelper;
use Illuminate\Console\Command;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Schema;
use Throwable;

/**
 * E-mail de ofertas para cada pessoa, com os produtos dela: menor preço em 90
 * dias, o que caiu de verdade, desconto de fachada e lojas novas. Pelo SMTP do
 * app (Settings → Notifications → Email); quem não tem nada a contar não recebe.
 *
 *   php artisan baratinho:ofertas                     mostra o de cada pessoa, sem enviar
 *   php artisan baratinho:ofertas --usuario=email     só uma pessoa
 *   php artisan baratinho:ofertas --enviar            envia agora
 *   php artisan baratinho:ofertas --se-for-hora       envia se o último foi há
 *                                                      PRICEBUDDY_OFERTAS_DIAS dias (o laço chama assim)
 */
class BaratinhoOfertas extends Command
{
    protected $signature = 'baratinho:ofertas {--usuario=} {--enviar} {--se-for-hora}';

    protected $description = 'E-mail de ofertas de verdade x desconto de fachada, por pessoa';

    protected const ESTADO = 'baratinho_estado';

    public function handle(): int
    {
        $dias = max(1, (int) env('PRICEBUDDY_OFERTAS_DIAS', 7));
        if (! Schema::hasTable(self::ESTADO)) {
            Schema::create(self::ESTADO, function ($t) {
                $t->string('chave')->primary();
                $t->text('valor')->nullable();
            });
        }
        $ultimo = DB::table(self::ESTADO)->where('chave', 'ofertas_enviado_em')->value('valor');
        if ($this->option('se-for-hora')) {
            if (! $ultimo) {
                $this->marcar();

                return self::SUCCESS;
            }
            // Margem de uma hora: o laço roda a cada ~10 minutos.
            if (Carbon::parse($ultimo)->gt(now()->subDays($dias)->addHour())) {
                return self::SUCCESS;
            }
        }
        $enviar = $this->option('enviar') || $this->option('se-for-hora');
        if ($enviar && ! NotificationsHelper::isEnabled('mail')) {
            $this->warn('E-mail desligado em Settings → Notifications: ofertas não enviadas.');
            $this->marcar();

            return self::SUCCESS;
        }

        $desde = $ultimo && $this->option('se-for-hora') ? Carbon::parse($ultimo) : now()->subDays($dias);
        $usuarios = User::query()->when($this->option('usuario'), fn ($q, $e) => $q->where('email', $e))->get();
        $enviados = 0;
        foreach ($usuarios as $u) {
            $texto = Ofertas::texto($u, $desde);
            if (! $texto || ! $u->email) {
                continue;
            }
            if (! $enviar) {
                $this->line("=== {$u->email}\n{$texto}\n");

                continue;
            }
            try {
                Mail::raw($texto, fn ($m) => $m->to($u->email)->subject('Baratinho: ofertas dos seus produtos'));
                $enviados++;
            } catch (Throwable $e) {
                $this->warn("Ofertas para {$u->email}: {$e->getMessage()}");
            }
        }
        if ($enviar) {
            $this->line("Ofertas enviadas para {$enviados} pessoa(s).");
            $this->marcar();
        }

        return self::SUCCESS;
    }

    protected function marcar(): void
    {
        DB::table(self::ESTADO)->updateOrInsert(['chave' => 'ofertas_enviado_em'], ['valor' => now()->toIso8601String()]);
    }
}
