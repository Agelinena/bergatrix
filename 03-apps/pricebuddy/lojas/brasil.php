<?php

// Lojas brasileiras para o PriceBuddy, no formato de database/seeders/Stores/*.php.
// Montado na imagem pelo docker-compose.yml; aplicar numa instalação existente:
// lojas/trocar-lojas.sh. Cada loja foi testada com um produto real (README: Lojas).
// Para incluir uma loja: cadastre um produto dela pela interface (o app detecta a
// configuração sozinho) ou acrescente aqui e rode o trocar-lojas.sh de novo.

return [
    // ── Lojas gerais e marketplaces ──
    [
        'name' => 'Amazon Brasil',
        'slug' => 'amazon-br',
        'domains' => [
            [
                'domain' => 'www.amazon.com.br',
            ],
            [
                'domain' => 'amazon.com.br',
            ],
            // Links curtos do app e do "compartilhar" da Amazon (a.co/d/...).
            ['domain' => 'a.co'],
            ['domain' => 'amzn.to'],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => '#productTitle',
            ],
            'price' => [
                'type' => 'selector',
                'value' => '#apex-pricetopay-accessibility-label',
            ],
            'image' => [
                'type' => 'regex',
                'value' => '~"hiRes":"(.+?)"~',
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Magazine Luiza',
        'slug' => 'magazine-luiza',
        'domains' => [
            [
                'domain' => 'www.magazineluiza.com.br',
            ],
            [
                'domain' => 'magazineluiza.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Casas Bahia',
        'slug' => 'casas-bahia',
        'domains' => [
            [
                'domain' => 'www.casasbahia.com.br',
            ],
            [
                'domain' => 'casasbahia.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Americanas',
        'slug' => 'americanas',
        'domains' => [
            [
                'domain' => 'www.americanas.com.br',
            ],
            [
                'domain' => 'americanas.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Carrefour',
        'slug' => 'carrefour',
        'domains' => [
            [
                'domain' => 'www.carrefour.com.br',
            ],
            [
                'domain' => 'carrefour.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // Mercado Livre: bloqueia robô sem login. Funciona com os cookies da sua conta,
    // colados em Stores → Mercado Livre → Cookies (README: Mercado Livre). Os cookies
    // ficam só no banco, nunca aqui; o trocar-lojas.sh não mexe neles.
    [
        'name' => 'Mercado Livre',
        'slug' => 'mercado-livre',
        'domains' => [
            ['domain' => 'www.mercadolivre.com.br'],
            ['domain' => 'mercadolivre.com.br'],
            ['domain' => 'produto.mercadolivre.com.br'],
            ['domain' => 'lista.mercadolivre.com.br'],
            // Link curto do "compartilhar" do app (mercadolivre.com/sec/...).
            ['domain' => 'mercadolivre.com'],
        ],
        'scrape_strategy' => [
            'title' => ['type' => 'selector', 'value' => 'meta[property=og:title]|content'],
            // Não testado com login (o ML recusa a página sem sessão): se o testar-loja.sh
            // mostrar o título mas não o preço, troque por "schema_org" em Stores.
            'price' => ['type' => 'selector', 'value' => 'meta[itemprop=price]|content'],
            'image' => ['type' => 'selector', 'value' => 'meta[property=og:image]|content'],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => ['locale' => 'pt_BR', 'currency' => 'BRL'],
        ],
    ],
    // ── Tecnologia e escritório ──
    [
        'name' => 'KaBuM!',
        'slug' => 'kabum',
        'domains' => [
            [
                'domain' => 'www.kabum.com.br',
            ],
            [
                'domain' => 'kabum.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Pichau',
        'slug' => 'pichau',
        'domains' => [
            [
                'domain' => 'www.pichau.com.br',
            ],
            [
                'domain' => 'pichau.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Terabyte',
        'slug' => 'terabyte',
        'domains' => [
            [
                'domain' => 'www.terabyteshop.com.br',
            ],
            [
                'domain' => 'terabyteshop.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Fast Shop',
        'slug' => 'fast-shop',
        'domains' => [
            [
                'domain' => 'site.fastshop.com.br',
            ],
            [
                'domain' => 'www.fastshop.com.br',
            ],
            [
                'domain' => 'fastshop.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Samsung Brasil',
        'slug' => 'samsung-br',
        'domains' => [
            [
                'domain' => 'www.samsung.com',
            ],
            [
                'domain' => 'samsung.com',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Kalunga',
        'slug' => 'kalunga',
        'domains' => [
            [
                'domain' => 'www.kalunga.com.br',
            ],
            [
                'domain' => 'kalunga.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property=og:title]|content',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~"price":\\s*([\\d.]+),~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property=og:image]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Livros ──
    [
        'name' => 'Estante Virtual',
        'slug' => 'estante-virtual',
        'domains' => [
            [
                'domain' => 'www.estantevirtual.com.br',
            ],
            [
                'domain' => 'estantevirtual.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property="og:title"]|content',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~\\"price\\"\\:\\s?\\"(.*?)\\"~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property="og:image"]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Livraria Leitura',
        'slug' => 'leitura',
        'domains' => [
            [
                'domain' => 'leitura.com.br',
            ],
            [
                'domain' => 'new.leitura.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Livraria da Travessa',
        'slug' => 'travessa',
        'domains' => [
            [
                'domain' => 'www.travessa.com.br',
            ],
            [
                'domain' => 'travessa.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property=og:title]|content',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~"price":\\s*"([\\d.,]+)"~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property=og:image]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Martins Fontes Paulista',
        'slug' => 'martins-fontes',
        'domains' => [
            [
                'domain' => 'www.martinsfontespaulista.com.br',
            ],
            [
                'domain' => 'martinsfontespaulista.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Livraria Vozes',
        'slug' => 'vozes',
        'domains' => [
            [
                'domain' => 'www.livrariavozes.com.br',
            ],
            [
                'domain' => 'livrariavozes.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Livros: mais livrarias, sebos, editoras e quadrinhos ──
    [
        'name' => 'Livraria da Vila',
        'slug' => 'livraria-da-vila',
        'domains' => [
            [
                'domain' => 'www.livrariadavila.com.br',
            ],
            [
                'domain' => 'livrariadavila.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Livrarias Curitiba',
        'slug' => 'livrarias-curitiba',
        'domains' => [
            [
                'domain' => 'www.livrariascuritiba.com.br',
            ],
            [
                'domain' => 'livrariascuritiba.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Livraria Loyola',
        'slug' => 'livraria-loyola',
        'domains' => [
            [
                'domain' => 'www.livrarialoyola.com.br',
            ],
            [
                'domain' => 'livrarialoyola.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Traça Livraria e Sebo',
        'slug' => 'traca',
        'domains' => [
            [
                'domain' => 'www.traca.com.br',
            ],
            [
                'domain' => 'traca.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Companhia das Letras',
        'slug' => 'companhia-das-letras',
        'domains' => [
            [
                'domain' => 'www.companhiadasletras.com.br',
            ],
            [
                'domain' => 'companhiadasletras.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Grupo Editorial Record',
        'slug' => 'record',
        'domains' => [
            [
                'domain' => 'www.record.com.br',
            ],
            [
                'domain' => 'record.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Editora Rocco',
        'slug' => 'rocco',
        'domains' => [
            [
                'domain' => 'rocco.com.br',
            ],
            [
                'domain' => 'www.rocco.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'title',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~"price":"([\\d.]+)"~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property=og:image]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Editora Sextante',
        'slug' => 'sextante',
        'domains' => [
            [
                'domain' => 'www.sextante.com.br',
            ],
            [
                'domain' => 'sextante.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Editora Aleph',
        'slug' => 'aleph',
        'domains' => [
            [
                'domain' => 'www.editoraaleph.com.br',
            ],
            [
                'domain' => 'editoraaleph.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Ubu Editora',
        'slug' => 'ubu',
        'domains' => [
            [
                'domain' => 'www.ubueditora.com.br',
            ],
            [
                'domain' => 'ubueditora.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'DarkSide Books',
        'slug' => 'darkside',
        'domains' => [
            [
                'domain' => 'www.darksidebooks.com.br',
            ],
            [
                'domain' => 'darksidebooks.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Paulus',
        'slug' => 'paulus',
        'domains' => [
            [
                'domain' => 'loja.paulus.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Paulinas',
        'slug' => 'paulinas',
        'domains' => [
            [
                'domain' => 'www.paulinas.com.br',
            ],
            [
                'domain' => 'paulinas.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Pipoca & Nanquim',
        'slug' => 'pipoca-e-nanquim',
        'domains' => [
            [
                'domain' => 'pipocaenanquim.com.br',
            ],
            [
                'domain' => 'www.pipocaenanquim.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Panini',
        'slug' => 'panini',
        'domains' => [
            [
                'domain' => 'panini.com.br',
            ],
            [
                'domain' => 'www.panini.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Jogos de tabuleiro e jogos de PC ──
    [
        'name' => 'Bravo Jogos',
        'slug' => 'bravo-jogos',
        'domains' => [
            [
                'domain' => 'bravojogos.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Galápagos Jogos',
        'slug' => 'galapagos',
        'domains' => [
            [
                'domain' => 'loja.galapagosjogos.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Nuuvem',
        'slug' => 'nuuvem',
        'domains' => [
            [
                'domain' => 'www.nuuvem.com',
            ],
            [
                'domain' => 'nuuvem.com',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property="og:title"]|content',
            ],
            'price' => [
                'type' => 'selector',
                'value' => '[itemProp="price"]|content',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property="og:image"]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Steam',
        'slug' => 'steam',
        'domains' => [
            [
                'domain' => 'store.steampowered.com',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Casa, construção e ferramentas ──
    [
        'name' => 'Leroy Merlin',
        'slug' => 'leroy-merlin',
        'domains' => [
            [
                'domain' => 'www.leroymerlin.com.br',
            ],
            [
                'domain' => 'leroymerlin.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Tok&Stok',
        'slug' => 'tok-stok',
        'domains' => [
            [
                'domain' => 'www.tokstok.com.br',
            ],
            [
                'domain' => 'tokstok.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Mobly',
        'slug' => 'mobly',
        'domains' => [
            [
                'domain' => 'www.mobly.com.br',
            ],
            [
                'domain' => 'mobly.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'MadeiraMadeira',
        'slug' => 'madeira-madeira',
        'domains' => [
            [
                'domain' => 'www.madeiramadeira.com.br',
            ],
            [
                'domain' => 'madeiramadeira.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Casa&Video',
        'slug' => 'casa-e-video',
        'domains' => [
            [
                'domain' => 'www.casaevideo.com.br',
            ],
            [
                'domain' => 'casaevideo.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Loja do Mecânico',
        'slug' => 'loja-do-mecanico',
        'domains' => [
            [
                'domain' => 'www.lojadomecanico.com.br',
            ],
            [
                'domain' => 'lojadomecanico.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Esporte ──
    [
        'name' => 'Decathlon',
        'slug' => 'decathlon',
        'domains' => [
            [
                'domain' => 'www.decathlon.com.br',
            ],
            [
                'domain' => 'decathlon.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property=og:title]|content',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~"price":\\s?([\\d.]+)~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property=og:image]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Farmácia e beleza ──
    [
        'name' => 'Drogasil',
        'slug' => 'drogasil',
        'domains' => [
            [
                'domain' => 'www.drogasil.com.br',
            ],
            [
                'domain' => 'drogasil.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Droga Raia',
        'slug' => 'droga-raia',
        'domains' => [
            [
                'domain' => 'www.drogaraia.com.br',
            ],
            [
                'domain' => 'drogaraia.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Época Cosméticos',
        'slug' => 'epoca-cosmeticos',
        'domains' => [
            [
                'domain' => 'www.epocacosmeticos.com.br',
            ],
            [
                'domain' => 'epocacosmeticos.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property="og:title"]|content',
            ],
            'price' => [
                'type' => 'selector',
                'value' => 'meta[property="product:price:amount"]|content',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property="og:image"]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'O Boticário',
        'slug' => 'boticario',
        'domains' => [
            [
                'domain' => 'www.boticario.com.br',
            ],
            [
                'domain' => 'boticario.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property="og:title"]|content',
            ],
            'price' => [
                'type' => 'selector',
                'value' => 'meta[property="product:price:amount"]|content',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property="og:image"]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Sephora',
        'slug' => 'sephora',
        'domains' => [
            [
                'domain' => 'www.sephora.com.br',
            ],
            [
                'domain' => 'sephora.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Pet ──
    [
        'name' => 'Petz',
        'slug' => 'petz',
        'domains' => [
            [
                'domain' => 'www.petz.com.br',
            ],
            [
                'domain' => 'petz.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'Cobasi',
        'slug' => 'cobasi',
        'domains' => [
            [
                'domain' => 'www.cobasi.com.br',
            ],
            [
                'domain' => 'cobasi.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'selector',
                'value' => 'meta[property=og:title]|content',
            ],
            'price' => [
                'type' => 'regex',
                'value' => '~"@type":"Offer","price":"([\\d.]+)"~',
            ],
            'image' => [
                'type' => 'selector',
                'value' => 'meta[property=og:image]|content',
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    // ── Brinquedos ──
    [
        'name' => 'Ri Happy',
        'slug' => 'ri-happy',
        'domains' => [
            [
                'domain' => 'www.rihappy.com.br',
            ],
            [
                'domain' => 'rihappy.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'api',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
    [
        'name' => 'PBKids',
        'slug' => 'pbkids',
        'domains' => [
            [
                'domain' => 'www.pbkids.com.br',
            ],
            [
                'domain' => 'pbkids.com.br',
            ],
        ],
        'scrape_strategy' => [
            'title' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'price' => [
                'type' => 'schema_org',
                'value' => null,
            ],
            'image' => [
                'type' => 'schema_org',
                'value' => null,
            ],
        ],
        'settings' => [
            'scraper_service' => 'http',
            'scraper_service_settings' => '',
            'locale_settings' => [
                'locale' => 'pt_BR',
                'currency' => 'BRL',
            ],
        ],
    ],
];
