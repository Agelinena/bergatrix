<?php

namespace App\Console\Commands;

use App\Baratinho\Dominios;
use App\Baratinho\Listas;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Consulta e corrige o que o buscador decidiu sobre cada site.
 *
 *   php artisan baratinho:dominio                    lista as decisões (mais vistos primeiro)
 *   php artisan baratinho:dominio --tipo=noticia     só um tipo
 *   php artisan baratinho:dominio exemplo.com.br loja    corrige (origem "manual", não é refeito)
 *   php artisan baratinho:dominio exemplo.com.br pendente    manda classificar de novo
 */
class BaratinhoDominio extends Command
{
    protected $signature = 'baratinho:dominio {host?} {tipo?} {--tipo= : Lista só este tipo} {--limite=40}';

    protected $description = 'Lista e corrige a classificação dos sites (loja, notícia, comparador, outro)';

    public function handle(): int
    {
        Dominios::garantirTabela();
        $host = $this->argument('host');
        $tipo = $this->argument('tipo');

        if ($host && $tipo) {
            if (! in_array($tipo, Dominios::TIPOS, true)) {
                $this->error('Tipo inválido. Use: '.implode(', ', Dominios::TIPOS));

                return self::FAILURE;
            }
            if ($fixo = Listas::tipoFixo($host)) {
                $this->warn("{$host} está na lista fixa como {$fixo} (buscador/Baratinho/Listas.php); a lista fixa vale antes.");
            }
            Dominios::decidir($host, $tipo, 'manual', 'corrigido à mão');
            if ($tipo === 'pendente') {
                DB::table(Dominios::TABELA)->where('host', Listas::normalizarHost($host))->update(['tentativas' => 0]);
            }
            $this->info(Listas::normalizarHost($host)." agora é {$tipo}.");

            return self::SUCCESS;
        }

        $q = DB::table(Dominios::TABELA)->orderByDesc('vezes')->limit((int) $this->option('limite'));
        if ($host) {
            $q->where('host', 'like', '%'.Listas::normalizarHost($host).'%');
        }
        if ($this->option('tipo')) {
            $q->where('tipo', $this->option('tipo'));
        }
        $this->table(
            ['site', 'tipo', 'por', 'vezes', 'motivo'],
            $q->get()->map(fn ($d) => [$d->host, $d->tipo, $d->origem ?? '-', $d->vezes, Str::limit((string) $d->motivo, 70)])->all()
        );
        $contagem = DB::table(Dominios::TABELA)->selectRaw('tipo, count(*) as n')->groupBy('tipo')->pluck('n', 'tipo');
        $this->line($contagem->map(fn ($n, $t) => "{$t}: {$n}")->implode('  '));

        return self::SUCCESS;
    }
}
