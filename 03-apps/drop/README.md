# Drop

Passa senhas, textos (até 16 KiB) e arquivos (até 25 MiB por envio) entre dois dispositivos, cifrados no navegador. O servidor é um relay cego: não vê o código, a chave nem o conteúdo, e nada vai para o disco.

Endereço: `drop.${DOMAIN}`. Público e sem conta, por decisão ([05-acesso.md](../../docs/05-acesso.md)).

## Como funciona

1. **Receber** gera um código de 20 símbolos (100 bits) e mostra o código e um QR com o link `https://drop.<domínio>/#code=…`. O código fica no `#`, que o navegador não envia ao servidor.
2. O navegador passa o código por HKDF-SHA256 e tira dele duas coisas independentes:
   - o **ID da sala**, que vai ao servidor;
   - a **chave AES-256-GCM**, que nunca sai do navegador.
3. **Enviar**, no outro dispositivo, lê o QR ou recebe o código digitado, deriva a mesma chave e entra na sala.
4. Cada mensagem vira um frame binário: `versão | IV | AES-GCM(mensagem)`.
   - Os dados associados amarram o frame à sala e ao lado que o mandou: o servidor não consegue devolvê-lo nem trocá-lo de sala.
   - Textos têm padding por faixas de tamanho.
   - Arquivos vão em pedaços de 64 KiB, sempre cheios, com SHA-256 conferido no destino.
5. O receptor confirma cada item, também cifrado. O emissor só mostra **Entregue e conferido** depois disso.

O protocolo está em [`app/static/assets/js/protocol.js`](app/static/assets/js/protocol.js), e o relay em [`app/server.py`](app/server.py).

### Inverter

Com os dois conectados, qualquer um pode tocar em **Inverter** para trocar quem envia e quem recebe. O outro precisa tocar em **Aceitar e inverter**. Sem resposta em 30 segundos, o pedido cai.

- **Lugar e papel são coisas separadas.** O lugar na sala (quem criou e quem entrou) não muda, e é ele que vai nos dados associados de cada frame. Só o papel na tela troca. O servidor não fica sabendo da inversão: é tudo combinado em mensagens `SWAP` cifradas.
- **Pedido → aceite → confirmação.** Quem pediu só troca ao mandar a confirmação, e o outro só troca ao recebê-la. Como os frames chegam em ordem, os dois nunca ficam enviando ao mesmo tempo.
- **Contador de inversões.** O papel vem da paridade dele. Ao reconectar, os dois trocam o contador, e o maior vale. Assim uma confirmação perdida não deixa os dois com o mesmo papel.
- **Só sem nada em andamento:** com um envio ou recebimento no meio, o pedido é recusado.
- **O que estava na tela some:** os itens recebidos, o texto e os arquivos escolhidos. Os dois lados são avisados antes de aceitar.

### Limites

| O quê | Limite |
|---|---|
| Sessão | 10 minutos a partir da criação, sem renovação |
| Texto | 16 KiB |
| Arquivos | 25 MiB e 20 arquivos por envio; 40 MiB por sessão, somando os dois sentidos (também depois de inverter) |
| Salas | 256 no total, 4 por IP |
| Frame | 66 KiB (WebSocket) |
| Página | 60 pedidos/min por IP, com rajada de 30 (Traefik) e CrowdSec |

Na tela do receptor, textos somem em 2 minutos e arquivos em 5. Recarregar a página mantém a sessão, mas não os itens recebidos.

## Segurança

- **Rede isolada:** o container fica só na rede `bergatrix-drop`, que é `internal` e fica em [`01-network/redes`](../../01-network/redes/docker-compose.yml). Ele não alcança outros containers, a rede de casa, a internet nem o DNS externo. Só o Traefik chega até ele.
- **Container:**
  - read-only, `cap_drop: ALL`, `no-new-privileges` e usuário 10001;
  - código do root e sem permissão de escrita;
  - sem pip na imagem;
  - dependências com hash (`--require-hashes`, só wheels).
- **Página:**
  - tudo servido pelo próprio Drop (fontes e bibliotecas em [`assets/vendor`](app/static/assets/vendor/README.md));
  - CSP `default-src 'none'`, com scripts só de `'self'`;
  - Trusted Types (`innerHTML` bloqueado);
  - COOP, COEP e CORP;
  - WebSocket só da mesma origem.
- **Arquivos recebidos** viram download (`application/octet-stream`). O navegador não os abre dentro do Drop.

O que a criptografia **não** protege: um servidor comprometido pode trocar o `app.js` que entrega e capturar o código e o conteúdo. O navegador, o sistema e o histórico da área de transferência também podem guardar cópias. O código é a credencial da sessão: mostre só para quem vai enviar.

### Texto e quebras de linha

O campo de texto segue a especificação do HTML: quebras `\r\n` viram `\n`. O resto chega byte a byte (emoji, acentos, tabs, aspas, espaços nas pontas). Para manter um arquivo exatamente igual, como um `.env` do Windows, mande como **arquivo**.

## Subir

```bash
# Uma vez: cria a rede bergatrix-drop e liga o Traefik a ela
cd ~/bergatrix/01-network/redes && docker compose run --rm redes
cd ~/bergatrix/01-network/traefik && docker compose up -d
cd ~/bergatrix/03-apps/drop && cp .env.example .env   # só o DOMAIN
docker compose up -d --build
```

## Testes

```bash
# Relay (precisa de starlette, uvicorn, websockets e httpx)
PYTHONPATH=app python -m unittest discover -s tests
# Protocolo e QR (Node 20+)
node --test tests/*.test.mjs
```

## Atualizar dependências

- **Python:** edite o `requirements.in` e rode `pip-compile --generate-hashes --strip-extras requirements.in`.
- **Bibliotecas do navegador:** siga o [`assets/vendor/README.md`](app/static/assets/vendor/README.md).
