<?php

namespace App\Baratinho;

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * IA local (Ollama, pela ponte "ia" da stack) para os casos que as regras não
 * resolvem: "esta página é loja ou notícia?" e "estes dois anúncios são o mesmo
 * produto?". Resposta em JSON com esquema fixo, temperatura 0, e guardada na
 * tabela baratinho_ia: a mesma pergunta nunca vai duas vezes à GPU.
 *
 * Desligada (sem erro) quando PRICEBUDDY_IA_URL está vazio ou o Ollama não responde.
 */
class Ia
{
    public const TABELA = 'baratinho_ia';

    protected int $usadas = 0;

    protected bool $foraDoAr = false;

    public function __construct(
        protected ?string $url = null,
        protected ?string $modelo = null,
        protected ?int $porRodada = null,
    ) {
        $this->url = rtrim((string) ($url ?? env('PRICEBUDDY_IA_URL', '')), '/');
        $this->modelo = $modelo ?? (string) env('PRICEBUDDY_IA_MODELO', 'gemma3:4b');
        $this->porRodada = $porRodada ?? (int) env('PRICEBUDDY_IA_POR_RODADA', 20);
    }

    public static function garantirTabela(): void
    {
        if (Schema::hasTable(self::TABELA)) {
            return;
        }
        Schema::create(self::TABELA, function (Blueprint $t) {
            $t->string('chave', 40)->primary();
            $t->string('pergunta', 20);
            $t->text('resposta');
            $t->timestamp('criado_em');
        });
    }

    public function ligada(): bool
    {
        return $this->url !== '' && ! $this->foraDoAr;
    }

    public function usadas(): int
    {
        return $this->usadas;
    }

    /**
     * 'loja', 'noticia', 'comparador', 'outro' ou 'bloqueio' (verificação de robô ou erro).
     *
     * @return array{tipo: string, motivo: string}|null
     */
    public function classificarPagina(Pagina $p): ?array
    {
        $dados = [
            'endereco' => $p->url,
            'titulo' => Str::limit($p->titulo(), 200),
            'descricao' => Str::limit((string) $p->meta('description'), 300),
            'og_type' => $p->meta('og:type'),
            'schema' => implode(', ', array_slice($p->tipos(), 0, 12)),
            'sinais_de_loja' => implode(', ', $p->sinaisDeLoja()) ?: 'nenhum',
            'sinais_de_artigo' => implode(', ', $p->sinaisDeArtigo()) ?: 'nenhum',
            'texto' => $p->texto(1500),
        ];
        $prompt = "Classifique a página abaixo, de um site brasileiro.\n"
            ."- loja: anúncio de um produto à venda NESTE site (loja virtual, marketplace, editora que vende direto), com preço e compra no próprio site.\n"
            ."- noticia: notícia, blog, análise, review, guia de compras, lista de ofertas ou cupons, mesmo que cite preços ou tenha links para lojas.\n"
            ."- comparador: comparador de preços ou agregador de ofertas de várias lojas.\n"
            ."- outro: rede social, fórum, wiki, artigo acadêmico, catálogo ou acervo sem venda, classificados de usados (OLX e parecidos).\n"
            ."- bloqueio: verificação de robô, captcha, página carregando, erro ou página não encontrada (não dá para saber o que o site é).\n"
            ."Página de um produto (inclusive livro, à venda pela editora ou livraria) com preço e compra no próprio site é loja.\n\n"
            .json_encode($dados, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);

        $r = $this->perguntar('pagina', $prompt, [
            'type' => 'object',
            'properties' => [
                'tipo' => ['type' => 'string', 'enum' => ['loja', 'noticia', 'comparador', 'outro', 'bloqueio']],
                'motivo' => ['type' => 'string'],
            ],
            'required' => ['tipo', 'motivo'],
        ]);

        return $r && in_array($r['tipo'] ?? null, ['loja', 'noticia', 'comparador', 'outro', 'bloqueio'], true)
            ? ['tipo' => $r['tipo'], 'motivo' => (string) ($r['motivo'] ?? '')]
            : null;
    }

    /**
     * @return array{mesmo: bool, motivo: string}|null
     */
    public function mesmoProduto(array $a, array $b): ?array
    {
        $prompt = "Os dois anúncios abaixo, de lojas diferentes, vendem exatamente o mesmo produto?\n"
            ."Responda mesmo=true só se for o mesmo item: mesmo fabricante, modelo, versão, capacidade, tamanho, voltagem e quantidade.\n"
            ."Cor diferente conta como o mesmo produto. Kit com outra quantidade, acessório, peça de reposição, outra edição de livro, usado ou recondicionado: mesmo=false.\n"
            ."Na dúvida, mesmo=false.\n\n"
            .'A: '.json_encode($this->resumoAnuncio($a), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n"
            .'B: '.json_encode($this->resumoAnuncio($b), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);

        $r = $this->perguntar('mesmo', $prompt, [
            'type' => 'object',
            'properties' => [
                'mesmo' => ['type' => 'boolean'],
                'motivo' => ['type' => 'string'],
            ],
            'required' => ['mesmo', 'motivo'],
        ]);

        return $r && is_bool($r['mesmo'] ?? null) ? ['mesmo' => $r['mesmo'], 'motivo' => (string) ($r['motivo'] ?? '')] : null;
    }

    protected function resumoAnuncio(array $x): array
    {
        return array_filter([
            'loja' => $x['loja'] ?? null,
            'titulo' => Str::limit((string) ($x['titulo'] ?? ''), 200),
            'preco' => isset($x['preco']) ? sprintf('R$ %.2f', $x['preco']) : null,
            'descricao' => isset($x['texto']) ? Str::limit((string) $x['texto'], 500) : null,
        ]);
    }

    /** Pergunta ao Ollama com resposta em JSON (esquema fixo). Null se desligada, sem cota ou com erro. */
    protected function perguntar(string $tipo, string $prompt, array $esquema): ?array
    {
        $chave = sha1($this->modelo."\n".$tipo."\n".$prompt);
        $guardada = DB::table(self::TABELA)->where('chave', $chave)->value('resposta');
        if ($guardada !== null) {
            return json_decode($guardada, true);
        }
        if (! $this->ligada() || $this->usadas >= $this->porRodada) {
            return null;
        }

        $this->usadas++;
        try {
            $resposta = Http::timeout(180)->connectTimeout(5)->post($this->url.'/api/chat', [
                'model' => $this->modelo,
                'stream' => false,
                'format' => $esquema,
                // Libera a VRAM logo: a GPU é dividida com Jellyfin, Immich e as outras IAs.
                'keep_alive' => '2m',
                'options' => ['temperature' => 0, 'num_ctx' => 4096],
                'messages' => [
                    ['role' => 'system', 'content' => 'Você classifica páginas de compras no Brasil. Responda só com o JSON pedido; o motivo em português, curto.'],
                    ['role' => 'user', 'content' => $prompt],
                ],
            ]);
            if (! $resposta->successful()) {
                throw new \RuntimeException('HTTP '.$resposta->status().': '.Str::limit($resposta->body(), 200));
            }
            $json = json_decode((string) $resposta->json('message.content'), true);
            if (! is_array($json)) {
                return null;
            }
            DB::table(self::TABELA)->insertOrIgnore([
                'chave' => $chave, 'pergunta' => $tipo, 'resposta' => json_encode($json, JSON_UNESCAPED_UNICODE), 'criado_em' => now(),
            ]);

            return $json;
        } catch (Throwable $e) {
            // Ollama fora do ar: desliga a IA até a próxima rodada, sem travar as buscas.
            $this->foraDoAr = true;
            logger()->warning('baratinho: IA indisponível', ['erro' => $e->getMessage()]);

            return null;
        }
    }
}
