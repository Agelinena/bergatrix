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
(`pricebuddy-buscador`, mesma imagem do app) com o comando [`buscador/BaratinhoBuscar.php`](buscador/BaratinhoBuscar.php).

Como decide:

1. Lê a página da primeira URL do produto. Se for livro, tira o **ISBN** (dos dados estruturados ou do texto).
2. Procura no **SearXNG** pelo ISBN (livros) ou pelo título.
3. Fica só com resultados de **lojas cadastradas** que o produto ainda não tem. URLs que você tirou do produto não
   voltam.
4. Lê cada candidata com a configuração da loja e só aceita se for **o mesmo item**:
   - livros: a página tem o mesmo ISBN;
   - outros: título parecido (60% das palavras, pelo menos 3 em comum), os mesmos números de modelo (RTX **5060**,
     **SA400S37**) e as mesmas medidas (**240 GB**, **55"**, **127 V**);
   - em todos: preço entre 0,3× e 3× o do produto (corta acessório e kit).
5. Acrescenta com o mesmo caminho da tela do app (`Url::createFromUrl`).

Testado em nov/2026: um livro da Amazon (*1984*) ganhou KaBuM, Magalu, Travessa e Martins Fontes pelo ISBN; um SSD
de 240 GB ganhou Pichau, Terabyte, KaBuM e Leroy Merlin; 240×480 GB, 55×65", RTX 5060×5070, 127×220 V e uma capinha
de R$ 39 para um Echo Dot de R$ 399 foram recusados.

O que já foi procurado fica na tabela `baratinho_buscas` do banco. Depois de `PRICEBUDDY_BUSCA_REFAZER_DIAS` (30), o
produto é procurado de novo, para achar lojas novas. Ajustes no `.env`: intervalo, produtos por rodada e máximo de
lojas por produto.

```bash
docker logs -f pricebuddy-buscador                                        # o que ele decidiu, loja por loja
docker exec pricebuddy-buscador php artisan baratinho:buscar --produto=12 --simular -v   # um produto, sem gravar
docker exec pricebuddy-buscador php artisan baratinho:buscar --produto=12               # procura de novo agora
```

**SearXNG** (`pricebuddy-searxng`): metabuscador próprio, só na rede interna, saindo pelo proxy. Motores em
[`searxng/settings.yml`](searxng/settings.yml): Bing, DuckDuckGo, Mojeek e Startpage (Google, Brave e Qwant recusam
um IP doméstico). O buscador liga o SearXNG nas configurações do app sozinho, então a tela **Criar produto → buscar na
web** também passa a funcionar.

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
4. Se o ML amarrar a sessão ao navegador, em **Scraper service settings** da loja ponha
   `user-agent=<o User-Agent do mesmo navegador>` (aparece nos mesmos cabeçalhos).
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
- **Afiliados:** `PRICEBUDDY_AFFILIATE_ENABLED=true` troca links da Amazon (EUA/Austrália) e do eBay pelos do autor do
  projeto, para apoiá-lo. Fica desligado por padrão.
- **Backup:** o banco tem a label `bergatrix.backup.dump=postgres`. O `storage` (logs e imagens) entra na cópia do
  `APPDATA_PATH`.
- **Comandos úteis:** `php artisan buddy:fetch-all` (busca todos os preços agora) e `php artisan buddy:regenerate-price-cache`.
