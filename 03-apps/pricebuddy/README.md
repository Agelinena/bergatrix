# PriceBuddy (baratinho)

Acompanha o preço de produtos em lojas online e avisa quando o preço cai. Cada pessoa tem a própria conta, com os
próprios produtos, tags e avisos. As lojas (como buscar título e preço em cada site) são compartilhadas.

Projeto: [jez500/pricebuddy](https://github.com/jez500/pricebuddy) · documentação: <https://pricebuddy.jez.me>.

| Serviço | O que faz | Redes |
|---|---|---|
| `app` | Interface (Filament), agendador e fila no mesmo container | `pricebuddy-internal`, `bergatrix-pricebuddy` (Traefik) |
| `scraper` | Chrome sem tela (SeleniumBase), para lojas que exigem JavaScript | só `pricebuddy-internal` |
| `egress` | Proxy de saída (smokescreen): recusa redes privadas | `pricebuddy-internal`, `pricebuddy-egress` |
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

4. **`.env`:** `cp .env.example .env` e preencha a senha do banco e a `PRICEBUDDY_APP_KEY` (os comandos estão no arquivo).
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

A imagem só traz lojas dos EUA e da Austrália. O [`lojas/brasil.php`](lojas/brasil.php) tem 36 lojas brasileiras,
montado na imagem. Numa instalação nova, ele já é o padrão (`PRICEBUDDY_STORES_COUNTRY=brasil`). Numa que já existe:

```bash
./lojas/trocar-lojas.sh --ver   # o que faria
./lojas/trocar-lojas.sh         # remove as dos EUA e da Austrália sem produto e cria/atualiza as brasileiras
```

O script pode rodar de novo depois de mudar o `brasil.php`: ele atualiza as lojas que já existem. Loja dos EUA ou da
Austrália com produto cadastrado fica, com um aviso.

| Grupo | Lojas |
|---|---|
| Gerais | Amazon Brasil, Magazine Luiza, Casas Bahia, Americanas, Carrefour |
| Tecnologia e escritório | KaBuM!, Pichau, Terabyte, Fast Shop, Samsung Brasil, Kalunga |
| Livros | Estante Virtual, Livraria Leitura, Livraria da Travessa, Martins Fontes Paulista, Livraria Vozes |
| Jogos | Bravo Jogos, Galápagos Jogos (tabuleiro); Nuuvem, Steam (PC) |
| Casa e ferramentas | Leroy Merlin, Tok&Stok, Mobly, MadeiraMadeira, Casa&Video, Loja do Mecânico |
| Esporte | Decathlon |
| Farmácia e beleza | Drogasil, Droga Raia, Época Cosméticos, O Boticário, Sephora |
| Pet e brinquedos | Petz, Cobasi, Ri Happy, PBKids |

Cada loja foi testada em nov/2026 com um produto real, pelo proxy de saída, e o preço gravado conferido. A
configuração usa os dados estruturados da página (`schema_org`) sempre que possível, porque eles mudam menos que o
visual. Treze lojas precisam do Chrome (`api`), por causa de JavaScript ou de bloqueio a robô.

**Ficaram de fora** (bloqueiam robô, testado): Mercado Livre (pede login/verificação), AliExpress (captcha de
arrastar, mesmo pelo Chrome), Shopee, Netshoes (Access Denied), Ponto e Extra (página de erro). Shoptime e Submarino
redirecionam para a Americanas. Lojas de moda (Renner, Riachuelo, Dafiti, Zattini) não foram testadas.

**Outras lojas:** ao cadastrar um produto de uma loja que não está na lista, o PriceBuddy tenta detectar a configuração
sozinho. Se uma loja parar de funcionar (o site mudou), troque o *scraper service* dela para `api` em **Stores**, ou
ajuste o `brasil.php` e rode o script de novo.

## Particularidades

- **Log:** o `/start-app.sh` da imagem roda `printenv`. O compose roda o mesmo script sem essa linha, para a senha do
  banco e a `APP_KEY` não irem para o Loki. Ao atualizar a imagem, confira se o script mudou
  (`docker run --rm --entrypoint cat jez500/pricebuddy:<versão> /start-app.sh`).
- **Afiliados:** `PRICEBUDDY_AFFILIATE_ENABLED=true` troca links da Amazon (EUA/Austrália) e do eBay pelos do autor do
  projeto, para apoiá-lo. Fica desligado por padrão.
- **Backup:** o banco tem a label `bergatrix.backup.dump=postgres`. O `storage` (logs e imagens) entra na cópia do
  `APPDATA_PATH`.
- **Comandos úteis:** `php artisan buddy:fetch-all` (busca todos os preços agora) e `php artisan buddy:regenerate-price-cache`.
