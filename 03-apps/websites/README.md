# 🌐 websites — sites estáticos (nginx)

Stack que sobe **três servidores estáticos** (`nginx:alpine`), um por domínio. O
conteúdo de cada site fica no **volume do host** (`${VOLUMES_BASE}/websites/published/<dominio>`,
definido no `.env`) e é servido em **read-only**. Sem banco, sem build, sem editor.

## Arquitetura

```
                    ┌───────────────────────────────────────────┐
                    │                Traefik                    │
                    │  (wildcard *.daberga.com, entrypoint 443)  │
                    └───────────────────────────────────────────┘
        daberga.com │            lucas.daberga.com │   marina.daberga.com │
        (apex)      ▼            (público)          ▼   (público)          ▼
              ┌───────────┐          ┌──────────┐          ┌───────────┐
              │web-daberga│          │ web-lucas│          │web-marina │
              │nginx :80  │          │nginx :80 │          │nginx :80  │
              └─────┬─────┘          └────┬─────┘          └─────┬─────┘
              :ro   │                :ro  │                :ro   │
                    ▼                     ▼                      ▼
        ${VOLUMES_BASE}/websites/published/{daberga, lucas, marina}
```

Cada nginx monta a pasta do seu site no volume (`:ro`) e a config
`./nginx/default.conf` (também `:ro`). Todos são **públicos** (só TLS, sem middleware).

> O `:ro` restringe apenas o **container** (nginx nunca escreve) — você continua
> editando os arquivos normalmente no host.

### Hosts e exposição

| Serviço     | Host                | Porta | Exposição  |
|-------------|---------------------|-------|------------|
| web-daberga | `${DOMAIN}` (apex)  | 80    | 🌐 público |
| web-lucas   | `lucas.${DOMAIN}`   | 80    | 🌐 público |
| web-marina  | `marina.${DOMAIN}`  | 80    | 🌐 público |

> **TLS:** todos os routers usam `tls=true` **sem `certresolver`** — herdam o
> wildcard `*.daberga.com` emitido uma única vez pelo Traefik (convenção da casa;
> evita emissão individual / rate-limit). Ver
> [02-convencoes-e-padroes.md](../../docs/bergatrix/02-convencoes-e-padroes.md).

## Estrutura de arquivos

```
03-apps/websites/
├── docker-compose.yml      # 3 nginx na rede bergatrix-proxy
├── .env.example            # DOMAIN, VOLUMES_BASE
├── .gitignore              # ignora .env e dados persistentes
├── nginx/
│   └── default.conf        # try_files (URLs limpas) + 404 amigável (montado :ro)
├── seed/                   # placeholders "em construção" (VERSIONADOS)
│   ├── daberga/{index,404}.html
│   ├── lucas/{index,404}.html
│   └── marina/{index,404}.html
└── README.md
```

> O conteúdo servido fica em **`${VOLUMES_BASE}/websites/published/`** (no host, fora
> do repo). A pasta `seed/` guarda só os placeholders iniciais.

## Como subir

> Execute no **servidor** (Linux), dentro de `03-apps/websites/`.

```bash
# 1. Configurar variáveis
cp .env.example .env
nano .env                      # ajustar DOMAIN e VOLUMES_BASE

# 2. Garantir a rede externa do Traefik (idempotente)
docker network inspect bergatrix-proxy >/dev/null 2>&1 || docker network create bergatrix-proxy

# 3. Criar as pastas dos sites no volume
export $(grep -E '^(VOLUMES_BASE|DOMAIN)=' .env | xargs)
mkdir -p "$VOLUMES_BASE/websites/published/"{daberga,lucas,marina}

# 4. (Opcional, só no 1º deploy) semear os placeholders "em construção"
#    Pula este passo se você já tem o conteúdo dos sites na pasta.
cp -rn seed/daberga/. "$VOLUMES_BASE/websites/published/daberga/"
cp -rn seed/lucas/.   "$VOLUMES_BASE/websites/published/lucas/"
cp -rn seed/marina/.  "$VOLUMES_BASE/websites/published/marina/"

# 5. Validar e subir
docker compose config
docker compose up -d
```

> `cp -rn` é "no-clobber": **não sobrescreve** arquivos já existentes na pasta.

## Editar conteúdo

Edite os arquivos diretamente em `${VOLUMES_BASE}/websites/published/<dominio>/` no
host. Como o mount é `:ro` direto dessa pasta, **as alterações aparecem na hora** —
não precisa reiniciar o container. Só rode `docker compose up -d` de novo se mudar o
`docker-compose.yml` ou o `nginx/default.conf`.

> **URLs limpas:** o `nginx/default.conf` usa `try_files $uri $uri/ $uri.html =404`,
> então `/sobre` serve `sobre.html` automaticamente; rotas inexistentes caem na
> `404.html` (com status HTTP 404 correto).

## Pós-deploy (DNS + certificado)

### DNS (deSEC)
Apontar para o ingress (mesmo IP/host dos demais serviços):

| Nome                 | Tipo            | Conteúdo           |
|----------------------|-----------------|--------------------|
| `daberga.com` (apex) | A/AAAA ou ALIAS | IP/host do ingress |
| `lucas`              | A/AAAA/CNAME    | ingress            |
| `marina`             | A/AAAA/CNAME    | ingress            |

> O wildcard `*.daberga.com` cobre `lucas`/`marina`, mas **não cobre o apex**
> `daberga.com` — por isso o apex precisa do próprio registro **e** do SAN no
> certificado (abaixo).

### Certificado (wildcard + apex)
Confirmar em [`01-network/traefik/config/traefik.yml`](../../01-network/traefik/config/traefik.yml)
que o entrypoint `websecure` lista o apex **e** o wildcard:

```yaml
domains:
  - main: "daberga.com"
    sans:
      - "*.daberga.com"
```

## Notas de rede e segurança

- **Sem `ports:`** publicadas no host — só o Traefik expõe 80/443; os containers só
  se alcançam pela rede `bergatrix-proxy`.
- **Conteúdo read-only no container:** cada nginx monta o site com `:ro` — o processo
  não consegue alterar os arquivos servidos.
- **Superfície mínima:** apenas conteúdo estático. Sem editor/admin, sem banco, sem
  segredos no compose — só `DOMAIN` e `VOLUMES_BASE` via `.env`.
