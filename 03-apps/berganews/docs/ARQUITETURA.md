# Berganews: arquitetura

O que existe hoje (fase 1) e o que cada fase acrescenta. Substitui o berga-news antigo
([legado](../../../docs/legado/stacks/berga-news.md)), que agrupava as notícias pedindo os grupos a um LLM externo,
em lotes de 40.

## Decisões

| Decisão | Por quê |
|---|---|
| **IA só local** (Ollama, stack `ollama`) | Nada sai de casa. A GPU (GTX 1060) é dividida com Jellyfin, Transcriptor, Immich e Legendarr, então a IA pesada roda de madrugada. |
| **Um trabalho de IA por vez**, no worker `ai` | O Ollama guarda um modelo na VRAM; trabalhos em paralelo só disputam a GPU. |
| **Modelo multilíngue** (`gemma3:4b` por padrão) | Notícias em português e em inglês. Cabe na GPU com folga (~3,3 GB). Troca-se pelo `.env`. |
| **Embeddings multilíngues** (`bge-m3`, fase 2) | O mesmo fato em português e em inglês cai no mesmo grupo: o vetor é o mesmo para os dois idiomas. |
| **Feed e artigo são da casa**; assinatura, pasta, lido e salvo são da pessoa | Um feed assinado por três pessoas é coletado uma vez. As histórias e os resumos (fase 2+) também são da casa, e cada pessoa vê o recorte dos veículos que assina. |
| **Toda URL das pessoas sai pelo `egress`** (smokescreen) | Um "feed" que aponte para o NAS ou para outro container é recusado, inclusive depois de redirecionamento. Mesmo modelo do Transcriptor. |
| **Imagens pelo servidor** (`/api/img`, link assinado) | O aparelho não fala com o site do veículo: sem rastreador, e a imagem não some. |
| **Busca no Postgres** (`tsvector` português/inglês + `unaccent`) | Sem serviço a mais. |
| **Login como no Bergastream** | Servidor como cliente OIDC, código de uso único e PKCE do app; funciona na web, no Android e no computador. |

## Serviços e redes

```
app (Flutter) ──▶ Traefik ──▶ api ──┬─▶ db, redis                 (berganews-internal)
                                    ├─▶ egress ──▶ internet      (achar feed, imagens)
                                    └─▶ authentik-server         (bergatrix-proxy)
fetcher ──▶ db, redis; egress ──▶ internet                       (só berganews-internal)
ai ──▶ db, redis; ollama                                         (bergatrix-ai, sem internet)
```

## Modelo de dados (fase 1)

| Tabela | De quem | O quê |
|---|---|---|
| `users`, `refresh_tokens` | pessoa | Conta ligada ao Authentik pelo `sub`; sessões com rotação |
| `user_prefs` | pessoa | Abas (ordem, ligada/desligada), idioma de leitura, tema, tamanho do texto |
| `feeds` | casa | Endereço, ETag/Last-Modified, falhas e próxima coleta (com espera crescente) |
| `folders`, `subscriptions` | pessoa | Pastas e o que cada um assina (com nome próprio do veículo) |
| `articles` | casa | Manchete, trecho, texto completo limpo, idioma, `tsvector` da busca |
| `article_states` | pessoa | Lido e salvo |
| `article_translations` | casa | Tradução por artigo e idioma, feita uma vez |

`articles.content_status`: `ok` (texto completo), `short` (paywall ou extração ruim: o app mostra o trecho e leva ao
site), `error`.

Fase 2:

| Tabela | De quem | O quê |
|---|---|---|
| `article_embeddings` | casa | Vetor `bge-m3` (1024) da manchete + começo do texto, e os nomes próprios e siglas |
| `stories` | casa | Manchete, datas, número de artigos e de veículos |
| `story_articles` | casa | Cada artigo com embedding está numa história; `is_seed` marca os artigos-base; `manual` = posto por uma pessoa |
| `story_pairs` | casa | Exemplos rotulados (mesma notícia ou não), de juntar, separar e da calibração |

## Agrupamento em histórias

Para cada artigo novo, em ordem de publicação (`app/stories/cluster.py`):

1. Compara o embedding com os **artigos-base** das histórias que tiveram matéria a até 72 h (busca exata: são poucos
   milhares de vetores na janela).
2. Entra na mais parecida se a similaridade passar de `STORY_THRESHOLD` (0,78) **e**, no mesmo idioma, se tiverem
   um nome próprio ou sigla em comum. Em idiomas diferentes os nomes não batem ("EUA" × "United States"), então vale
   só a similaridade.
3. Acima de `STORY_STRONG` (0,88) entra sem checar nomes e vira artigo-base (até 4).
4. Senão, abre uma história nova, com ele de base.

Comparar com os artigos-base, e não com o último que entrou, é o que impede o grupo de "crescer" juntando assuntos
vizinhos. Os limites são um ponto de partida: calibre com exemplos reais (README, "Calibrar o limite").

## Coleta

1. A cada `FETCH_INTERVAL_MINUTES` (20), os feeds com assinatura, até 6 em paralelo, com `If-None-Match` e
   `If-Modified-Since`. Falhas seguidas dobram a espera, até 6 h.
2. Assinatura nova ou botão "atualizar": a API põe o feed na fila `berganews:fetch:now` e o worker coleta na hora.
3. Texto completo: sempre pela página, com o trafilatura (sem menu, anúncio, rodapé), mantendo parágrafos,
   subtítulos, negrito, links, citações e as fotos do corpo (`<graphic>` do trafilatura e `<amp-img>` do G1 viram
   `<img>`). O texto que vem no feed fica só de reserva, para quando a página falha: o G1, por exemplo, manda a
   matéria num bloco só. Texto curto (paywall) fica guardado como `short`, e o app oferece o site.
   Vídeos viram cartões com a miniatura, que abrem no player do veículo (Globoplay, YouTube, Vimeo, a página da
   BBC); o arquivo de vídeo não vem para o servidor (`app/core/videos.py`).
   Quando o extrator melhora, `EXTRACT_VERSION` sobe (`worker/fetcher.py`) e o worker refaz em segundo plano as
   matérias guardadas, sem trocar uma boa por uma pior.
4. Limpeza às 4 h: matérias com mais de 150 dias (5 meses) que ninguém salvou, com as imagens; feeds sem
   ninguém; imagens que nenhuma matéria guardada usa. Ao salvar uma matéria, as imagens dela vão para o
   servidor na hora, e ficam enquanto ela estiver salva.

## API

| Rota | Para quê |
|---|---|
| `GET /api/auth/oidc/start`, `/callback`, `POST /exchange`, `/refresh`, `/logout`, `GET /me` | Login |
| `GET/PATCH /api/admin/users`, `POST /api/admin/users/{id}/logout` | Página Usuários |
| `GET/PUT /api/prefs` | Painel Aparência (abas) |
| `GET/POST/PATCH/DELETE /api/subscriptions`, `POST …/{id}/refresh` | Veículos (aceita o endereço do site) |
| `GET/POST/PATCH/DELETE /api/folders` | Pastas |
| `GET/POST /api/opml` | Exportar e importar |
| `GET /api/articles?view=all\|unread\|saved&feed_id&folder_id&q&cursor` | Todas as abas e a busca |
| `GET /api/articles/{id}`, `POST …/state`, `POST /api/articles/read` | Leitor, lido/salvo, marcar tudo |
| `GET/POST /api/articles/{id}/translation/{lang}` | Tradução (202 com o progresso enquanto traduz) |
| `GET /api/img?u&s` | Imagens |
| `GET /api/stories?days&min_sources&cursor`, `GET /api/stories/{id}` | Aba "IA" e a tela da história (linha do tempo) |
| `POST /api/stories/{id}/merge`, `POST /api/stories/{id}/split` | Juntar e separar à mão |
| `GET /api/admin/stories/calibration`, `GET …/pairs/suggest`, `POST …/pairs`, `POST …/recluster` | Calibração (admin) |

## IA: quando roda o quê

| Trabalho | Quando | Fase |
|---|---|---|
| Tradução | Na hora, quando a pessoa aperta o botão | 1 (feito) |
| Embeddings (`bge-m3`) | Ao longo do dia, em lotes de 16, nos intervalos da tradução | 2 (feito) |
| Agrupamento em histórias | Junto dos embeddings (é só SQL com pgvector) | 2 (feito) |
| Resumo, linha do tempo e "como cada veículo contou" | De madrugada (janela configurável, ex.: 1 h às 6 h) | 3 |
| Newsletter de cada pessoa | De madrugada, depois dos resumos; o e-mail sai no horário que a pessoa escolher | 4 |

Durante o dia, as histórias já aparecem agrupadas (com fontes e linha do tempo), e o resumo chega na madrugada seguinte.
Os resumos só usam o texto extraído, e cada frase leva o link da fonte.

## Fases

1. **Leitor** (feito no servidor): feeds, texto completo, pastas, OPML, busca, lido/salvo, abas, tradução.
   Falta o app Flutter.
2. **Histórias** (feito no servidor): embeddings, agrupamento, aba "IA", tela da história com linha do tempo,
   juntar e separar à mão, calibração do limite.
3. **Resumos:** resumo por história, "o que mudou desde a última vez" (só os artigos depois do `last_seen` da
   pessoa), comparação entre veículos.
4. **Avisos:** newsletter, tópicos seguidos, silenciar assuntos e palavras, push (ntfy, stack nova).

Desde a fase 1: guardar à mão pares de artigos "mesma notícia / notícias diferentes" dos feeds reais. É o que vai
calibrar o agrupamento.
