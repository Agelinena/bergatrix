# Redes Docker

Como os containers se enxergam. Cada rede é uma porta: um serviço só alcança quem está numa rede em comum com ele. Por isso cada serviço entra só nas redes de que precisa.

## As redes

### Compartilhadas (entre stacks)

Ficam em [`01-network/redes/docker-compose.yml`](../01-network/redes/docker-compose.yml) e são criadas antes de qualquer stack.

| Rede | Quem entra | Internet |
|---|---|---|
| `bergatrix-proxy` | O Traefik, os serviços **com rota** e o CrowdSec, que o Traefik consulta | Sim |
| `bergatrix-media` | Jellyfin, Seerr, *arr, SABnzbd, qBittorrent, indexadores, Legendarr e o Lidarr do bergastream | Sim |
| `bergatrix-ldap` | O outpost LDAP do Authentik e os apps que fazem login por LDAP (Jellyfin) | Não |
| `bergatrix-ai` | O Ollama e quem usa ele (worker do Legendarr, worker `ai` do Berganews) | Sim |
| `bergatrix-drop` | Só o Traefik e o Drop. O Drop é público, então fica fora da `bergatrix-proxy`: não alcança nenhum outro container | Não |
| `bergatrix-office` | Só o Traefik e o Collabora (editor de documentos do Nextcloud). O Traefik tem nela o alias `storange.${DOMAIN}`, que é como o Collabora chega ao Nextcloud | Não |

### Da própria stack

Declaradas no compose da stack e usadas só por ela.

| Rede | Para quê | Como declarar |
|---|---|---|
| `<stack>-internal` | Banco, Redis e serviços internos | `name: <stack>-internal` e `internal: true` |
| `<stack>-egress` | Serviço interno que precisa de internet, mas não do Traefik | `name: <stack>-egress` |

Hoje existem: `authentik-internal`, `berganews-internal`, `berganews-egress`, `bergastream-internal`, `bergastream-egress`, `bergalink-internal`, `transcriptor-internal`, `transcriptor-egress`, `immich-internal`, `immich-egress`, `nextcloud-internal`, `nextcloud-egress` e a rede padrão do Wazuh.

No Transcriptor, o worker (que baixa links enviados pelas pessoas) fica só na `transcriptor-internal` e sai para a internet por um proxy (smokescreen) que recusa destinos em redes privadas. É o modelo para qualquer serviço que busque URLs vindas de usuários, e o Berganews o segue (feeds, páginas e imagens cadastrados pelas pessoas).

### Collabora (editor de documentos do Nextcloud)

O Collabora abre documentos enviados pelas pessoas, e um documento malicioso mira o próprio editor. Por isso ele fica só na `bergatrix-office`, que é `internal: true`, e não na `bergatrix-proxy`. Ele usa dois caminhos:

- **Navegador → Collabora**, por `office.${DOMAIN}`, pelo Traefik.
- **Collabora → Nextcloud** (WOPI, para ler e gravar o arquivo), por `storange.${DOMAIN}`. Como a rede não tem internet nem o Nextcloud, o Traefik entra nela com o alias `storange.${DOMAIN}`: o Collabora resolve o endereço público para o próprio Traefik, que encaminha ao Nextcloud pela rota normal, com o CrowdSec.

O Nextcloud chega ao Collabora pelo endereço público (`wopi_url`), então não entra na `bergatrix-office`. Se o alias sumir do Traefik, o editor abre em branco ou não salva.

```yaml
# No serviço do Traefik
services:
  traefik:
    networks:
      bergatrix-proxy: {}
      bergatrix-office:
        aliases:
          - storange.${DOMAIN}

networks:
  bergatrix-office:
    external: true
```

## Regras

- **Rede compartilhada só no arquivo de redes.** A stack usa a rede com `external: true` e nunca a cria.
- **Rede que só uma stack usa fica na stack**, com o nome `<stack>-internal` ou `<stack>-egress`.
- **Serviço público sem conta tem rede própria com o Traefik** (`bergatrix-drop`), e não entra na `bergatrix-proxy`.
- **Serviço que processa arquivos enviados pelas pessoas** (hoje, o Collabora) também tem rede própria com o Traefik (`bergatrix-office`), sem internet.
- **`bergatrix-proxy` é só para quem tem rota no Traefik.** Um serviço sem labels do Traefik não entra nela. Para falar com outra stack, use a rede do assunto (`bergatrix-media`, `bergatrix-ai`…).
- **O banco nunca fica numa rede compartilhada.** Ele fica só na `<stack>-internal`.
- **`internal: true` sempre que der:** a rede não tem saída para a internet.
- **O nome do container é o endereço.** Quem está na mesma rede chama `http://<container_name>:<porta>`. Mudar o nome quebra quem depende dele (veja as [dependências](01-infraestrutura.md#dependências-entre-stacks)).

## Usar uma rede numa stack

```yaml
services:
  app:
    networks:
      - minhaapp-internal   # banco da própria stack
      - bergatrix-proxy     # tem rota no Traefik
      - bergatrix-media     # fala com os *arr

networks:
  minhaapp-internal:
    name: minhaapp-internal
    internal: true
  bergatrix-proxy:
    external: true
  bergatrix-media:
    external: true
```

Quem está em mais de uma rede e tem rota precisa da label `traefik.docker.network=bergatrix-proxy`, para o Traefik saber por qual rede chegar.

## Criar uma rede compartilhada nova

Só quando duas ou mais stacks precisam conversar e nenhuma rede existente serve.

1. Acrescente a rede em [`01-network/redes/docker-compose.yml`](../01-network/redes/docker-compose.yml), em `networks:` e na lista do serviço `redes`. Use o nome `bergatrix-<assunto>`, `name:` igual à chave, e `internal: true` se ninguém precisar de internet por ela.
2. Nas stacks que vão usar a rede, acrescente-a ao serviço e declare-a com `external: true`.
3. Atualize a tabela [As redes](#as-redes) deste documento.
4. No servidor, crie a rede e recrie as stacks:
   ```bash
   cd ~/bergatrix/01-network/redes && docker compose run --rm redes
   cd ~/bergatrix/<stack> && docker compose up -d
   ```

**Mudar uma rede que já existe** (nome, `internal` ou driver) exige recriá-la, e o Docker só remove uma rede sem containers ligados. Derrube tudo, apague a rede e suba de novo:

```bash
./00-infrastructure/derrubar-tudo.sh
docker network rm <rede>
./00-infrastructure/subir-tudo.sh
```

## Conferir

```bash
# Quem está numa rede
docker network inspect bergatrix-proxy --format '{{range .Containers}}{{.Name}} {{end}}'

# Em que redes um container está
docker inspect jellyfin --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

## Migração para estas redes (uma vez, out/2026)

Antes, quase tudo ficava na `bergatrix-proxy`, e a rede de mídia (`media-internal`) era criada pela stack do jellyfin. Para aplicar no servidor:

```bash
cd ~/bergatrix
./00-infrastructure/derrubar-tudo.sh
# Recriar a bergatrix-proxy pelo arquivo de redes (antes era criada à mão)
# e apagar a rede de mídia antiga
docker network rm bergatrix-proxy media-internal
./00-infrastructure/subir-tudo.sh
```

Se a `bergatrix-proxy` não for recriada, tudo funciona do mesmo jeito. O Compose só avisa, a cada subida, que ela não foi criada por ele.

## Migração para a `bergatrix-office` (uma vez, out/2026)

Antes, o Collabora ficava na `bergatrix-proxy`. A ordem importa: o Traefik precisa do alias antes de o Collabora sair da rede antiga.

```bash
# 1. Criar a rede (depois de acrescentá-la ao 01-network/redes/docker-compose.yml)
cd ~/bergatrix/01-network/redes && docker compose run --rm redes

# 2. Traefik entra na rede com o alias (interrompe as rotas por alguns segundos)
cd ~/bergatrix/01-network/traefik && docker compose up -d

# 3. Testar o caminho que o Collabora vai usar, antes de movê-lo (esperado: 200)
docker run --rm --network bergatrix-office curlimages/curl \
  -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://storange.<domínio>/status.php

# 4. Mover o Collabora (só ele)
cd ~/bergatrix/03-apps/nextcloud && docker compose up -d collabora
```

Conferir: `docker inspect nextcloud-collabora --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'` deve listar só `bergatrix-office`. Depois, abrir e salvar um documento.

Se o passo 3 não responder 200, o Traefik não está aceitando a conexão interna. Como alternativa, tire o `internal: true` da `bergatrix-office` e o alias: o Collabora continua isolado dos outros containers e chega ao Nextcloud pelo caminho público.