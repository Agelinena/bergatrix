# 🌐 websites — sites estáticos (nginx)

Stack que sobe **três servidores estáticos** (`nginx:alpine`), um por domínio. O
conteúdo de cada site vive **versionado no repo** em `sites/<dominio>/` e é servido
em **read-only**. Sem banco, sem build, sem volumes externos — `git pull` + `up`.

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
              ./sites/daberga       ./sites/lucas         ./sites/marina
```

Cada nginx monta a pasta do seu site (`./sites/<dominio>`) como **read-only** e a
config `./nginx/default.conf` (também `:ro`). Todos são **públicos** (só TLS, sem
middleware).

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
├── .env.example            # apenas DOMAIN
├── .gitignore              # ignora .env (o conteúdo de sites/ é versionado)
├── nginx/
│   └── default.conf        # try_files (URLs limpas) + 404 amigável (montado :ro)
├── sites/                  # conteúdo de cada site (VERSIONADO)
│   ├── daberga/{index,404}.html
│   ├── lucas/{index,404}.html
│   └── marina/{index,404}.html
└── README.md
```

## Como subir

> Execute no **servidor** (Linux), dentro de `03-apps/websites/`.

```bash
cp .env.example .env          # ajustar DOMAIN se necessário
# Garantir a rede externa do Traefik (idempotente)
docker network inspect bergatrix-proxy >/dev/null 2>&1 || docker network create bergatrix-proxy
docker compose config         # validar (não sobe nada)
docker compose up -d
```

Pronto: `https://${DOMAIN}`, `https://lucas.${DOMAIN}` e `https://marina.${DOMAIN}`
mostram a página "em construção".

## Editar / publicar conteúdo

1. Edite os arquivos em `sites/<dominio>/` (HTML/CSS/JS estáticos).
2. `git commit` + `git push`.
3. No servidor: `git pull`.

O mount é `:ro` direto da pasta do host, então **alterações de conteúdo aparecem na
hora** — não precisa reiniciar o container. Só rode `docker compose up -d` de novo se
mudar o `docker-compose.yml` ou o `nginx/default.conf`.

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
- **Conteúdo read-only:** cada nginx monta o site com `:ro` — o processo não consegue
  alterar os arquivos servidos.
- **Superfície mínima:** apenas conteúdo estático. Sem editor/admin, sem banco, sem
  segredos no compose — só `DOMAIN` via `.env`.
