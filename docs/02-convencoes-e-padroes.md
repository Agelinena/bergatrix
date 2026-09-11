# 📐 Bergatrix — Convenções & Padrões de Desenvolvimento

> Para que qualquer evolução futura siga os mesmos padrões. Inferido dos 17 composes e do código real das stacks.

## 1. Organização em camadas
- Pastas de camada com **prefixo numérico de 2 dígitos** refletindo **ordem de dependência**: `00-infrastructure`, `01-network`, `02-security`, `03-apps`, `04-monitoring`.
- **Quando criar uma nova camada:** só se introduzir um nível de dependência transversal novo (ex: um `05-backup`). Na dúvida, é uma app → vai em `03-apps`.
- **Regra de ouro:** *uma stack = uma pasta = um `docker-compose.yml` + `.env.example`*. Sem orquestrador central; deploy por `docker compose up -d` dentro da pasta.

## 2. Estrutura padrão de uma stack
```
03-apps/<nome>/
├── docker-compose.yml        # serviços, redes, volumes, labels Traefik
├── .env.example              # placeholders de TODAS as variáveis (versionado)
├── .env                      # valores reais (NUNCA versionado)
├── Dockerfile                # se houver build local
└── app/ (ou api/ + worker/)  # código-fonte
    ├── main.py
    ├── requirements.txt
    └── ...
```
Padrão **API + worker** (berga-news, rss-ig): duas imagens buildadas separadamente (`api/` e `worker/`), **mesmo volume/banco compartilhado**, worker como processo de scheduler (APScheduler) sem servidor HTTP. ⚠️ Hoje há **duplicação de `db.py`/`llm.py`** entre `api/` e `worker/` — ao criar uma nova app desse tipo, considere um pacote compartilhado.

## 3. Nomenclatura
| Item | Convenção | Exemplos |
|---|---|---|
| Pasta de camada | `NN-nome` | `01-network` |
| Rede compartilhada | prefixo `bergatrix-` | `bergatrix-proxy`, `bergatrix-db-internal` |
| Rede interna de stack | sufixo `-internal` (+ `internal: true`) | `litellm-internal`, `wazuh-internal` |
| Rede de saída de worker | sufixo `-egress` (bridge) | `litellm-egress`, `instaloader-egress` |
| `container_name` | kebab/lower explícito | `bergastream-api`, `legendarr-worker` |
| Router Traefik | sufixo `-router` | `jellyfin-router`, `drop-router` |
| Service Traefik | sufixo `-service` | `n8n-service` |
| Domínio | `Host(\`subdominio.${DOMAIN}\`)` | `news.`, `llm.`, `chat.`, `jellyflix.` |
| Volumes | ancorados em var base | `${VOLUMES_BASE}/<stack>` (maioria), `${STORAGE_PATH}` (cloudbeaver, jellyfin) |

> ⚠️ **Inconsistência atual:** a variável base de volume varia entre stacks (`VOLUMES_BASE`, `STORAGE_PATH`, `BERGANEWS_DATA_DIR`, `TRANSCRIPTOR_DATA_DIR`, `INSTALOADER_DATA_DIR`). Vale padronizar em `${VOLUMES_BASE}/<stack>` nas novas stacks.

## 4. Padrão de roteamento (labels Traefik)
Bloco repetido em ~15 composes — copie e ajuste:
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=bergatrix-proxy"
  - "traefik.http.routers.<nome>.rule=Host(`<sub>.${DOMAIN}`)"
  - "traefik.http.routers.<nome>.entrypoints=websecure"
  - "traefik.http.routers.<nome>.tls=true"   # herda o wildcard *.daberga.com do Traefik — NÃO declarar certresolver
  - "traefik.http.routers.<nome>.middlewares=internal-only@docker"   # se interno
  - "traefik.http.services.<nome>.loadbalancer.server.port=<porta>"
networks: [ <nome>-internal, bergatrix-proxy ]
```
- **Exposição:** público = só `websecure`+TLS; interno = `+ internal-only@docker`; sensível = `+ authentik@docker`.
- **Não publique portas no host** (`ports:`) para serviços roteados pelo Traefik — só o Traefik expõe 80/443.
- **Certificado = wildcard:** use **apenas `tls=true`** (sem `tls.certresolver`); todos os apps herdam o **wildcard `*.daberga.com`** emitido pelo Traefik. Declarar `certresolver` faria o Traefik emitir um certificado individual desnecessário (risco de rate limit do Let's Encrypt).

## 5. Padrão de SSO (Authentik)
- Para proteger uma UI com login SSO, basta adicionar o middleware `authentik@docker` (ForwardAuth) — não precisa codar login na app.
- Apps com auth própria (sessão/JWT) podem dispensar, mas devem ficar ao menos atrás de `internal-only`.

## 6. Gestão de segredos
> 📖 Guia prático completo (como montar, variáveis comuns, gerar segredos, manipular, template): **[06-guia-env.md](06-guia-env.md)**.

- **Sempre** `.env` (não versionado) + `.env.example` (placeholders, versionado).
- Nunca colocar valor real em `docker-compose.yml`, código ou doc.
- Hash de senha = **bcrypt**; cookies assinados = `itsdangerous`; nada de segredo em querystring/URL.
- Derive strings de conexão no compose interpolando o segredo (ex: `DATABASE_URL` a partir de `${POSTGRES_PASSWORD}`).

## 7. Versionamento (git)
- **`.gitignore`** por seções: segredos, certificados, dados persistentes (`**/data/`, `**/db_data/`, `**/volumes/`, `**/backups/`, `**/downloads/`, `**/storage/`), logs, OS/IDE, Python/Node, runtime do Legendarr.
- **`.gitattributes`** força **EOL = LF** em todo o repo (`* text=auto eol=lf`) — crítico porque o dev é em **Windows 11** e os containers rodam Linux. Binários (`*.png/jpg/gif/ico/woff2/ttf`) sem conversão.
- **`.claude/` é ignorado** — settings/hooks do Claude não são versionados.
- Commits recentes seguem prefixos tipo `nvenc:`, `logging:`, `chore:`, `optimizer:`.

## 8. Persistência
- Bancos relacionais: **PostgreSQL** por stack (ou Postgres global via `bergatrix-db-internal`). Vários apps **não usam Alembic** — schema por `create_all` + `CREATE INDEX IF NOT EXISTS` (mudanças de coluna seriam manuais). **Recomendação para novas apps: adotar migrations.**
- Casos mais simples usam **SQLite** (rss-ig) ou **arquivos JSON** (jellyfin/Legendarr, transcriptor) — aceitável para single-node, mas não escala.

## 9. GPU (NVIDIA GTX 1060, compartilhada)
- 1 chip NVENC dividido entre jellyfin (transcode), optimizer (encode), Ollama (LLM) e transcriptor (Whisper).
- Acesso via `deploy.resources.reservations.devices` (driver `nvidia`, `capabilities: [gpu]`) ou `runtime: nvidia` + `NVIDIA_VISIBLE_DEVICES`.
- **Serialize** o uso (lock/`MAX_WORKERS=1`) — não há agendador de GPU entre stacks.

## ✅ Checklist para adicionar uma nova app
1. [ ] Criar pasta `03-apps/<nome>/` com `docker-compose.yml` + `.env.example`.
2. [ ] Definir `container_name`, redes (`<nome>-internal` + `bergatrix-proxy`; `internal: true` no banco).
3. [ ] Adicionar labels Traefik (router/service/porta) e escolher exposição (público / `internal-only` / `+authentik`).
4. [ ] Escolher subdomínio `Host(\`<sub>.${DOMAIN}\`)` e usar **`tls=true` sem `certresolver`** (herda o wildcard `*.daberga.com`).
5. [ ] Ancorar volumes em `${VOLUMES_BASE}/<nome>`.
6. [ ] Segredos só via `.env`; preencher `.env.example` com **todos** os nomes de variáveis.
7. [ ] Adicionar `restart: unless-stopped` e **healthcheck** a cada serviço.
8. [ ] Se usar IA, preferir o gateway **LiteLLM** (`http://litellm:4000/v1`) ou **Ollama** local.
9. [ ] Adicionar a stack ao índice em [00-visao-geral.md](00-visao-geral.md) e criar `stacks/<nome>.md`.
10. [ ] Garantir EOL LF (o `.gitattributes` já cobre) e não commitar `.env`/dados.

---
_Documento gerado por análise automatizada da Bergatrix e revisado. Atualize conforme a estrutura evoluir._
