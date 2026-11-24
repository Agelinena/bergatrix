<?php

namespace App\Baratinho;

use Illuminate\Support\Str;

/** Normalização de títulos, medidas, quantidades, preços e endereços. */
class Texto
{
    /** Palavras que não ajudam a comparar títulos. */
    public const VAZIAS = [
        'de', 'da', 'do', 'das', 'dos', 'e', 'a', 'o', 'as', 'os', 'em', 'com', 'para', 'por', 'um', 'uma', 'no', 'na',
        'the', 'and', 'of', 'for', 'with', 'kit', 'novo', 'nova', 'original', 'oficial', 'frete', 'gratis', 'cor',
        'amazon', 'br', 'com', 'loja', 'comprar', 'compre', 'oferta', 'promocao', 'preco', 'livro', 'livros', 'edicao',
    ];

    /** Unidades de capacidade, tamanho e potência: valores diferentes = produtos diferentes. */
    public const UNIDADES = 'gb|tb|mb|ml|l|kg|g|t|mg|mm|cm|m|w|v|hz|mah|pol|polegadas|pcs|un|unidades|lugares|pessoas';

    /** Palavras de produto que não é novo. */
    protected const NAO_NOVO = '/\b(usad[oa]s?|semi-?nov[oa]s?|recondicionad[oa]s?|refurbished|renewed|vitrine|mostru[aá]rio|open\s*box|avariad[oa]|com\s+defeito|reembalad[oa])\b/iu';

    public static function limparTitulo(string $titulo): string
    {
        $titulo = preg_replace('/\s*[|–-]\s*(Amazon\.com\.br|Amazon|Magazine Luiza|Americanas|KaBuM!?|Mercado Livre).*$/iu', '', $titulo);

        return Str::limit(trim(preg_replace('/\s+/', ' ', $titulo)), 120, '');
    }

    /** As primeiras palavras que importam, para buscas curtas (site:loja ...). */
    public static function tituloCurto(string $titulo, int $max = 8): string
    {
        $partes = preg_split('/\s+/', self::limparTitulo($titulo), -1, PREG_SPLIT_NO_EMPTY);

        return implode(' ', array_slice($partes, 0, $max));
    }

    /** @return array<int, string> */
    public static function palavras(string $texto): array
    {
        $texto = strtolower(Str::ascii($texto));
        // "240 GB" e "240GB" viram a mesma palavra.
        $texto = preg_replace('/(\d)\s+('.self::UNIDADES.')\b/', '$1$2', $texto);
        // Apelidos: 240G = 240GB, 2T = 2TB, 55" = 55 polegadas.
        $texto = preg_replace(['/(\d)gb\b/', '/(\d)tb\b/', '/(\d)(?:polegadas|")/', '/(\d)unidades\b/'], ['$1g', '$1t', '$1pol', '$1un'], $texto);
        // 110 V e 127 V são a mesma tomada no Brasil.
        $texto = preg_replace('/\b(?:110|115|120)v\b/', '127v', $texto);
        $partes = preg_split('/[^a-z0-9]+/', $texto, -1, PREG_SPLIT_NO_EMPTY);

        return array_values(array_unique(array_filter(
            $partes,
            fn ($p) => strlen($p) >= 2 && ! in_array($p, self::VAZIAS, true)
        )));
    }

    /**
     * Códigos de modelo inteiros, sem hífen nem espaço: "AFN-40-BI" e "AFN40BI"
     * viram "afn40bi"; "RTX 5060" vira "rtx5060"; "SA400S37/240G" vira "sa400s37".
     *
     * @return array<int, string>
     */
    public static function codigos(string $titulo): array
    {
        $t = strtolower(Str::ascii($titulo));
        preg_match_all('/\b[a-z]{1,6}[- ]?\d{1,5}(?:[- ]?[a-z]{1,3}\d{0,3}\b|[a-z0-9]{0,4}\b)/', $t, $m);
        $out = [];
        foreach ($m[0] as $c) {
            $c = preg_replace('/[- ]/', '', $c);
            // Medida não é modelo (240gb, 127v, 4l).
            if (preg_match('/\d/', $c) && ! self::unidade($c) && ! preg_match('/^\d/', $c)) {
                $out[$c] = true;
            }
        }

        return array_keys($out);
    }

    public static function unidade(string $palavra): ?string
    {
        return preg_match('/^\d+(?:[.,]\d+)?('.self::UNIDADES.')$/', $palavra, $m) ? $m[1] : null;
    }

    /** @return array<string, array<int, string>> */
    public static function medidas(array $palavras): array
    {
        $out = [];
        foreach ($palavras as $p) {
            if ($u = self::unidade($p)) {
                $out[$u][] = $p;
            }
        }

        return $out;
    }

    /**
     * Quantas unidades o anúncio vende ("kit com 3", "pack 2", "4 unidades",
     * "caixa c/ 12"). Sem indicação: 1.
     */
    public static function quantidade(string $titulo): int
    {
        $t = strtolower(Str::ascii($titulo));
        $padroes = [
            '/\b(?:kit|pack|combo|caixa|cx|conjunto|jogo)\s*(?:com|c\/|de|c)?\s*(\d{1,3})\b/',
            '/\b(\d{1,3})\s*(?:unidades|unid|un|pecas|pcs|pares|rolos|latas|frascos)\b/',
        ];
        foreach ($padroes as $p) {
            if (preg_match($p, $t, $m) && (int) $m[1] > 1) {
                return (int) $m[1];
            }
        }

        return 1;
    }

    /** O título diz que não é produto novo (usado, recondicionado, vitrine...)? */
    public static function naoNovo(string $titulo): bool
    {
        return (bool) preg_match(self::NAO_NOVO, $titulo);
    }

    public static function numero(mixed $preco): ?float
    {
        if (is_numeric($preco)) {
            return (float) $preco;
        }
        $s = preg_replace('/[^0-9,.]/', '', (string) $preco);
        if ($s === '') {
            return null;
        }
        // Formato brasileiro (1.234,56) ou com ponto decimal (1234.56).
        if (str_contains($s, ',')) {
            $s = str_replace(['.', ','], ['', '.'], $s);
        }

        return is_numeric($s) ? (float) $s : null;
    }

    /** Tira parâmetros de rastreio, que mudam a cada busca. */
    public static function semRastreio(string $url): string
    {
        $partes = parse_url($url);
        if (! $partes || empty($partes['host'])) {
            return $url;
        }
        parse_str($partes['query'] ?? '', $q);
        $q = array_filter($q, fn ($k) => ! preg_match('/^(utm_|srsltid|gclid|fbclid|msockid|ref|tag|psc|smid|spm|scm)/i', (string) $k), ARRAY_FILTER_USE_KEY);

        return ($partes['scheme'] ?? 'https').'://'.$partes['host'].($partes['path'] ?? '/').($q ? '?'.http_build_query($q) : '');
    }
}
