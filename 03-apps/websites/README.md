# 🌐 websites — Silex (editor visual) + sites estáticos

Stack que sobe um **construtor de sites visual** ([Silex](https://www.silex.me/)) e
**três servidores estáticos** (nginx), um por domínio. O editor é protegido (acesso
interno); os três sites são públicos.

## Arquitetura

```
                            ┌───────────────────────────────────────────┐
                            │                Traefik                    │
                            │  (wildcard *.daberga.com, entrypoint 443)  │
                            └───────────────────────────────────────────┘
        studio.daberga.com │            daberga.com │ lucas. │ marina.
        (internal-only)    ▼            (público)    ▼        ▼        ▼
              ┌───────────────────┐   ┌──────────┐ ┌─────────┐ ┌──────────┐
              │    silex-editor   │   │web-daberga│ │web-lucas│ │web-marina│
              │  (Node, :6805)    │   │nginx :80  │ │nginx :80│ │nginx :80 │
              └─────────┬─────────┘   └────┬──────┘ └───┬─────┘ └────┬─────┘
        escreve build   │            :ro   │            │ :ro        │ :ro
                        ▼                  ▼            ▼            ▼
   ${VOLUMES_BASE}/websites/published/{<projetos>, daberga, lucas, marina}
                        ▲
        projetos/rascunhos: ${VOLUMES_BASE}/websites/storage
```

- **silex-editor** — o painel onde os sites são criados/editados. Publica o HTML
  estático no conector `fs` (filesystem), dentro de `/silex/hosting` (= o volume
  `published`). Exposto em `studio.${DOMAIN}` **apenas para a rede interna/LAN/VPN**
  via middleware `internal-only@docker`.
- **web-daberga / web-lucas / web-marina** — três `nginx:alpine`, cada um servindo
  **read-only** a pasta publicada do respectivo domínio. São **públicos** (só TLS,
  sem middleware).

### Hosts e exposição

| Serviço      | Host                  | Porta | Exposição                         |
|--------------|-----------------------|-------|-----------------------------------|
| silex-editor | `studio.${DOMAIN}`    | 6805  | 🔒 interno (`internal-only@docker`) |
| web-daberga  | `${DOMAIN}` (apex)    | 80    | 🌐 público                         |
| web-lucas    | `lucas.${DOMAIN}`     | 80    | 🌐 público                         |
| web-marina   | `marina.${DOMAIN}`    | 80    | 🌐 público                         |

> **TLS:** todos os routers usam `tls=true` **sem `certresolver`** — herdam o
> wildcard `*.daberga.com` emitido uma única vez pelo Traefik (convenção da casa;
> declarar `certresolver` por-router dispararia emissão individual e risco de
> rate-limit no Let's Encrypt). Ver [02-convencoes-e-padroes.md](../../docs/bergatrix/02-convencoes-e-padroes.md).

## Estrutura de arquivos

```
03-apps/websites/
├── docker-compose.yml      # 4 serviços (silex + 3 nginx) na rede bergatrix-proxy
├── .env.example            # DOMAIN, VOLUMES_BASE (placeholders)
├── .gitignore              # ignora .env e dados persistentes
├── nginx/
│   └── default.conf        # try_files (URLs limpas) + 404 amigável (montado :ro)
├── seed/                   # placeholders "em construção" (VERSIONADOS)
│   ├── daberga/{index,404}.html
│   ├── lucas/{index,404}.html
│   └── marina/{index,404}.html
└── README.md
```

> ⚠️ O conteúdo servido fica em **`${VOLUMES_BASE}/websites/published/`** (fora do
> repo, no host). A pasta `seed/` contém apenas os placeholders iniciais, que são
> **copiados** para o volume no primeiro deploy (ver abaixo).

## Como subir

> Execute no **servidor** (Linux), dentro de `03-apps/websites/`.

```bash
# 1. Configurar variáveis
cp .env.example .env
nano .env                      # ajustar DOMAIN e VOLUMES_BASE

# 2. Garantir a rede externa do Traefik (idempotente)
docker network inspect bergatrix-proxy >/dev/null 2>&1 || docker network create bergatrix-proxy

# 3. Criar os diretórios de volume e semear os placeholders
#    (lê VOLUMES_BASE do .env para esta sessão de shell)
export $(grep -E '^(VOLUMES_BASE|DOMAIN)=' .env | xargs)
mkdir -p "$VOLUMES_BASE/websites/storage"
mkdir -p "$VOLUMES_BASE/websites/published/daberga" \
         "$VOLUMES_BASE/websites/published/lucas" \
         "$VOLUMES_BASE/websites/published/marina"
cp -r seed/daberga/. "$VOLUMES_BASE/websites/published/daberga/"
cp -r seed/lucas/.   "$VOLUMES_BASE/websites/published/lucas/"
cp -r seed/marina/.  "$VOLUMES_BASE/websites/published/marina/"

# 4. Validar o compose (não sobe nada)
docker compose config

# 5. Subir
docker compose up -d
```

Depois disso:
- `https://${DOMAIN}`, `https://lucas.${DOMAIN}`, `https://marina.${DOMAIN}` já
  mostram a página "em construção".
- `https://studio.${DOMAIN}` abre o editor Silex (somente da rede interna/VPN).

## Pós-deploy

### 1. DNS (deSEC)
Criar os registros apontando para o ingress (mesmo IP/host dos demais serviços):

| Nome      | Tipo | Conteúdo               |
|-----------|------|------------------------|
| `daberga.com` (apex) | A/AAAA ou ALIAS | IP/host do ingress |
| `studio`  | A/AAAA/CNAME | ingress             |
| `lucas`   | A/AAAA/CNAME | ingress             |
| `marina`  | A/AAAA/CNAME | ingress             |

> O wildcard `*.daberga.com` cobre `studio/lucas/marina`, mas **não cobre o apex**
> `daberga.com` — por isso o apex precisa do seu próprio registro **e** do SAN no
> certificado (ver item 2).

### 2. Certificado (wildcard + apex)
Confirmar em [`01-network/traefik/config/traefik.yml`](../../01-network/traefik/config/traefik.yml)
que o entrypoint `websecure` lista o apex **e** o wildcard:

```yaml
domains:
  - main: "daberga.com"
    sans:
      - "*.daberga.com"
```

(Já está assim hoje — o `main: daberga.com` cobre o apex; o `*.daberga.com` cobre os
subdomínios. O wildcard sozinho **não** cobre o apex.)

### 3. Mapeamento publish → pasta (passo manual após o 1º publish)
O conector **FsHosting** do Silex publica cada site numa pasta **por ID de projeto**
dentro de `published/`, algo como `published/<projectId>/`. Como cada nginx serve uma
pasta fixa (`published/daberga`, `published/lucas`, `published/marina`), é preciso
**apontar** cada pasta fixa para o build do projeto correspondente.

Fluxo recomendado:

1. No editor (`https://studio.${DOMAIN}`), crie e **publique** cada site (conector
   *fs*). Descubra o ID do projeto listando o volume:
   ```bash
   ls -la "$VOLUMES_BASE/websites/published/"
   ```
2. Substitua a pasta-placeholder por um **symlink** para o build do projeto e
   reinicie o nginx daquele domínio:
   ```bash
   cd "$VOLUMES_BASE/websites/published"
   rm -rf daberga && ln -s <projectId-do-daberga> daberga
   rm -rf lucas   && ln -s <projectId-do-lucas>   lucas
   rm -rf marina  && ln -s <projectId-do-marina>  marina
   cd -
   docker compose restart web-daberga web-lucas web-marina
   ```
   > Alternativa sem symlink: `rsync -a --delete <projectId>/ daberga/` a cada publish
   > (duplica os arquivos, mas dispensa restart e symlinks).

A partir daí, cada `re-publish` no Silex atualiza `published/<projectId>/`, que o
symlink já reflete (não precisa mexer no nginx de novo).

### 4. Ativar o Authentik (SSO) no editor — opcional
O editor já está restrito à rede interna. Para **exigir login SSO** por cima disso,
edite o `docker-compose.yml`: comente a linha atual de middleware do `silex-router`
e descomente a que inclui `authentik@docker`:

```yaml
- "traefik.http.routers.silex-router.middlewares=authentik@docker,internal-only@docker"
# - "traefik.http.routers.silex-router.middlewares=internal-only@docker"
```

Depois: `docker compose up -d` (recria só o que mudou). Ambos os middlewares precisam
passar (rede interna **E** login Authentik) — mesmo padrão de cloudbeaver/wazuh.

## Notas de rede e segurança

- **Sem `ports:`** publicadas no host — só o Traefik expõe 80/443. Os containers ficam
  alcançáveis apenas pela rede `bergatrix-proxy`.
- **Editor isolado dos sites:** o `silex-editor` escreve em `published/` (RW); os três
  nginx montam suas subpastas **read-only** (`:ro`) — um site comprometido não
  consegue alterar o conteúdo de outro nem os projetos do editor.
- **Superfície pública:** apenas conteúdo estático nos 3 nginx. O painel de
  administração (Silex) **não** fica exposto à internet (`internal-only@docker` =
  ipallowlist `127.0.0.1/32` + `192.168.10.0/24`).
- **Sem segredos** no compose nem no código — só `DOMAIN` e `VOLUMES_BASE` via `.env`.
