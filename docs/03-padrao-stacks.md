# Padrão de stacks

Guia base para criar ou ajustar qualquer stack da Bergatrix. Os modelos prontos ficam em [`templates/`](templates/).

Se uma stack existente foge de alguma regra, ela está listada em [Dívidas conhecidas](#dívidas-conhecidas). As exceções ficam registradas, em vez de virarem regra nova.

## Estrutura do repositório

```
<camada>/<stack>/
├── docker-compose.yml     obrigatório
├── .env.example           obrigatório: todas as variáveis que o compose usa, sem valores reais
├── README.md              recomendado: o que é, como subir, particularidades
└── app/ | backend/ | frontend/   código próprio, quando houver
```

| Camada | Para quê |
|---|---|
| `00-infrastructure` | Ferramentas de base (CloudBeaver), a ordem das stacks e os scripts de subir e derrubar tudo |
| `01-network` | Entrada de tráfego (Traefik) e redes compartilhadas |
| `02-security` | Identidade, segredos e proteção (Authentik, Vaultwarden, CrowdSec) |
| `03-apps` | Aplicações |
| `04-monitoring` | Observabilidade e segurança (Wazuh) |

**O nome da stack é o nome da pasta.** É o nome usado em `${APPDATA_PATH}/<stack>` e `${CACHE_PATH}/<stack>`. Renomear a pasta obriga a renomear essas pastas no servidor.

## Variáveis (`.env`)

Cada stack tem seu próprio `.env`, copiado do `.env.example`. O `.env` nunca vai para o git.

### Bloco base

Todo `.env.example` começa com o bloco base: **os mesmos nomes, na mesma ordem**, incluindo só as variáveis que a stack usa.

```bash
# ── Base Bergatrix ────────────────────────────────────────────
DOMAIN=example.com
TZ=America/Sao_Paulo
PUID=1000
PGID=1000
APPDATA_PATH=/srv/appdata
CACHE_PATH=/srv/cache
MEDIA_PATH=/mnt/nas/media
USERDATA_PATH=/mnt/nas/userdata
```

| Variável | Uso |
|---|---|
| `DOMAIN` | Domínio raiz. Os endereços são sempre `<subdomínio>.${DOMAIN}`. |
| `TZ` | Fuso horário dos containers. |
| `PUID` / `PGID` | Usuário e grupo que gravam os arquivos. |
| `*_PATH` | As raízes de [armazenamento](02-armazenamento.md). |

### Variáveis da stack

Depois do bloco base, uma seção por assunto (`# ── Banco ──`, `# ── <App> ──`, `# ── Serviços externos ──`).

| Regra | Exemplo |
|---|---|
| Prefixo com o nome do app | `VAULTWARDEN_ADMIN_TOKEN`, `TRANSCRIPTOR_API_KEY`, `OUTPOST_LDAP_TOKEN` |
| O Postgres próprio da stack usa os nomes da imagem oficial (um banco por stack, sem colisão) | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Serviços de terceiros usam o nome do serviço | `OPENROUTER_API_KEY`, `DESEC_TOKEN`, `HF_TOKEN`, `DEEMIX_ARL` |
| Variáveis lidas diretamente pelo app via `env_file` mantêm o nome que o app espera | `AUTHENTIK_*` e as configurações do Bergastream e do Legendarr |
| Endereço nunca é variável: o subdomínio fica escrito no compose | `Host(\`drop.${DOMAIN}\`)`, e não `${DROP_DOMAIN}` |
| Caminho nunca é variável própria: deriva de uma raiz | `${APPDATA_PATH}/transcriptor/data`, e não `TRANSCRIPTOR_DATA_DIR` |

### No compose

- **Raízes sempre com `:?`:** `${APPDATA_PATH:?}/minhastack/postgres`. Se a variável não estiver no `.env`, o compose para com erro, em vez de montar `/minhastack/postgres` na raiz do sistema.
- **Segredos sem valor padrão:** `${MINHAAPP_SECRET_KEY}`.
- **Ajustes com valor padrão** igual ao do código: `${SCAN_INTERVAL:-3600}`. Assim o `.env` só precisa ter o que muda.
- **Toda variável lida pelo app precisa ser repassada pelo compose** (em `environment:` ou `env_file:`). Se estiver só no `.env.example`, ela não chega ao container.

### Valores no repositório

O repositório é público. Nos `.env.example` e na documentação:

- domínio: `example.com`;
- IPs: `<ip-do-nas>`, `192.168.x.x`;
- segredos: vazios, com o comando para gerar ao lado (`openssl rand -hex 32`);
- e-mails e usuários: genéricos.

Valores reais (domínio, IPs, contas, passo a passo de configuração com dados) ficam no repositório privado.

## Volumes

As regras completas estão em [02-armazenamento.md](02-armazenamento.md). Em resumo:

```yaml
volumes:
  - ${APPDATA_PATH:?}/minhastack/app:/config       # config e banco
  - ${CACHE_PATH:?}/minhastack/cache:/cache        # recriável
  - ${MEDIA_PATH:?}/filmes:/media/filmes:ro        # só a subpasta necessária; :ro se só lê
```

- Monte só a subpasta que o container usa, nunca a raiz inteira (a exceção é o Jellyfin, que é a biblioteca).
- Use `:ro` quando o container só lê.
- Arquivos de configuração versionados no repositório (como `./config/traefik.yml:ro`) podem ser montados por caminho relativo. Dados gerados pelo container nunca ficam dentro do repositório.

## Redes

Regras completas e como criar uma rede em [06-redes.md](06-redes.md). Em resumo:

- Redes compartilhadas (`bergatrix-proxy`, `bergatrix-media`, `bergatrix-ldap`, `bergatrix-ai`) ficam em `01-network/redes` e entram na stack com `external: true`.
- A `bergatrix-proxy` é só para serviços com rota no Traefik.
- Banco e serviços internos ficam na `<stack>-internal` (`internal: true`). O banco nunca entra numa rede compartilhada.

## Containers

- **`container_name`:** `<stack>-<serviço>` (`bergastream-api`, `bergalink-db`), ou só `<stack>` quando a stack tem um serviço. Esse nome é o endereço DNS na rede.
- **`restart: unless-stopped`**, exceto jobs de uma vez (migrações): `restart: "no"`.
- **`security_opt: [no-new-privileges:true]`**, e rodar como usuário não-root quando a imagem permitir.
- **Imagem com versão fixa** (`postgres:16-alpine`, `traefik:v3.6.2`), nunca `latest` ou sem tag.
- **Ao fixar a versão de uma imagem que hoje roda em `latest`**, confira antes a versão em execução (`docker exec <container> ... --version` ou `docker image inspect`) e as releases do projeto. Fixar uma versão mais antiga do que a que está rodando é um **downgrade**: o banco já pode ter sido migrado, e os clientes mais novos podem parar de funcionar.
- **Banco com `healthcheck`**, e quem depende dele usa `depends_on: condition: service_healthy`.
- **Migrações** num serviço `migrate` (`dbmate`) que roda antes da API (`service_completed_successfully`).

## Acesso (Traefik e autenticação)

Regra e labels em [05-acesso.md](05-acesso.md). Em resumo:

- **Nenhum serviço fica sem Authentik na frente, nem na rede local.**
- O app entra por **OIDC**, por **LDAP** ou por **forward-auth**.
- Cada serviço tem uma rota só.
- Não se usam mais IPs fixos nem bypass em serviços do Docker.

## Checklist de stack nova

1. Pasta em `<camada>/<stack>/`, partindo dos [templates](templates/).
2. `.env.example` com o bloco base e todas as variáveis, sem valores reais.
3. Cada volume na raiz certa ([como decidir](02-armazenamento.md#como-decidir-onde-um-volume-vai)), com `:?`.
4. Imagens com versão fixa; banco com healthcheck e rede interna.
5. Acesso conforme [05-acesso.md](05-acesso.md): aplicação e grupo no Authentik, e rota no padrão certo.
6. Validar: `docker compose --env-file .env.example config --quiet`.
7. Redes conforme [06-redes.md](06-redes.md): rede compartilhada nova só no `01-network/redes`.
8. **Acrescentar a stack ao [`00-infrastructure/stacks.txt`](../00-infrastructure/stacks.txt)**, depois das stacks de que ela depende ([07-ligar-e-desligar.md](07-ligar-e-desligar.md)).
9. Criar as pastas no servidor com o dono certo antes do primeiro `up`.
10. Atualizar o [mapa por stack](02-armazenamento.md#mapa-atual-por-stack) e a tabela de stacks em [01-infraestrutura.md](01-infraestrutura.md).

## Dívidas conhecidas

Stacks existentes que ainda não seguem o padrão. Nenhuma delas impede a migração.

| Stack | Fora do padrão |
|---|---|
| várias | Imagens sem versão fixa: Jellyfin, *arr, SABnzbd, Deemix, Lidarr, CrowdSec, CloudBeaver, Ollama, FlareSolverr |
| várias | `container_name` antigos (`bitwarden`, `ollama`, `sonarr`…). Mantidos porque outras stacks os usam como endereço; mudam junto com a revisão de acesso. |
| homeassistant, transcriptor | Rotas antigas com IPs fixos, bypass e `public-auth`. Saem conforme o [plano de acesso](plano-acesso.md). |
| jellyfin | Legendarr (web, worker, optimizer) roda como root. O optimizer guarda `requires_redownload.txt` fora de volume. |
| bitwarden | O nome da pasta é `bitwarden`, mas o app é o Vaultwarden. |
| cloudbeaver | Ficou sem banco para acessar desde que o Postgres global saiu: cada stack tem o seu, em rede interna. |
| quase todas | Sem `README.md` próprio (só bergastream, bergalink e wazuh têm). |
