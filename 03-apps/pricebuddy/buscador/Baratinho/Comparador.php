<?php

namespace App\Baratinho;

/**
 * Decide se um anúncio é o mesmo produto do original: 'sim', 'nao' ou 'duvida'
 * (vai para a IA). Ordem: identificadores (ISBN, EAN, código do fabricante),
 * depois recusas certas (preço, usado, quantidade, modelo, medida) e por fim a
 * semelhança do título. Recusa certa nunca vai para a IA.
 *
 * Cada anúncio é um array: titulo, preco, loja, isbn, gtins, mpn, nao_novo.
 */
class Comparador
{
    /** @return array{0: string, 1: string} */
    public static function decidir(array $orig, array $cand): array
    {
        $tituloC = trim((string) ($cand['titulo'] ?? ''));
        $precoC = $cand['preco'] ?? null;
        $precoR = (float) ($orig['preco'] ?? 0);

        if ($tituloC === '' || ! $precoC) {
            return ['nao', 'sem título ou preço'];
        }
        if ($precoR > 0 && ($precoC < $precoR * 0.3 || $precoC > $precoR * 3)) {
            return ['nao', sprintf('preço fora da faixa (R$ %.2f contra R$ %.2f)', $precoC, $precoR)];
        }
        if (! empty($cand['nao_novo']) && empty($orig['nao_novo'])) {
            return ['nao', 'usado, recondicionado ou vitrine'];
        }

        // Livro: só o ISBN decide.
        if (! empty($orig['isbn'])) {
            return ! empty($cand['isbn_na_pagina'])
                ? ['sim', sprintf('mesmo ISBN, R$ %.2f', $precoC)]
                : ['nao', 'ISBN diferente ou ausente'];
        }

        // EAN: igual é o mesmo produto; diferente nos dois lados, outro produto
        // (outra versão, cor com código próprio ou kit).
        $ga = (array) ($orig['gtins'] ?? []);
        $gb = (array) ($cand['gtins'] ?? []);
        if ($ga && $gb) {
            return array_intersect($ga, $gb)
                ? ['sim', sprintf('mesmo EAN, R$ %.2f', $precoC)]
                : ['nao', 'EAN diferente'];
        }

        $qa = Texto::quantidade((string) ($orig['titulo'] ?? ''));
        $qb = Texto::quantidade($tituloC);
        if ($qa !== $qb) {
            return ['nao', "quantidade diferente ({$qa} x {$qb})"];
        }

        $a = Texto::palavras((string) ($orig['titulo'] ?? ''));
        $b = array_values(array_diff(Texto::palavras($tituloC), Texto::palavras((string) ($cand['loja'] ?? ''))));
        if (! $a || ! $b) {
            return ['nao', 'título vazio'];
        }

        // Números de modelo (rtx 5060, sa400s37): os do original precisam aparecer.
        $modeloA = array_filter($a, fn ($p) => preg_match('/\d/', $p) && ! Texto::unidade($p));
        $modeloB = array_filter($b, fn ($p) => preg_match('/\d/', $p) && ! Texto::unidade($p));
        if ($modeloA && $modeloB && ! array_intersect($modeloA, $modeloB)) {
            return ['nao', 'modelo diferente'];
        }

        // Medidas (240gb x 480gb, 110v x 220v): mesma unidade sem valor em comum = outro produto.
        $ua = Texto::medidas($a);
        $ub = Texto::medidas($b);
        foreach ($ua as $u => $valores) {
            if (isset($ub[$u]) && ! array_intersect($valores, $ub[$u])) {
                return ['nao', "medida diferente ({$u})"];
            }
        }

        // Mesmo código do fabricante e nada em conflito: é o mesmo.
        if (! empty($orig['mpn']) && ! empty($cand['mpn']) && $orig['mpn'] === $cand['mpn']) {
            return ['sim', sprintf('mesmo código do fabricante (%s), R$ %.2f', $orig['mpn'], $precoC)];
        }

        $comuns = count(array_intersect($a, $b));
        $semelhanca = $comuns / min(count($a), count($b));
        $faltaModelo = $modeloA && ! $modeloB;

        if ($semelhanca >= 0.6 && $comuns >= 3 && ! $faltaModelo) {
            return ['sim', sprintf('título %.0f%% igual, R$ %.2f', $semelhanca * 100, $precoC)];
        }
        if ($comuns < 2) {
            return ['nao', "só {$comuns} palavra(s) em comum"];
        }
        if ($semelhanca >= 0.35) {
            return ['duvida', sprintf('título %.0f%% igual%s', $semelhanca * 100, $faltaModelo ? ', sem o modelo' : '')];
        }

        return ['nao', sprintf('título diferente (%.0f%%)', $semelhanca * 100)];
    }
}
