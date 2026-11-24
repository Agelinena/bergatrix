<?php

namespace App\Baratinho;

use Illuminate\Support\Str;

/**
 * Leitura de uma página: dados estruturados (JSON-LD), metadados e sinais de
 * loja ou de notícia. Decide, sem IA, se é anúncio de loja, notícia/blog ou
 * caso de dúvida (que vai para a IA).
 */
class Pagina
{
    protected array $nos;

    protected array $tipos;

    public function __construct(public readonly string $url, public readonly string $html)
    {
        $this->nos = $this->lerJsonLd();
        $this->tipos = array_values(array_unique(array_merge(...array_map(
            fn ($n) => array_map('strval', (array) ($n['@type'] ?? [])),
            $this->nos ?: [[]]
        ))));
    }

    /** O primeiro nó Product/Book/... dos dados estruturados (com a oferta dentro, se houver). */
    public function produto(): array
    {
        foreach ($this->nos as $n) {
            if (array_intersect((array) ($n['@type'] ?? []), ['Product', 'Book', 'IndividualProduct', 'ProductModel', 'ProductGroup', 'Vehicle', 'SoftwareApplication', 'VideoGame'])) {
                return $n;
            }
        }

        return [];
    }

    /** A oferta do produto: preço, moeda, disponibilidade, condição. */
    public function oferta(): array
    {
        $p = $this->produto();
        $ofertas = $p['offers'] ?? null;
        if (! $ofertas) {
            foreach ($this->nos as $n) {
                if (array_intersect((array) ($n['@type'] ?? []), ['Offer', 'AggregateOffer'])) {
                    $ofertas = $n;
                    break;
                }
            }
        }
        if (is_array($ofertas) && array_is_list($ofertas)) {
            $ofertas = $ofertas[0] ?? [];
        }
        $o = (array) $ofertas;
        $preco = $o['price'] ?? $o['lowPrice'] ?? data_get($o, 'priceSpecification.price');

        return [
            'preco' => Texto::numero($preco),
            'moeda' => strtoupper((string) ($o['priceCurrency'] ?? data_get($o, 'priceSpecification.priceCurrency') ?? '')),
            'disponivel' => ! preg_match('/(OutOfStock|SoldOut|Discontinued)$/i', (string) ($o['availability'] ?? '')),
            'condicao' => (string) ($o['itemCondition'] ?? $p['itemCondition'] ?? ''),
        ];
    }

    public function tipos(): array
    {
        return $this->tipos;
    }

    public function titulo(): string
    {
        $t = $this->meta('og:title') ?: (preg_match('/<title[^>]*>(.*?)<\/title>/is', $this->html, $m) ? $m[1] : '');

        return trim(html_entity_decode(strip_tags((string) $t), ENT_QUOTES | ENT_HTML5));
    }

    public function meta(string $nome): ?string
    {
        $q = preg_quote($nome, '/');
        if (preg_match('/<meta[^>]+(?:property|name|itemprop)=["\']'.$q.'["\'][^>]*content=["\']([^"\']*)["\']/i', $this->html, $m)
            || preg_match('/<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name|itemprop)=["\']'.$q.'["\']/i', $this->html, $m)) {
            return html_entity_decode($m[1], ENT_QUOTES | ENT_HTML5);
        }

        return null;
    }

    /** Texto visível, sem scripts e estilos, para a IA (resumido). */
    public function texto(int $max = 1500): string
    {
        // preg_replace devolve null em página enorme ou com UTF-8 inválido: aí fica com o original.
        $h = preg_replace('/<(script|style|noscript|svg|nav|footer|header)\b.*?<\/\1>/is', ' ', $this->html) ?? $this->html;
        $t = html_entity_decode(strip_tags($h), ENT_QUOTES | ENT_HTML5);
        $t = preg_replace('/\s+/u', ' ', $t) ?? preg_replace('/\s+/', ' ', $t) ?? $t;

        return Str::limit(trim($t), $max, '…');
    }

    public function isbn(): ?string
    {
        return Identificadores::isbn($this->html);
    }

    public function gtins(): array
    {
        return Identificadores::gtins($this->html, $this->produto());
    }

    public function mpn(): ?string
    {
        return Identificadores::mpn($this->produto());
    }

    /** Usado, recondicionado ou danificado, pelos dados estruturados ou pelo título. */
    public function naoNovo(): bool
    {
        $c = $this->oferta()['condicao'];

        return (bool) preg_match('/(Used|Refurbished|Damaged)Condition$/i', $c) || Texto::naoNovo($this->titulo());
    }

    public function temCarrinho(): bool
    {
        return (bool) preg_match('/(adicionar\s+(ao|à|a)\s+(carrinho|sacola|cesta)|comprar\s+agora|add\s+to\s+(cart|basket)|colocar\s+na\s+sacola|"addToCart|add-to-cart|btn-?comprar|buy-?button)/iu', $this->html);
    }

    /**
     * Página de verificação de robô, captcha, bloqueio ou erro: não diz nada sobre
     * o site (tenta de novo depois, com outro endereço).
     */
    public function bloqueio(): ?string
    {
        if ($robo = $this->verificacaoDeRobo()) {
            return $robo;
        }
        $alvo = $this->titulo().' '.Str::limit($this->texto(600), 600, '');
        if (preg_match('/(404 not found|p[áa]gina n[ãa]o encontrada|page not found)/iu', $alvo, $m)) {
            return $m[1];
        }

        return strlen(trim($this->texto(200))) < 40 && ! $this->produto() ? 'página quase vazia' : null;
    }

    /**
     * Só a verificação de robô (o site desconfiou do acesso), sem os erros de
     * página: é o que põe o site em pausa no ritmo.
     */
    public function verificacaoDeRobo(): ?string
    {
        // Verificação que só aparece no HTML, em página pequena (a página de
        // produto de verdade tem centenas de KB): Amazon ("Continuar comprando")
        // e Mercado Livre (account-verification).
        foreach (['validateCaptcha', 'account-verification'] as $sinal) {
            if (str_contains($this->html, $sinal) && strlen($this->html) < 30000) {
                return $sinal;
            }
        }
        $alvo = $this->titulo().' '.Str::limit($this->texto(600), 600, '');
        if (preg_match('/(just a moment|attention required|access denied|acesso negado|checking your browser|verifica[çc][ãa]o de seguran[çc]a|are you a (robot|human)|n[ãa]o sou um rob[ôo]|captcha|ddos-guard|cf-chl|request blocked|403 forbidden|tr[áa]fego suspeito|unusual traffic)/iu', $alvo, $m)) {
            return $m[1];
        }

        return null;
    }

    /** Sinais de notícia, artigo, blog ou análise. */
    public function sinaisDeArtigo(): array
    {
        $s = [];
        if ($t = array_intersect($this->tipos, ['NewsArticle', 'Article', 'BlogPosting', 'Report', 'Review', 'ReportageNewsArticle', 'AnalysisNewsArticle', 'OpinionNewsArticle', 'LiveBlogPosting', 'TechArticle'])) {
            $s[] = 'schema '.implode('/', $t);
        }
        if (strtolower((string) $this->meta('og:type')) === 'article') {
            $s[] = 'og:type article';
        }
        if ($this->meta('article:published_time') || $this->meta('article:section')) {
            $s[] = 'metadados de artigo';
        }

        return $s;
    }

    /** Sinais de anúncio de loja. */
    public function sinaisDeLoja(): array
    {
        $s = [];
        $o = $this->oferta();
        if ($this->produto() && $o['preco']) {
            $s[] = 'schema Product com oferta';
        }
        if (in_array(strtolower((string) $this->meta('og:type')), ['product', 'og:product', 'product.item'], true)) {
            $s[] = 'og:type product';
        }
        if ($this->meta('product:price:amount')) {
            $s[] = 'meta product:price';
        }
        if ($this->temCarrinho()) {
            $s[] = 'botão de compra';
        }

        return $s;
    }

    /**
     * 'loja' (anúncio de produto), 'noticia' (notícia, blog, análise) ou 'duvida'.
     *
     * @return array{0: string, 1: string}
     */
    public function veredito(): array
    {
        $loja = $this->sinaisDeLoja();
        $artigo = $this->sinaisDeArtigo();
        $moeda = $this->oferta()['moeda'];

        if ($moeda !== '' && $moeda !== 'BRL' && $loja) {
            return ['outro', "vende em {$moeda}"];
        }
        // Artigo com produto embutido (análise com link de afiliado) e sem
        // carrinho próprio: é notícia.
        if ($artigo && ! $this->temCarrinho()) {
            return ['noticia', implode(', ', $artigo)];
        }
        $fortes = array_intersect($loja, ['schema Product com oferta', 'og:type product', 'meta product:price']);
        if ($fortes && (! $artigo || $this->temCarrinho())) {
            return ['loja', implode(', ', $loja)];
        }
        if (count($loja) >= 1 && ! $artigo && preg_match('/R\$\s*\d/', $this->html)) {
            return ['duvida', 'só '.implode(', ', $loja).' e preço em R$'];
        }

        return ['duvida', $artigo || $loja ? implode(', ', array_merge($artigo, $loja)) : 'sem sinais'];
    }

    /** Todos os nós JSON-LD da página, achatando @graph e listas. */
    protected function lerJsonLd(): array
    {
        $nos = [];
        if (! preg_match_all('/<script[^>]+type=["\']application\/ld\+json["\'][^>]*>(.*?)<\/script>/is', $this->html, $m)) {
            return [];
        }
        foreach ($m[1] as $bloco) {
            $dados = json_decode(trim(html_entity_decode($bloco, ENT_QUOTES | ENT_HTML5)), true)
                ?? json_decode(trim($bloco), true);
            if (! is_array($dados)) {
                continue;
            }
            $pilha = array_is_list($dados) ? $dados : [$dados];
            while ($pilha) {
                $n = array_shift($pilha);
                if (! is_array($n)) {
                    continue;
                }
                if (isset($n['@graph']) && is_array($n['@graph'])) {
                    $pilha = array_merge($pilha, $n['@graph']);
                }
                if (isset($n['@type'])) {
                    $nos[] = $n;
                }
                // Produto dentro de um ItemPage/WebPage (mainEntity) ou de uma lista.
                foreach (['mainEntity', 'itemOffered'] as $k) {
                    if (isset($n[$k]) && is_array($n[$k])) {
                        $pilha[] = $n[$k];
                    }
                }
            }
        }

        return $nos;
    }
}
