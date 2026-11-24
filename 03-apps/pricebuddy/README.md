# PriceBuddy (baratinho)

Acompanha o preço de produtos em lojas online e avisa quando o preço cai. Cada pessoa tem a própria conta, com os
próprios produtos, tags e avisos. As lojas (como buscar título e preço em cada site) são compartilhadas.

Projeto: [jez500/pricebuddy](https://github.com/jez500/pricebuddy) · documentação: <https://pricebuddy.jez.me>.

| Serviço | O que faz | Redes |
|---|---|---|
| `app` | Interface (Filament), agendador e fila no mesmo container | `pricebuddy-internal`, `bergatrix-pricebuddy` (Traefik) |
| `scraper` | Chrome sem tela (SeleniumBase), para lojas que exigem JavaScript | só `pricebuddy-internal` |
| `egress` | Proxy de saída (smokescreen): recusa redes privadas | `pricebuddy-internal`, `pricebuddy-egress` |
| `searxng` | Metabuscador (busca na internet), usado pelo buscador e pela tela de busca do app | `pricebuddy-internal` |
| `buscador` | Procura o mesmo produto nas outras lojas, sozinho ([Busca automática](#busca-automática-nas-outras-lojas)) | `pricebuddy-internal` |
| `smtp` | Relay de e-mail (Postfix): recebe do app e repassa só ao SMTP do `.env` | `pricebuddy-internal`, `pricebuddy-egress` |
| `db` | Postgres 16 | `pricebuddy-internal` |

Endereço: `baratinho.${DOMAIN}`.

## Por que a rede é assim

O PriceBuddy busca as páginas que as pessoas cadastram. Um link como `http://192.168.x.x` ou `http://sonarr:8989`
faria o servidor buscar coisas da rede de casa. Por isso, seguindo o modelo do Transcriptor e do Berganews
([docs/06-redes.md](../../docs/06-redes.md)):

- o `app` não fica na `bergatrix-proxy`: ele divide só a rede `bergatrix-pricebuddy` com o Traefik, sem internet;
- toda saída HTTP do `app` e do `scraper` vai pelo `egress` (`HTTP_PROXY`/`HTTPS_PROXY`, também em minúsculas, porque o
  libcurl só lê `http_proxy` assim), e o smokescreen recusa redes privadas, loopback e link-local.

Testado (v1.0.57): página pública responde 200 tanto pela linha de comando quanto pelo Apache e pelo Chrome do scraper.
`https://192.168.0.1` é recusado (`Deny: Private Range`).

**E-mail:** o app não alcança a internet, e o proxy de saída só fala HTTP. Por isso o e-mail passa pelo serviço `smtp`
(Postfix): o app entrega a ele, na rede interna, e ele repassa só ao `SMTP_HOST` do `.env` (pode ser a mesma conta do
Authentik e do monitor), com TLS e login. Testado: o relay recebe do app e abre TLS com o provedor.

## Acesso

O PriceBuddy não tem OIDC, então entra no padrão **forward-auth** ([docs/05-acesso.md](../../docs/05-acesso.md)):
o Authentik exige o login e depois a pessoa entra com a conta dela no PriceBuddy (são dois logins). A sessão do app
dura 30 dias.

A aplicação de domínio só deixa passar o grupo `admins`. Para a família usar, o baratinho tem uma aplicação própria:

| Campo | Valor |
|---|---|
| Provider | *Proxy*, modo **Forward auth (single application)** |
| External host | `https://baratinho.<domínio>` |
| Outpost | o embutido (o mesmo da aplicação de domínio) |
| Aplicação | `PriceBuddy`, slug `pricebuddy` |
| Acesso | *Binding* ao grupo `pricebuddy_users` (Order `0`) |

Ponha no grupo `pricebuddy_users` quem vai usar, inclusive você.

## Subir

1. **Redes e Traefik:** `./00-infrastructure/atualizar.sh` cria a rede nova `bergatrix-pricebuddy` e recria o
   Traefik (as rotas param por alguns segundos). Ele pula o PriceBuddy enquanto não houver `.env`.

2. **Authentik:** crie o provider, a aplicação e o grupo (acima).
3. **Pasta** no servidor:

   ```bash
   sudo mkdir -p /srv/appdata/pricebuddy/{postgres,storage}
   ```

   O Postgres corrige o dono da pasta dele. O app roda como root e libera o `storage` sozinho (`chmod 777` no início).

4. **`.env`:** `cp .env.example .env` e preencha a senha do banco, a `PRICEBUDDY_APP_KEY`, o `SEARXNG_SECRET` e o `SMTP_*`
   (os comandos estão no arquivo).
   **Não troque a `APP_KEY` depois:** as sessões caem e o que foi cifrado no banco fica ilegível.
5. `docker compose up -d --build`. A primeira subida cria o banco e as lojas. Os erros `relation "cache" does not
   exist` dessa primeira vez são normais, porque aparecem antes das migrações.
6. **Primeiro admin**, pela linha de comando (não use `APP_USER_PASSWORD`: a imagem imprime a senha no log):

   ```bash
   docker exec -it pricebuddy php artisan make:filament-user
   docker exec -it pricebuddy php artisan user:assign-role <seu-email> admin
   ```

7. Entre em `https://baratinho.<domínio>` e, em **Settings**:
   - locale `pt_BR` e moeda `BRL`;
   - **e-mail** (em *Notifications → Email*): host `smtp`, porta `25`, sem criptografia, sem usuário e senha, e o
     remetente aceito pelo seu provedor (o mesmo `From` do Authentik). Quem fala com o provedor é o relay, com o login
     do `.env`.

## Usuários

- **Contas:** o admin cria em **Users** (ou com `make:filament-user`). Não há cadastro aberto. Use o mesmo e-mail do
  Authentik, para ficar fácil de saber quem é quem.
- **Papéis:** `admin` (configurações, usuários, apagar lojas) e `user` (o padrão: os próprios produtos, tags e avisos).
  Para trocar: editar em **Users** ou `php artisan user:assign-role <email> admin|user`.
- **Avisos:** cada pessoa liga os dela em *Notification Settings* (tópico do ntfy, chat do Telegram etc.). O admin
  configura os serviços em **Settings**.
- **Tirar alguém:** remova a pessoa do grupo `pricebuddy_users` (perde o acesso na hora) e, se quiser, apague a conta
  em **Users**.

## Lojas brasileiras

A imagem só traz lojas dos EUA e da Austrália. O [`lojas/brasil.php`](lojas/brasil.php) tem 52 lojas brasileiras (51 testadas e o Mercado Livre),
montado na imagem. Numa instalação nova, ele já é o padrão (`PRICEBUDDY_STORES_COUNTRY=brasil`). Numa que já existe:

```bash
./lojas/trocar-lojas.sh --ver   # o que faria
./lojas/trocar-lojas.sh         # remove as dos EUA e da Austrália sem produto e cria/atualiza as brasileiras
```

O script pode rodar de novo depois de mudar o `brasil.php`: ele atualiza as lojas que já existem. Loja dos EUA ou da
Austrália com produto cadastrado fica, com um aviso.

| Grupo | Lojas |
|---|---|
| Gerais | Amazon Brasil, Mercado Livre (com a sua conta), Magazine Luiza, Casas Bahia, Americanas, Carrefour |
| Tecnologia e escritório | KaBuM!, Pichau, Terabyte, Fast Shop, Samsung Brasil, Kalunga |
| Livros | Estante Virtual, Leitura, Travessa, Martins Fontes Paulista, Vozes, Livraria da Vila, Livrarias Curitiba, Loyola, Traça (sebo) |
| Editoras e quadrinhos | Companhia das Letras, Record, Rocco, Sextante, Aleph, Ubu, DarkSide, Paulus, Paulinas, Pipoca & Nanquim, Panini |
| Jogos | Bravo Jogos, Galápagos Jogos (tabuleiro); Nuuvem, Steam (PC) |
| Casa e ferramentas | Leroy Merlin, Tok&Stok, Mobly, MadeiraMadeira, Casa&Video, Loja do Mecânico |
| Esporte | Decathlon |
| Farmácia e beleza | Drogasil, Droga Raia, Época Cosméticos, O Boticário, Sephora |
| Pet e brinquedos | Petz, Cobasi, Ri Happy, PBKids |

Cada loja foi testada em nov/2026 com um produto real, pelo proxy de saída, e o preço gravado conferido. A
configuração usa os dados estruturados da página (`schema_org`) sempre que possível, porque eles mudam menos que o
visual. Treze lojas precisam do Chrome (`api`), por causa de JavaScript ou de bloqueio a robô.

O **Mercado Livre** está na lista, mas só funciona com a sua conta ([Mercado Livre](#mercado-livre-com-a-sua-conta)).

**Ficaram de fora** (bloqueiam robô, testado): AliExpress (captcha de
arrastar, mesmo pelo Chrome), Shopee, Netshoes (Access Denied), Ponto e Extra (página de erro). Shoptime e Submarino
redirecionam para a Americanas. Intrínseca, Editora 34 e Todavia não mostram preço na página do livro (mandam para
parceiras); Livraria Cultura e Nobel não responderam direito. Lojas de moda (Renner, Riachuelo, Dafiti, Zattini) não foram testadas.

**Outras lojas:** ao cadastrar um produto de uma loja que não está na lista, o PriceBuddy tenta detectar a configuração
sozinho. Se uma loja parar de funcionar (o site mudou), troque o *scraper service* dela para `api` em **Stores**, ou
ajuste o `brasil.php` e rode o script de novo.

## Busca automática nas outras lojas

Cadastrou um produto (de qualquer loja)? Em até ~10 minutos o **buscador** procura o mesmo item nas outras lojas
cadastradas e acrescenta ao produto as que baterem, sem nada a fazer. Ele roda num container próprio
(`pricebuddy-buscador`, mesma imagem do app): o comando [`buscador/BaratinhoBuscar.php`](buscador/BaratinhoBuscar.php)
e as classes de [`buscador/Baratinho/`](buscador/Baratinho/), montadas em `app/Baratinho`.

Como decide:

1. Lê a página da primeira URL do produto e tira os **identificadores**: ISBN (livros), EAN/GTIN e código do
   fabricante, dos dados estruturados ou do texto, conferidos pelo dígito verificador.
2. Procura no **SearXNG** pelo ISBN (ou EAN) e pelo título, e também **dentro das lojas com mais chance** de ter o
   produto (`site:kabum.com.br <título>`): as que já vendem produtos de títulos parecidos
   (`PRICEBUDDY_BUSCA_SITE_LOJAS`, 4).
3. Fica com **páginas de produto** de lojas cadastradas que o produto ainda não tem. Saem: listagens (busca,
   categoria, página inicial), arquivos (PDF...) e URLs que você tirou do produto. Sites desconhecidos ficam anotados
   para classificar (abaixo).
4. Lê cada candidata com a configuração da loja e compara ([`Comparador.php`](buscador/Baratinho/Comparador.php)):
   - **identificador**: mesmo ISBN ou mesmo EAN, aceita; ISBN ou EAN diferente, recusa;
   - **recusa certa**: preço fora de 0,3×–3× o do produto (acessório, kit), usado/recondicionado/vitrine, outra
     quantidade (kit com 2 × unidade), outro número de modelo (RTX **5060** × **5070**; `AFN-40-BI` e `AFN40BI` contam como o mesmo), outra medida (**240** ×
     **480 GB**, **127** × **220 V**; 110 e 127 V contam como iguais);
   - **mesmo código do fabricante** sem conflito, aceita;
   - **título** com 60% das palavras e pelo menos 3 em comum, aceita;
   - **dúvida** (título parecido, mas não o bastante, ou sem o número do modelo): pergunta à **IA local**. Sem IA,
     fica de fora.
5. Acrescenta com o mesmo caminho da tela do app (`Url::createFromUrl`).

Testado em nov/2026, com a stack inteira e o `gemma3:4b`: o *1984* da Amazon ganhou Companhia das Letras, Martins
Fontes, Magalu, Mercado Livre, Travessa e KaBuM (as duas últimas pelo ISBN); o SSD A400 240 GB ganhou KaBuM e Magalu,
e a IA recusou um SSD "240 GB Kingston" sem o modelo. As regras (veredito de página, comparador, quantidade, EAN,
listagens) têm 64 casos de teste ([`buscador/testes/`](buscador/testes/), `./buscador/testes/rodar.sh`).

O que já foi procurado fica na tabela `baratinho_buscas`. Depois de `PRICEBUDDY_BUSCA_REFAZER_DIAS` (30), o produto
é procurado de novo, para achar lojas novas.

```bash
docker logs -f pricebuddy-buscador                                        # o que ele decidiu, loja por loja
docker exec pricebuddy-buscador php artisan baratinho:buscar --produto=12 --simular -v   # um produto, sem gravar
docker exec pricebuddy-buscador php artisan baratinho:buscar --produto=12               # procura de novo agora
```

**SearXNG** (`pricebuddy-searxng`): metabuscador próprio, só na rede interna, saindo pelo proxy. Motores em
[`searxng/settings.yml`](searxng/settings.yml): Bing, DuckDuckGo, Mojeek e Startpage (Google, Brave e Qwant recusam
um IP doméstico). Quando um motor pede captcha e a resposta demora, o buscador espera até 60 s e tenta de novo uma vez.

### Loja ou notícia: os sites que aparecem nas buscas

Notícia, blog, review, comparador ou classificado também mostram preço, e a pesquisa do app os listava como se
fossem lojas. Agora cada site que aparece nas buscas (do buscador e da tela do app) é classificado uma vez e a
decisão fica guardada (tabela `baratinho_dominios`):

1. **Lista fixa** ([`Listas.php`](buscador/Baratinho/Listas.php)): portais de notícia, sites de tecnologia,
   comparadores, redes sociais, classificados, acadêmicos.
2. **Regras da página** ([`Pagina.php`](buscador/Baratinho/Pagina.php)): dados estruturados de produto com oferta,
   `og:type product`, botão de compra → loja; `NewsArticle`/`Article`/`Review`, `og:type article`, data de
   publicação, sem carrinho próprio → notícia; preço em outra moeda → fora.
3. **IA local**, só quando as regras não decidem: loja, notícia, comparador, outro ou bloqueio.

Página de verificação de robô, captcha ou erro não decide nada: o site é tentado de novo depois, com outro endereço
(e pelo navegador do scraper, para sites que só funcionam com JavaScript). São
`PRICEBUDDY_BUSCA_DOMINIOS_POR_RODADA` (5) sites por rodada, os mais vistos primeiro.

```bash
docker exec pricebuddy-buscador php artisan baratinho:dominio                    # decisões, mais vistos primeiro
docker exec pricebuddy-buscador php artisan baratinho:dominio --tipo=noticia     # só um tipo
docker exec pricebuddy-buscador php artisan baratinho:dominio exemplo.com.br loja    # corrige (fica "manual")
docker exec pricebuddy-buscador php artisan baratinho:dominio exemplo.com.br pendente  # classifica de novo
```

Os sites classificados como **loja** que ainda não estão cadastrados viram lojas novas (abaixo).

### Lojas novas automáticas

Um site classificado como loja, que aparece numa busca com a página de um produto, vira loja cadastrada no PriceBuddy
sozinho ([`LojasNovas.php`](buscador/Baratinho/LojasNovas.php)):

1. Lê a página (leitura simples ou, se o site bloquear ou só funcionar com JavaScript, pelo navegador do scraper).
2. Exige preço em R$ (site em outra moeda vira "outro") e anúncio de produto novo.
3. O **AutoCreateStore** do próprio PriceBuddy descobre as regras de título, preço e imagem.
4. Valida antes de salvar: lê o produto duas vezes com a loja ainda não salva; precisa de título e do mesmo preço nas
   duas. Se a leitura simples do PriceBuddy falhar, tenta pelo navegador.
5. Salva com o nome do site (`og:site_name`, o fim do título da página ou o domínio) e uma nota em **Notes** dizendo
   que foi criada pelo Baratinho, a partir de que página.
6. A página que originou a loja passa pelo comparador, como qualquer outra: se for o mesmo produto, entra nele.

Até `PRICEBUDDY_LOJAS_NOVAS_POR_RODADA` (3) por rodada; `0` desliga. Site que não deu para criar ("recusada": leitura
instável, sem regra detectável) é tentado de novo depois de 30 dias.

**Saúde:** cada loja automática é testada uma vez por dia (a página de teste e, se falhar, outra URL dela). Três dias
seguidos sem preço a **desativam**: o buscador para de usá-la e tira dos produtos as URLs que ele mesmo pôs nela (para
não ficar preço velho). A loja continua em **Stores**, com o motivo nas notas, para consertar à mão.

```bash
docker exec pricebuddy-buscador php artisan baratinho:lojas                           # ativas, desativadas, recusadas
docker exec pricebuddy-buscador php artisan baratinho:lojas reativar exemplo.com.br   # depois de consertar a loja
docker exec pricebuddy-buscador php artisan baratinho:lojas tentar exemplo.com.br     # recusada: tenta de novo já
```

Testado em nov/2026 com uma fritadeira e um SSD: 7 lojas criadas (Mondial, Lognet, Medina Distribuidora, Biostech,
KingstonStore, Smarteletron, maiscorreios), 4 já entraram no SSD e a Mondial na fritadeira; Zema e MGS Shop recusadas
(preço mudando entre as leituras); um site japonês ficou de fora pela moeda; uma loja com a regra de preço quebrada de
propósito foi desativada no terceiro dia, com a URL tirada do produto.

### Resumo semanal

Uma vez por semana, os admins do PriceBuddy recebem por e-mail (o mesmo SMTP de **Settings → Notifications → Email**)
as lojas criadas, desativadas e recusadas, e quantos sites foram classificados. Sem e-mail ligado no app, não envia.

```bash
docker exec pricebuddy-buscador php artisan baratinho:resumo            # mostra, sem enviar
docker exec pricebuddy-buscador php artisan baratinho:resumo --enviar   # envia agora
```

### Pesquisa do app filtrada

A tela **Criar produto → buscar na web** não fala mais direto com o SearXNG: o buscador aponta a configuração dela
para o **filtro** ([`buscador/filtro.php`](buscador/filtro.php), `http://buscador:8081/search`), que repassa a busca
e tira notícias, comparadores, redes sociais, listagens e arquivos. Site ainda não classificado continua aparecendo
(e entra na fila). Nos testes, o filtro tirou de 7 a 15 dos ~35 resultados de cada busca. O filtro não grava nos logs
o que foi pesquisado.

Um endereço posto à mão em **Settings → SearXNG** (outro que não o da stack) é respeitado.

### IA local (Ollama)

O buscador usa o Ollama da stack `ollama` (a GPU), com o mesmo modelo do Berganews (`gemma3:4b`, que já fica baixado
para ele), para não trocar de modelo na GPU a cada pergunta. Só pergunta nos casos de dúvida, no máximo
`PRICEBUDDY_IA_POR_RODADA` (20) vezes por rodada, com resposta em JSON de formato fixo; a mesma pergunta nunca vai duas
vezes (tabela `baratinho_ia`). Com o Ollama fora do ar, o buscador segue sem IA: os casos de dúvida ficam de fora.

O buscador não tem internet, e a rede `bergatrix-ai` tem (para o `ollama pull`). Por isso ele não entra nela: fala
com a **ponte** `pricebuddy-ia` ([`ia/nginx.conf`](ia/nginx.conf)), um nginx que é o único da stack nas duas redes e
só deixa passar conversa com um modelo já baixado (`/api/chat`, `/api/generate`, e a lista de modelos). Baixar, apagar
ou criar modelo dá 403.

Desligar a IA: `PRICEBUDDY_IA_URL=` (vazio) no `.env`.

## Mercado Livre (com a sua conta)

O ML recusa robô sem login: a página do produto vira uma verificação ("tráfego suspeito") ou uma tela "Continuar"
sem preço. A loja já está cadastrada; falta a sua sessão:

1. No navegador, entre no [mercadolivre.com.br](https://www.mercadolivre.com.br) com a sua conta e abra um produto.
2. Exporte os cookies para um arquivo no servidor, de um destes jeitos:
   - uma extensão como *Get cookies.txt LOCALLY* → exportar `cookies.txt` (formato Netscape, uma linha por cookie);
   - ou F12 → **Rede** → recarregue → clique no primeiro pedido (`www.mercadolivre.com.br`) → em **Cabeçalhos da
     requisição**, copie o valor inteiro de **Cookie** para um arquivo.
3. Grave na loja e apague o arquivo:

   ```bash
   ./lojas/cookies-loja.sh ~/cookies.txt && rm ~/cookies.txt
   ```

   O script converte para a linha única `nome=valor; nome2=valor2`, que é o que o PriceBuddy manda no cabeçalho
   `Cookie`. Ele também descarta os cookies vencidos e os de outros sites. **Não cole o `cookies.txt` inteiro no campo
   Cookies da tela:** com várias linhas, o pedido ao scraper quebra e não vem nem título.
4. Em **Stores → Mercado Livre → Scraper service settings**, ponha o User-Agent do mesmo navegador (o ML amarra a
   sessão a ele; aparece em F12 → Rede → **Cabeçalhos da requisição** → `User-Agent`, ou em
   `navigator.userAgent` no Console), e uma espera para o JavaScript da página:

   ```
   user-agent=Mozilla/5.0 (...) Chrome/... Safari/537.36
   sleep=3000
   ```
5. Teste com um produto:

   ```bash
   ./lojas/testar-loja.sh 'https://www.mercadolivre.com.br/.../p/MLB...'
   ```

   Título e preço preenchidos: pronto, o ML passa a valer para os produtos e para o buscador. Título sem preço: troque
   o preço da loja para `schema_org` em **Stores**. "Verificação de robô": os cookies não foram aceitos ou venceram.

**Cuidado:** esses cookies são a sua sessão do ML. Ficam no banco do PriceBuddy (e no backup), e qualquer admin do
PriceBuddy os vê na tela da loja. Quando o ML encerrar a sessão (troca de senha, "sair de todos os dispositivos" ou o
tempo), repita os passos. Quando a aplicação oficial sair (falando com o suporte do ML), dá para trocar por ela.

## Particularidades

- **Log:** o `/start-app.sh` da imagem roda `printenv`. O compose roda o mesmo script sem essa linha, para a senha do
  banco e a `APP_KEY` não irem para o Loki. Ao atualizar a imagem, confira se o script mudou
  (`docker run --rm --entrypoint cat jez500/pricebuddy:<versão> /start-app.sh`).
- **Scraper com cookies:** o endpoint `/api/article` da imagem `seleniumbase-scrapper` lê `extra-http-headers` (por
  onde o PriceBuddy manda os cookies da loja) e `user-agent`, mas não aplica nenhum dos dois ao Chrome, e o cache dele
  não distingue cookies. [`scraper/article.py`](scraper/article.py) é a cópia da v1.0.1 com as duas correções
  (procure `_bergatrix` e `Bergatrix:`), montada por cima da original. Ao atualizar a imagem, veja se o original já
  corrigiu; se não, copie o novo (`docker run --rm --entrypoint cat jez500/seleniumbase-scrapper:<versão>
  /SeleniumBase/api/endpoints/article.py`) e reaplique os trechos.
- **Avisos com id fixo:** o app cria avisos com ids de texto (`searchJobDispatched`, `url_updated`...), e o Filament
  procura o id na coluna `uuid` de `notifications`: no Postgres, a página dá 500 (pesquisa, atualizar URL etc.). O
  `command` do compose troca todos por ids gerados (`sed` na subida; nenhum id é usado em outro lugar, e não tem
  efeito se a versão nova já corrigir). Uma pesquisa presa em "em andamento" sai com
  `docker exec pricebuddy php artisan cache:clear`.
- **Afiliados:** `PRICEBUDDY_AFFILIATE_ENABLED=true` troca links da Amazon (EUA/Austrália) e do eBay pelos do autor do
  projeto, para apoiá-lo. Fica desligado por padrão.
- **Backup:** o banco tem a label `bergatrix.backup.dump=postgres`. O `storage` (logs e imagens) entra na cópia do
  `APPDATA_PATH`.
- **Comandos úteis:** `php artisan buddy:fetch-all` (busca todos os preços agora) e `php artisan buddy:regenerate-price-cache`.
