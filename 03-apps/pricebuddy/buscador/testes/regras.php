<?php
/*
 * Testes das regras do buscador (sem banco nem internet): veredito de página,
 * comparador, quantidade, EAN/ISBN e listagens. Rode com ./buscador/testes/rodar.sh.
 * Caso novo: um eq() com o que se espera; uma mudança nas regras não pode quebrar os antigos.
 */
require '/app/vendor/autoload.php';
use App\Baratinho\{Pagina, Comparador, Texto, Identificadores, Listas};
$falhas = 0;
function eq($nome, $obtido, $esperado) { global $falhas; $ok = $obtido === $esperado; if (!$ok) $falhas++; printf("%s %s => %s%s\n", $ok ? 'ok ' : 'ERRO', $nome, json_encode($obtido, JSON_UNESCAPED_UNICODE), $ok ? '' : ' (esperado '.json_encode($esperado, JSON_UNESCAPED_UNICODE).')'); }

$loja = '<html><head><title>SSD Kingston A400 240GB | KaBuM!</title><meta property="og:type" content="product"><script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"SSD Kingston A400 240GB","gtin13":"0740617261219","mpn":"SA400S37/240G","offers":{"@type":"Offer","price":"189.90","priceCurrency":"BRL","availability":"https://schema.org/InStock","itemCondition":"https://schema.org/NewCondition"}}</script></head><body><button>Adicionar ao carrinho</button></body></html>';
$noticia = '<html><head><title>SSD em promoção: Kingston A400 por R$ 189</title><meta property="og:type" content="article"><meta property="article:published_time" content="2026-11-20"><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"NewsArticle","headline":"SSD em promoção"},{"@type":"Product","name":"SSD Kingston A400","offers":{"@type":"Offer","price":"189","priceCurrency":"BRL"}}]}</script></head><body>Vale a pena? O SSD está por R$ 189 na Amazon. <a href="https://amzn.to/x">Ver oferta</a></body></html>';
$review = '<html><head><title>Review A400</title><script type="application/ld+json">{"@type":"Review","itemReviewed":{"@type":"Product","name":"A400"}}</script></head><body>Nota 8</body></html>';
$vago = '<html><head><title>Loja X - SSD</title></head><body>SSD 240GB R$ 199,90 <a class="btn-comprar">Comprar</a></body></html>';
$usd = '<html><head><script type="application/ld+json">{"@type":"Product","name":"SSD","offers":{"price":"29.99","priceCurrency":"USD"}}</script></head><body>Add to cart</body></html>';
$usado = '<html><head><title>iPhone 13 128GB Usado - Excelente</title><script type="application/ld+json">{"@type":"Product","name":"iPhone 13","offers":{"price":"2500","priceCurrency":"BRL","itemCondition":"https://schema.org/UsedCondition"}}</script></head><body>Comprar agora</body></html>';

eq('loja: veredito', (new Pagina('https://www.kabum.com.br/produto/1', $loja))->veredito()[0], 'loja');
eq('loja: gtin', (new Pagina('u', $loja))->gtins(), ['00740617261219']);
eq('loja: mpn', (new Pagina('u', $loja))->mpn(), 'SA400S37240G');
eq('loja: oferta', (new Pagina('u', $loja))->oferta()['preco'], 189.9);
eq('notícia com Product embutido', (new Pagina('u', $noticia))->veredito()[0], 'noticia');
eq('review', (new Pagina('u', $review))->veredito()[0], 'noticia');
eq('sem dados estruturados', (new Pagina('u', $vago))->veredito()[0], 'duvida');
eq('loja em dólar', (new Pagina('u', $usd))->veredito()[0], 'outro');
eq('usado', (new Pagina('u', $usado))->naoNovo(), true);
eq('loja não é usado', (new Pagina('u', $loja))->naoNovo(), false);

eq('qtd kit com 3', Texto::quantidade('Kit com 3 Toalhas de Banho'), 3);
eq('qtd 12 unidades', Texto::quantidade('Cerveja Lata 350ml 12 Unidades'), 12);
eq('qtd normal', Texto::quantidade('Caixa de Som JBL Go 3'), 1);
eq('qtd jogo 5 peças', Texto::quantidade('Jogo de Panelas 5 Peças Tramontina'), 5);
eq('ean inválido', Identificadores::gtins('"gtin13":"7891234567890"'), []);
eq('ean válido', Identificadores::gtins('"gtin13":"7891000100103"'), ['07891000100103']);
eq('isbn não vira ean', Identificadores::gtins('"gtin13":"9788535914849"'), []);
eq('ean no texto', Identificadores::gtins('<td>EAN: 7891000100103</td>'), ['07891000100103']);

foreach ([
  ['https://www.amazon.com.br/s?k=ssd', true], ['https://www.kabum.com.br/busca/ssd', true], ['https://www.magazineluiza.com.br/busca/ssd/', true],
  ['https://lista.mercadolivre.com.br/ssd-240', true], ['https://www.kabum.com.br/', true], ['https://loja.com/categoria/ssd', true],
  ['https://www.kabum.com.br/produto/85196/ssd-kingston', false], ['https://www.amazon.com.br/dp/B01N5IB20Q', false],
  ['https://www.magazineluiza.com.br/ssd-240gb-kingston/p/ad8jc5g0c4/in/ssd2/', false], ['https://produto.mercadolivre.com.br/MLB-123-ssd-_JM', false],
  ['https://manuais.emondial.com/Manual-AFN-40-BFS.pdf', true], ['https://www.terabyteshop.com.br/hardware/hard-disk/ssd', true], ['https://www.pichau.com.br/hardware/ssd', true], ['https://www.livrariadavila.com.br/livros/ficcao/classicos', true],
  ['https://www.travessa.com.br/1984/artigo/c2581bed-5e91-4b27-8ab0-1444b1260baf', false], ['https://loja.com.br/products/camiseta-basica-preta', false], ['https://loja.com.br/caneca-porcelana-gato-preto', false],
  ['https://www.companhiadasletras.com.br/9788535914849-1984---traducao/p', false], ['https://www.martinsfontespaulista.com.br/1984---traducao-de-alexandre-hubner-e-heloisa-jahn-580053/p', false],
] as [$u, $e]) eq('listagem '.$u, Listas::pareceListagem($u), $e);
eq('fixo g1', Listas::tipoFixo('g1.globo.com'), 'noticia');
eq('fixo www.tecmundo', Listas::tipoFixo('www.tecmundo.com.br'), 'noticia');
eq('fixo kabum', Listas::tipoFixo('www.kabum.com.br'), null);
eq('fixo falso-globo', Listas::tipoFixo('naoglobo.com'), null);

$o = ['titulo' => 'SSD Kingston A400 240GB SATA', 'preco' => 189.9, 'gtins' => [], 'mpn' => null, 'isbn' => null];
$c = fn($t, $p, $x = []) => array_merge(['titulo' => $t, 'preco' => $p, 'loja' => 'Loja', 'gtins' => [], 'mpn' => null], $x);
eq('cmp igual', Comparador::decidir($o, $c('SSD 240 GB Kingston A400, SATA III', 199))[0], 'sim');
eq('cmp 480', Comparador::decidir($o, $c('SSD Kingston A400 480GB SATA', 299))[0], 'nao');
// Kit com outra quantidade: mesmo produto, comparado por unidade.
eq('cmp kit 2 por unidade', Comparador::decidir($o, $c('Kit 2 SSD Kingston A400 240GB SATA', 379))[0], 'sim');
eq('cmp kit 2 motivo', str_contains(Comparador::decidir($o, $c('Kit 2 SSD Kingston A400 240GB SATA', 379))[1], '1 x 2 unidades'), true);
eq('cmp kit caro por unidade', Comparador::decidir($o, $c('Kit 2 SSD Kingston A400 240GB SATA', 1300))[0], 'nao');
eq('cmp 6 x 12 latas', Comparador::decidir(['titulo' => 'Cerveja Heineken Lata 350ml 12 unidades', 'preco' => 60], $c('Cerveja Heineken Lata 350ml 6 unidades', 31))[0], 'sim');
eq('cmp lata x long neck', Comparador::decidir(['titulo' => 'Cerveja Heineken Lata 350ml 12 unidades', 'preco' => 60], $c('Cerveja Heineken Long Neck 330ml 12 unidades', 70))[0], 'nao');
eq('cmp usado', Comparador::decidir($o, $c('SSD Kingston A400 240GB usado', 120, ['nao_novo' => true]))[0], 'nao');
eq('cmp ean igual', Comparador::decidir(array_merge($o, ['gtins' => ['1']]), $c('Qualquer coisa', 190, ['gtins' => ['1']]))[0], 'sim');
eq('cmp ean diferente', Comparador::decidir(array_merge($o, ['gtins' => ['1']]), $c('SSD Kingston A400 240GB', 190, ['gtins' => ['2']]))[0], 'nao');
eq('cmp dúvida sem modelo', Comparador::decidir($o, $c('SSD Kingston 240GB SATA III 2,5"', 189))[0], 'duvida');
eq('cmp mpn', Comparador::decidir(array_merge($o, ['mpn' => 'SA400S37240G']), $c('Unidade de estado sólido 240GB Kingston', 189, ['mpn' => 'SA400S37240G']))[0], 'sim');
eq('cmp fritadeira mesmo', Comparador::decidir(['titulo' => 'Fritadeira Elétrica Air Fryer Mondial AFN-40-BI 4L Preta 127V', 'preco' => 399], $c('Air Fryer Mondial 4 Litros AFN-40-BI Preto 110V', 389))[0], 'sim');
eq('cmp acessório barato', Comparador::decidir(['titulo' => 'Echo Dot 5ª geração', 'preco' => 399], $c('Capa para Echo Dot 5ª geração', 39))[0], 'nao');
eq('cmp livro mesmo isbn', Comparador::decidir(['titulo' => '1984', 'preco' => 40, 'isbn' => '9788535914849'], $c('1984 George Orwell', 45, ['isbn_na_pagina' => true]))[0], 'sim');
eq('cmp 127 x 220', Comparador::decidir(['titulo' => 'Air Fryer Mondial AFN-40-BI 4L 127V', 'preco' => 399], $c('Air Fryer Mondial AFN-40-BI 4L 220V', 399))[0], 'nao');
eq('cmp livro sem isbn', Comparador::decidir(['titulo' => '1984', 'preco' => 40, 'isbn' => '9788535914849'], $c('1984 George Orwell', 45, ['isbn_na_pagina' => false]))[0], 'nao');
eq('códigos AFN-40-BI', Texto::codigos('Fritadeira Air Fryer Mondial AFN-40-BI 4L 127V'), ['afn40bi']);
eq('códigos RTX 5060', Texto::codigos('Placa de Vídeo RTX 5060 8GB'), ['rtx5060']);
eq('cmp código junto', Comparador::decidir(['titulo' => 'MONDIAL Fritadeira Sem Óleo Air Fryer 4L, Preto/Inox, 1500W, 110V - AFN-40-BI', 'preco' => 239], $c('Fritadeira Elétrica Sem Óleo Air Fryer Mondial AFN40BI Family Inox 4L - Preta/Inox', 311))[0], 'sim');
eq('cmp código diferente', Comparador::decidir(['titulo' => 'Placa de Vídeo RTX 5060 8GB Gigabyte', 'preco' => 2000], $c('Placa de Vídeo RTX 5070 12GB Gigabyte', 2900))[0], 'nao');

eq('bloqueio: Amazon continuar comprando', (new Pagina('u', '<html><title>Amazon.com.br</title><form action="/errors/validateCaptcha"><button>Continuar comprando</button></form></html>'))->bloqueio(), 'validateCaptcha');
eq('bloqueio: página normal com carrinho', (new Pagina('u', '<html><title>Produto X</title>'.str_repeat('<p>Descrição longa do produto com detalhes.</p>', 40).'<div>Produto adicionado! Continuar comprando</div></html>'))->bloqueio(), null);

eq('fixo .edu.br', Listas::tipoFixo('repositorio.ufsc.edu.br'), 'outro');
eq('fixo .edu', Listas::tipoFixo('www.harvard.edu'), 'outro');
eq('fixo pergamum', Listas::tipoFixo('ifsp.pergamum.com.br'), 'outro');
eq('fixo catálogo de livros', Listas::tipoFixo('www.bookinfometadados.com.br'), 'outro');

// Nome automático de loja nova.
$pg = fn ($t, $site = '') => new Pagina('u', '<html><head><title>'.$t.'</title>'.($site ? '<meta property="og:site_name" content="'.$site.'">' : '').'</head></html>');
eq('nome og:site_name', App\Baratinho\LojasNovas::nome($pg('SSD | Loja', 'Lognet Informática'), 'lognetinfo.com.br'), 'Lognet Informática');
eq('nome fim do título', App\Baratinho\LojasNovas::nome($pg('SSD 240GB KINGSTON | Medina Distribuidora'), 'medinadistribuidora.com.br'), 'Medina Distribuidora');
eq('nome fim do título curto', App\Baratinho\LojasNovas::nome($pg('Memória SSD Kingston 240GB | Microtec'), 'www.microtecpapelaria.com.br'), 'Microtec');
eq('nome sem relação', App\Baratinho\LojasNovas::nome($pg('SSD 240GB - Kingston'), 'zema.com'), 'Zema');
eq('nome subdomínio genérico', App\Baratinho\LojasNovas::nome($pg('Livro X'), 'secure.livrariaunesp.com.br'), 'Livrariaunesp');
eq('nome subdomínio genérico com título', App\Baratinho\LojasNovas::nome($pg('Livro X | Livraria Unesp'), 'secure.livrariaunesp.com.br'), 'Livraria Unesp');
eq('nome og igual ao domínio', App\Baratinho\LojasNovas::nome($pg('Livro X', 'cliquebooks.com.br'), 'cliquebooks.com.br'), 'Cliquebooks');
eq('nome og minúsculo', App\Baratinho\LojasNovas::nome($pg('Fone', 'qcymall'), 'qcymall.com'), 'Qcymall');
eq('nome loja.x', App\Baratinho\LojasNovas::nome($pg('Produto'), 'loja.exemplo.com.br'), 'Exemplo');
eq('texto com UTF-8 inválido', is_string((new Pagina('u', "<p>caf\xe9 R\$ 10</p>"))->texto()), true);

// Ofertas: série diária do menor preço.
use App\Baratinho\Ofertas;
$hoje = Illuminate\Support\Carbon::parse('2026-11-27');
$serie = function (array $trechos) use ($hoje) {
    // [[dias atrás (início), dias atrás (fim), preço], ...]
    $s = [];
    foreach ($trechos as [$de, $ate, $p]) {
        for ($d = $de; $d >= $ate; $d--) {
            $s[$hoje->copy()->subDays($d)->format('Y-m-d')] = $p;
        }
    }
    return $s;
};
$fach = Ofertas::analisarSerie($serie([[80, 15, 100], [14, 7, 150], [6, 0, 110]]), $hoje);
eq('ofertas: fachada (subiu e "caiu")', [$fach['fachada'], $fach['caiu'], $fach['minimo']], [true, false, false]);
$real = Ofertas::analisarSerie($serie([[80, 7, 100], [6, 0, 85]]), $hoje);
eq('ofertas: queda de verdade e mínimo', [$real['fachada'], $real['caiu'], $real['minimo']], [false, true, true]);
$novo = Ofertas::analisarSerie($serie([[6, 0, 100]]), $hoje);
eq('ofertas: histórico curto não é mínimo', [$novo['minimo'], $novo['caiu']], [false, false]);
$estavel = Ofertas::analisarSerie($serie([[60, 0, 100]]), $hoje);
eq('ofertas: preço parado não é mínimo', $estavel['minimo'], false);
$antigo = Ofertas::analisarSerie($serie([[200, 120, 50], [100, 0, 100]]), $hoje);
eq('ofertas: janela de 90 dias', $antigo['min90'], 100.0);

echo $falhas ? "\n$falhas falha(s)\n" : "\ntudo certo\n";
exit($falhas ? 1 : 0);
