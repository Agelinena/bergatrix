<?php

namespace App\Baratinho;

/** ISBN, EAN/GTIN e código do fabricante: com eles, o mesmo produto se reconhece sem adivinhar. */
class Identificadores
{
    /** ISBN-13 da página (dados estruturados, metadados ou o texto "ISBN"), conferido pelo dígito verificador. */
    public static function isbn(string $html): ?string
    {
        $achados = [];
        if (preg_match_all('/"isbn"\s*:\s*"([0-9Xx\- ]{10,20})"/', $html, $m)) {
            $achados = array_merge($achados, $m[1]);
        }
        if (preg_match_all('/(?:book:isbn|itemprop="isbn")[^>]*content="([0-9Xx\- ]{10,20})"/i', $html, $m)) {
            $achados = array_merge($achados, $m[1]);
        }
        $texto = html_entity_decode(strip_tags(preg_replace('/<(script|style)\b.*?<\/\1>/is', ' ', $html)));
        if (preg_match_all('/ISBN(?:-1[03])?\s*[:\x{A0} ]*\s*((?:97[89][\-\x{A0} ]?)?[0-9][0-9\-\x{A0} ]{8,15}[0-9Xx])/iu', $texto, $m)) {
            $achados = array_merge($achados, $m[1]);
        }

        foreach ($achados as $bruto) {
            if ($isbn = self::isbn13($bruto)) {
                return $isbn;
            }
        }

        return null;
    }

    public static function isbn13(string $bruto): ?string
    {
        $d = strtoupper(preg_replace('/[^0-9Xx]/', '', $bruto));
        if (strlen($d) === 10) {
            $d = '978'.substr($d, 0, 9);

            return $d.self::digitoGtin($d);
        }
        if (strlen($d) !== 13 || ! preg_match('/^97[89]\d{10}$/', $d)) {
            return null;
        }

        return self::digitoGtin(substr($d, 0, 12)) === (int) $d[12] ? $d : null;
    }

    /** A página tem o mesmo ISBN (13 ou 10 dígitos, com ou sem separadores)? */
    public static function temIsbn(string $html, string $isbn): bool
    {
        $isbn10 = substr($isbn, 0, 3) === '978' ? substr($isbn, 3, 9) : null;
        foreach (array_filter([$isbn, $isbn10]) as $alvo) {
            $padrao = '/(?<![0-9])'.implode('[\-\s.]?', str_split($alvo)).($alvo === $isbn10 ? '[\-\s.]?[0-9Xx]' : '').'(?![0-9])/';
            if (preg_match($padrao, $html)) {
                return true;
            }
        }

        return false;
    }

    /**
     * EAN/GTIN dos dados estruturados (gtin, gtin8/12/13/14, ean, "EAN" no texto
     * de especificações), normalizados para 14 dígitos. ISBN de livro fica de fora
     * (tem o próprio caminho).
     *
     * @return array<int, string>
     */
    public static function gtins(string $html, array $produto = []): array
    {
        $brutos = [];
        foreach (['gtin', 'gtin8', 'gtin12', 'gtin13', 'gtin14', 'ean', 'productID'] as $campo) {
            foreach ((array) ($produto[$campo] ?? []) as $v) {
                $brutos[] = (string) $v;
            }
        }
        if (preg_match_all('/"(?:gtin(?:8|12|13|14)?|ean)"\s*:\s*"?(\d{8,14})"?/i', $html, $m)) {
            $brutos = array_merge($brutos, $m[1]);
        }
        if (preg_match_all('/itemprop="gtin(?:8|12|13|14)?"[^>]*content="(\d{8,14})"/i', $html, $m)) {
            $brutos = array_merge($brutos, $m[1]);
        }
        $texto = html_entity_decode(strip_tags(preg_replace('/<(script|style)\b.*?<\/\1>/is', ' ', $html)));
        if (preg_match_all('/\b(?:EAN|GTIN|C[óo]digo\s+de\s+barras)(?:-1[34])?\s*[:\x{A0} ]\s*(\d{8,14})\b/iu', $texto, $m)) {
            $brutos = array_merge($brutos, $m[1]);
        }

        $ok = [];
        foreach ($brutos as $b) {
            $d = preg_replace('/\D/', '', $b);
            if (! in_array(strlen($d), [8, 12, 13, 14], true) || preg_match('/^0+$/', $d)) {
                continue;
            }
            $d = str_pad($d, 14, '0', STR_PAD_LEFT);
            if (self::digitoGtin(substr($d, 0, 13)) !== (int) $d[13] || preg_match('/^0{0,1}97[89]/', $d)) {
                continue;
            }
            $ok[$d] = true;
        }

        return array_keys($ok);
    }

    /** Código do fabricante (mpn/sku de modelo), em maiúsculas e sem separadores. */
    public static function mpn(array $produto): ?string
    {
        $v = $produto['mpn'] ?? null;
        if (is_array($v)) {
            $v = reset($v);
        }
        $v = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) $v));

        // Curto demais ou só números pequenos: não identifica nada.
        return strlen($v) >= 4 && preg_match('/[0-9]/', $v) ? $v : null;
    }

    /** Dígito verificador GTIN (módulo 10, pesos 3 e 1 da direita para a esquerda). */
    public static function digitoGtin(string $semDigito): int
    {
        $soma = 0;
        $n = strlen($semDigito);
        for ($i = 0; $i < $n; $i++) {
            $peso = (($n - $i) % 2 === 1) ? 3 : 1;
            $soma += (int) $semDigito[$i] * $peso;
        }

        return (10 - $soma % 10) % 10;
    }
}
