<?php

namespace App\Baratinho;

/**
 * Listas fixas do Baratinho: domínios que nunca são loja e endereços que são
 * listagem (busca, categoria), não página de produto.
 *
 * Sem dependência do Laravel: o filtro da pesquisa (buscador/filtro.php) usa
 * este arquivo direto, sem subir o app inteiro.
 */
class Listas
{
    /**
     * Domínios (e os subdomínios deles) que nunca são loja, por tipo. As decisões
     * do buscador (tabela baratinho_dominios) completam esta lista sozinhas.
     */
    public const NAO_LOJAS = [
        'noticia' => [
            'globo.com', 'uol.com.br', 'folha.uol.com.br', 'estadao.com.br', 'terra.com.br', 'r7.com',
            'cnnbrasil.com.br', 'metropoles.com', 'correiobraziliense.com.br', 'oglobo.globo.com', 'band.uol.com.br',
            'exame.com', 'infomoney.com.br', 'istoe.com.br', 'veja.abril.com.br', 'abril.com.br', 'gazetadopovo.com.br',
            'em.com.br', 'otempo.com.br', 'jornaldocommercio.com.br', 'poder360.com.br', 'sbt.com.br', 'ndmais.com.br',
            'tecmundo.com.br', 'tecnoblog.net', 'olhardigital.com.br', 'canaltech.com.br', 'techtudo.com.br',
            'tudocelular.com', 'mobiletime.com.br', 'adrenaline.com.br', 'hardware.com.br', 'showmetech.com.br',
            'oficinadanet.com.br', 'mundoconectado.com.br', 'macmagazine.com.br', 'gizmodo.uol.com.br', 'theverge.com',
            'engadget.com', 'cnet.com', 'techradar.com', 'tomsguide.com', 'tomshardware.com', 'pcmag.com', 'rtings.com',
            'ign.com', 'jovemnerd.com.br', 'omelete.com.br', 'legiaodosherois.com.br', 'meups.com.br', 'voxel.com.br',
            'blogspot.com', 'wordpress.com', 'medium.com', 'substack.com', 'tumblr.com',
        ],
        'comparador' => [
            'zoom.com.br', 'buscape.com.br', 'jacotei.com.br', 'bondfaro.com.br', 'promobit.com.br', 'pelando.com.br',
            'gatry.com', 'cuponomia.com.br', 'meliuz.com.br', 'mercadolivre.com.br/ofertas', 'google.com',
            'shopping.google.com', 'bing.com', 'idealo.com', 'pricespy.co.uk', 'camelcamelcamel.com', 'keepa.com',
        ],
        'outro' => [
            'youtube.com', 'youtu.be', 'facebook.com', 'instagram.com', 'tiktok.com', 'x.com', 'twitter.com',
            'threads.net', 'reddit.com', 'pinterest.com', 'pinterest.com.br', 'linkedin.com', 'quora.com',
            'wikipedia.org', 'wikiwand.com', 'reclameaqui.com.br', 'consumidor.gov.br', 'skoob.com.br', 'goodreads.com',
            'boardgamegeek.com', 'ludopedia.com.br', 'github.com', 'stackoverflow.com', 'gov.br', 'jusbrasil.com.br',
            'scribd.com', 'slideshare.net', 'issuu.com', 'archive.org', 'whatsapp.com', 't.me', 'telegram.me',
            'forum.adrenaline.com.br', 'clubedohardware.com.br', 'apps.apple.com', 'play.google.com',
            // Classificados e usados.
            'olx.com.br', 'enjoei.com.br', 'webmotors.com.br', 'mobiauto.com.br', 'icarros.com.br', 'zapimoveis.com.br',
            // Referência, resumos e cinema.
            'imdb.com', 'britannica.com', 'gutenberg.org', 'gutenberg.net.au', 'culturagenial.com', 'todamateria.com.br',
            'significados.com.br', 'mundoeducacao.uol.com.br', 'resumocompleto.com.br', 'livrosdominiopublico.com.br',
            'adorocinema.com', 'filmow.com', 'letterboxd.com', 'rottentomatoes.com',
            // Acadêmico.
            'researchgate.net', 'scispace.com', 'academia.edu', 'scielo.br', 'scielo.org', 'scholar.google.com',
        ],
    ];

    /** Caminhos e parâmetros de listagem (busca, categoria, lista), que não são página de um produto. */
    protected const LISTAGEM = [
        '~/(busca|buscar|search|pesquisa|resultado|s)(/|\?|$)~i',
        '~[?&](q|k|query|busca|search|termo|ft|keyword|keywords)=~i',
        '~/(categoria|categorias|category|categories|departamento|colecao|colecoes|collections?|marca|marcas|brand|tag|tags|lista|listas|ofertas|promocoes|promocao)(/|$)~i',
        '~/(c|cat|b)/[^/]+/?$~i',
        '~^/?$~',
        // Arquivos (manuais, catálogos, artigos), não página de produto.
        '~\.(pdf|docx?|xlsx?|pptx?|zip|rar|epub|mobi|mp4|mp3|jpe?g|png)(\?|$)~i',
    ];

    /** Tipo fixo do domínio ('noticia', 'comparador', 'outro') ou null quando não está na lista. */
    public static function tipoFixo(string $host): ?string
    {
        $host = self::normalizarHost($host);
        foreach (self::NAO_LOJAS as $tipo => $dominios) {
            foreach ($dominios as $dominio) {
                if (str_contains($dominio, '/')) {
                    continue;
                }
                if ($host === $dominio || str_ends_with($host, '.'.$dominio)) {
                    return $tipo;
                }
            }
        }

        return null;
    }

    /** O endereço é uma listagem (busca, categoria, página inicial) ou um arquivo, e não um produto? */
    public static function pareceListagem(string $url): bool
    {
        $caminho = (string) parse_url($url, PHP_URL_PATH);
        $consulta = (string) parse_url($url, PHP_URL_QUERY);
        $alvo = $caminho.($consulta !== '' ? '?'.$consulta : '');

        // Mercado Livre: lista.mercadolivre.com.br/<termo> é a busca.
        if (str_starts_with(self::normalizarHost((string) parse_url($url, PHP_URL_HOST)), 'lista.mercadolivre.')) {
            return true;
        }

        foreach (self::LISTAGEM as $padrao) {
            if (preg_match($padrao, $alvo)) {
                return true;
            }
        }

        // Categoria pelo jeito do caminho (/hardware/ssd, /livros/ficcao/classicos):
        // página de produto quase sempre tem um código (número) ou um nome longo.
        $partes = array_values(array_filter(explode('/', strtolower($caminho))));
        if ($partes && ! preg_match('/\d/', $caminho)
            && ! array_intersect($partes, ['p', 'dp', 'produto', 'produtos', 'product', 'products', 'item', 'itens', 'livro', 'prod', 'artigo'])) {
            $ultima = preg_replace('/\.(html?|aspx?|php)$/', '', end($partes));

            return count(preg_split('/[-_]+/', $ultima, -1, PREG_SPLIT_NO_EMPTY)) < 3;
        }

        return false;
    }

    public static function normalizarHost(string $host): string
    {
        $host = strtolower(trim($host, ". \t\n\r"));

        return str_starts_with($host, 'www.') ? substr($host, 4) : $host;
    }
}
