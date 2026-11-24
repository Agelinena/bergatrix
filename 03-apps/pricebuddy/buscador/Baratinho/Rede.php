<?php

namespace App\Baratinho;

use Illuminate\Support\Facades\Http;
use Throwable;

/** Leitura de páginas da internet pelo proxy de saída, ou pelo navegador do scraper. */
class Rede
{
    public const NAVEGADOR = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

    /**
     * Baixa uma página. Pela leitura simples (proxy de saída) e, se o site recusar
     * ou com $navegador, pelo navegador do scraper (sites que exigem JavaScript).
     *
     * @return array{0: string, 1: string} HTML e o serviço que funcionou ('http' ou 'api')
     */
    public static function baixar(string $url, bool $navegador = false): array
    {
        if (! $navegador) {
            $proxy = env('HTTPS_PROXY');
            try {
                $r = Http::timeout(25)
                    ->withOptions($proxy ? ['proxy' => ['http' => $proxy, 'https' => $proxy]] : [])
                    ->withHeaders(['User-Agent' => self::NAVEGADOR, 'Accept-Language' => 'pt-BR,pt;q=0.9'])
                    ->get($url);
                if ($r->successful() && strlen($r->body()) > 2000) {
                    return [$r->body(), 'http'];
                }
            } catch (Throwable) {
                // Tenta pelo navegador abaixo.
            }
        }

        $r = Http::timeout(90)->get(rtrim((string) env('SCRAPER_BASE_URL', 'http://scraper:3000'), '/').'/api/article', [
            'url' => $url, 'full-content' => 'true', 'cache' => 'false',
        ]);
        $html = (string) $r->json('fullContent');
        if (! $r->successful() || $html === '') {
            throw new \RuntimeException('HTTP '.$r->status());
        }

        return [$html, 'api'];
    }

    /**
     * Página pronta para analisar: pela leitura simples e, se vier bloqueio, quase
     * vazia ou sem sinal de loja, de novo pelo navegador.
     *
     * @return array{0: Pagina, 1: string} a página e o serviço que a trouxe
     */
    public static function pagina(string $url): array
    {
        [$html, $servico] = self::baixar($url);
        $p = new Pagina($url, $html);
        if ($servico === 'http' && ($p->bloqueio() || ! $p->sinaisDeLoja())) {
            try {
                [$html2] = self::baixar($url, true);
                $p2 = new Pagina($url, $html2);
                if (! $p2->bloqueio() && (count($p2->sinaisDeLoja()) > count($p->sinaisDeLoja()) || $p->bloqueio())) {
                    return [$p2, 'api'];
                }
            } catch (Throwable) {
                // Fica com a leitura simples.
            }
        }

        return [$p, $servico];
    }
}
