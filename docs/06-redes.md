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
| `bergatrix-ai` | O Ollama e quem usa ele (worker do Legendarr) | Sim |
| `bergatrix-drop` | Só o Traefik e o Drop. O Drop é público, então fica fora da `bergatrix-proxy`: não alcança nenhum outro container | Não |

### Da própria stack

Declaradas no compose da stack e usadas só por ela.

| Rede | Para quê | Como declarar |
|---|---|---|
| `<stack>-internal` | Banco, Redis e serviços internos | `name: <stack>-internal` e `internal: true` |
| `<stack>-egress` | Serviço interno que precisa de internet, mas não do Traefik | `name: <stack>-egress` |

Hoje existem: `authentik-internal`, `bergastream-internal`, `bergastream-egress`, `bergalink-internal`, `transcriptor-internal`, `transcriptor-egress`, `immich-internal`, `immich-egress`, `nextcloud-internal`, `nextcloud-egress` e a rede padrão do Wazuh.

No Transcriptor, o worker (que baixa links enviados pelas pessoas) fica só na `transcriptor-internal` e sai para a internet por um proxy (smokescreen) que recusa destinos em redes privadas. É o modelo para qualquer serviço que busque URLs vindas de usuários.

## Regras

- **Rede compartilhada só no arquivo de redes.** A stack usa a rede com `external: true` e nunca a cria.
- **Rede que só uma stack usa fica na stack**, com o nome `<stack>-internal` ou `<stack>-egress`.
- **Serviço público sem conta tem rede própria com o Traefik** (`bergatrix-drop`), e não entra na `bergatrix-proxy`.
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
