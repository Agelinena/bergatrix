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
| `00-infrastructure` | Ferramentas de base (CloudBeaver) |
| `01-network` | Entrada de tráfego (Traefik) |
| `02-security` | Identidade, segredos e proteção (Authentik, Vaultwarden, CrowdSec) |
| `03-apps` | Aplicações |
| `04-monitoring` | Observabilidade (Homepage, Wazuh) |

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
| Prefixo com o nome do app | `VAULTWARDEN_ADMIN_TOKEN`, `TRANSCRIPTOR_API_KEY`, `OPENWEBUI_SECRET_KEY` |
| O Postgres próprio da stack usa os nomes da imagem oficial (um banco por stack, sem colisão) | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Serviços de terceiros usam o nome do serviço | `OPENROUTER_API_KEY`, `DESEC_TOKEN`, `HF_TOKEN`, `DEEMIX_ARL` |
| Variáveis lidas diretamente pelo app via `env_file` mantêm o nome que o app espera | `AUTHENTIK_*` e as configurações do Bergastream e do Legendarr |
| Endereço nunca é variável: o subdomínio fica escrito no compose | `Host(\`n8n.${DOMAIN}\`)`, e não `${N8N_DOMAIN}` |
| Caminho nunca é variável própria: deriva de uma raiz | `${APPDATA_PATH}/n8n/data`, e não `N8N_DATA_DIR` |

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

| Rede | Quem entra | Como declarar |
|---|---|---|
| `bergatrix-proxy` | Só os serviços com rota no Traefik ou que precisam falar com outra stack | `external: true` (criada uma vez: `docker network create bergatrix-proxy`) |
| `<stack>-internal` | Banco, Redis e serviços internos da stack | `name: <stack>-internal` e `internal: true` (sem internet) |
| `<stack>-egress` | Serviços internos que precisam de internet, mas não do Traefik | `name: <stack>-egress` |

O banco nunca fica na `bergatrix-proxy`.

## Containers

- **`container_name`:** `<stack>-<serviço>` (`bergastream-api`, `bergalink-db`), ou só `<stack>` quando a stack tem um serviço. Esse nome é o endereço DNS na rede.
- **`restart: unless-stopped`**, exceto jobs de uma vez (migrações): `restart: "no"`.
- **`security_opt: [no-new-privileges:true]`**, e rodar como usuário não-root quando a imagem permitir.
- **Imagem com versão fixa** (`postgres:16-alpine`, `traefik:v3.6.2`), nunca `latest` ou sem tag.
- **Banco com `healthcheck`**, e quem depende dele usa `depends_on: condition: service_healthy`.
- **Migrações** num serviço `migrate` (`dbmate`) que roda antes da API (`service_completed_successfully`).

## Acesso (Traefik e autenticação)

> **Em transição.** Hoje a maioria das stacks usa três rotas: Authentik por forward-auth, acesso direto para IPs de confiança e bypass em `/api-access-bypass` para apps mobile. O modelo está descrito em [legado/modelos-labels-traefik.md](legado/modelos-labels-traefik.md). Ele será substituído por **login OIDC do Authentik dentro de cada app**, e esta seção será reescrita.

Para apps novos, siga já o modelo de destino, que o Bergalink usa:

- uma rota só: `Host(\`<app>.${DOMAIN}\`)`, entrypoint `websecure`, `tls=true` e middleware `crowdsec-bouncer@file`;
- o próprio app autentica pelo Authentik (OIDC) e valida o token;
- painéis administrativos sem login próprio recebem `internal-only@file`.

App sem OIDC, mas com suporte a LDAP (como o Jellyfin): login pelo outpost LDAP do Authentik. Ver [guias/autenticacao-ldap.md](guias/autenticacao-ldap.md).

## Checklist de stack nova

1. Pasta em `<camada>/<stack>/`, partindo dos [templates](templates/).
2. `.env.example` com o bloco base e todas as variáveis, sem valores reais.
3. Cada volume na raiz certa ([como decidir](02-armazenamento.md#como-decidir-onde-um-volume-vai)), com `:?`.
4. Imagens com versão fixa; banco com healthcheck e rede interna.
5. Validar: `docker compose --env-file .env.example config --quiet`.
6. Criar as pastas no servidor com o dono certo antes do primeiro `up`.
7. Atualizar o [mapa por stack](02-armazenamento.md#mapa-atual-por-stack) e a tabela de stacks em [01-infraestrutura.md](01-infraestrutura.md).

## Dívidas conhecidas

Stacks existentes que ainda não seguem o padrão. Nenhuma delas impede a migração.

| Stack | Fora do padrão |
|---|---|
| várias | Imagens sem versão fixa: Jellyfin, *arr, SABnzbd, Deemix, Lidarr, Vaultwarden, CrowdSec, CloudBeaver, Ollama, Open WebUI, n8n, LiteLLM, Homepage, FlareSolverr |
| várias | `container_name` antigos (`bitwarden`, `ollama`, `sonarr`…). Mantidos porque outras stacks os usam como endereço; mudam junto com a revisão de acesso. |
| várias | IPs de confiança escritos nas labels e no `dynamic.yml`. Saem com a migração para OIDC. |
| jellyfin | Legendarr (web, worker, optimizer) roda como root. O optimizer guarda `requires_redownload.txt` fora de volume. |
| jellyfin | Sem rede interna: tudo, inclusive o que não tem rota, fica na `bergatrix-proxy`. |
| openuiweb | O nome da pasta tem um erro de digitação (o app é Open WebUI). Renomear muda `${APPDATA_PATH}/openuiweb`. |
| bitwarden | O nome da pasta é `bitwarden`, mas o app é o Vaultwarden. |
| cloudbeaver | Ficou sem banco para acessar desde que o Postgres global saiu: cada stack tem o seu, em rede interna. |
| quase todas | Sem `README.md` próprio (só bergastream, bergalink e wazuh têm). |
