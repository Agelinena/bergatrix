<?php

/**
 * Filtro da pesquisa do app: fica entre a tela "criar por busca" do PriceBuddy
 * e o SearXNG (http://buscador:8081/search, posto nas configurações pelo
 * buscador). Repassa a busca e tira dos resultados:
 *
 *   - sites da lista fixa (notícias, comparadores, redes sociais...);
 *   - sites que o buscador já classificou como não-loja (baratinho_dominios);
 *   - páginas de listagem (busca, categoria, página inicial).
 *
 * Sites desconhecidos continuam aparecendo e ficam anotados para o buscador
 * classificar. Roda com `php -S` dentro do container do buscador (rodar.sh),
 * sem subir o Laravel: só PDO e as listas de Baratinho/Listas.php.
 */

require __DIR__.'/Baratinho/Listas.php';

use App\Baratinho\Listas;

$caminho = (string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if ($caminho === '/saude') {
    echo 'ok';

    return;
}
if ($caminho !== '/search') {
    http_response_code(404);

    return;
}

$searxng = getenv('PRICEBUDDY_SEARXNG_URL') ?: 'http://searxng:8080/search';
$corpo = @file_get_contents($searxng.'?'.($_SERVER['QUERY_STRING'] ?? ''), false, stream_context_create([
    'http' => ['timeout' => 40, 'ignore_errors' => true],
]));
$status = preg_match('/\s(\d{3})\s/', $http_response_header[0] ?? '', $m) ? (int) $m[1] : 502;
if ($corpo === false) {
    http_response_code(502);
    header('Content-Type: application/json');
    echo json_encode(['results' => [], 'erro' => 'SearXNG não respondeu']);

    return;
}

$dados = json_decode($corpo, true);
if (! is_array($dados) || ! isset($dados['results'])) {
    // Não é JSON (formato html, erro do SearXNG): repassa como veio.
    http_response_code($status);
    foreach ($http_response_header ?? [] as $h) {
        if (stripos($h, 'content-type:') === 0) {
            header($h);
        }
    }
    echo $corpo;

    return;
}

$pdo = null;
try {
    $pdo = new PDO(
        sprintf('pgsql:host=%s;port=%s;dbname=%s', getenv('DB_HOST'), getenv('DB_PORT') ?: '5432', getenv('DB_DATABASE')),
        getenv('DB_USERNAME'),
        getenv('DB_PASSWORD'),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 3]
    );
} catch (Throwable $e) {
    error_log('filtro: sem banco, só a lista fixa: '.$e->getMessage());
}

// Domínios das lojas cadastradas: sempre ficam.
$lojas = [];
if ($pdo) {
    try {
        foreach ($pdo->query('select domains from stores')->fetchAll(PDO::FETCH_COLUMN) as $json) {
            foreach ((array) json_decode((string) $json, true) as $d) {
                if (! empty($d['domain'])) {
                    $lojas[Listas::normalizarHost($d['domain'])] = true;
                }
            }
        }
    } catch (Throwable $e) {
        error_log('filtro: lojas: '.$e->getMessage());
    }
}

$hosts = [];
foreach ($dados['results'] as $r) {
    $h = Listas::normalizarHost((string) parse_url((string) ($r['url'] ?? ''), PHP_URL_HOST));
    if ($h !== '') {
        $hosts[$h] = true;
    }
}

// Decisões do buscador para esses sites.
$decididos = [];
if ($pdo && $hosts) {
    try {
        $marcas = implode(',', array_fill(0, count($hosts), '?'));
        $st = $pdo->prepare("select host, tipo from baratinho_dominios where host in ($marcas)");
        $st->execute(array_keys($hosts));
        $decididos = $st->fetchAll(PDO::FETCH_KEY_PAIR);
    } catch (Throwable $e) {
        // Tabela ainda não criada (o buscador cria na primeira rodada).
    }
}

$ficam = [];
$tirados = 0;
$novos = [];
foreach ($dados['results'] as $r) {
    $url = (string) ($r['url'] ?? '');
    $h = Listas::normalizarHost((string) parse_url($url, PHP_URL_HOST));
    if ($h === '' || Listas::pareceListagem($url) || Listas::tipoFixo($h)
        || in_array($decididos[$h] ?? null, ['noticia', 'comparador', 'outro'], true)) {
        $tirados++;

        continue;
    }
    if (! isset($lojas[$h]) && ! isset($decididos[$h])) {
        $novos[$h] = $url;
    }
    $ficam[] = $r;
}

if ($pdo && $novos) {
    try {
        $st = $pdo->prepare(
            "insert into baratinho_dominios (host, tipo, exemplo_url, vezes, tentativas, visto_em)
             values (?, 'pendente', ?, 1, 0, now())
             on conflict (host) do update set vezes = baratinho_dominios.vezes + 1, visto_em = now()"
        );
        foreach ($novos as $h => $url) {
            $st->execute([$h, $url]);
        }
    } catch (Throwable $e) {
        // Sem a tabela ainda: anota na próxima.
    }
}

$dados['results'] = $ficam;
http_response_code($status);
header('Content-Type: application/json');
header('X-Baratinho-Filtrados: '.$tirados);
echo json_encode($dados, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
