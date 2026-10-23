# Transcriptor

Transcrição de áudio e vídeo com Whisper (faster-whisper) na GPU do servidor. Funciona com arquivo ou link (YouTube e outros sites do yt-dlp).

- **Por pessoa:** cada um vê só as próprias transcrições, com busca, histórico, o áudio para ouvir junto com o texto e correção dos trechos.
- **Exportação:** TXT, SRT, VTT e JSON.
- **Login:** pelo Authentik (OIDC). Scripts usam tokens pessoais.

Endereço: `transcriptor.${DOMAIN}`, modelo A de [05-acesso.md](../../docs/05-acesso.md): uma rota só, com CrowdSec e sem forward-auth.

## Serviços

| Serviço | O que faz | Redes |
|---|---|---|
| `api` | Interface web e API, login OIDC, upload em pedaços, eventos ao vivo (SSE) | `transcriptor-internal`, `bergatrix-proxy` |
| `worker` | Pega jobs da fila no Postgres, baixa links, converte com ffmpeg e transcreve na GPU | só `transcriptor-internal` |
| `egress` | Proxy de saída do worker ([smokescreen](https://github.com/stripe/smokescreen)): resolve o DNS e recusa destinos em redes privadas | `transcriptor-internal`, `transcriptor-egress` |
| `db` + `migrate` | Postgres 16 e as migrações (dbmate) em [`db/migrations`](db/migrations) | `transcriptor-internal` |

A fila é a tabela `jobs`: o worker pega o próximo com `FOR UPDATE SKIP LOCKED` e manda sinal de vida a cada 20 s. Se o worker cair, o job volta para a fila; na segunda queda, falha. Um trigger avisa a API (`LISTEN`), que repassa para as abas abertas.

## Armazenamento

| Onde | O quê | Backup |
|---|---|---|
| `${APPDATA_PATH}/transcriptor/postgres` | Usuários, sessões, tokens, transcrições e trechos | Sim |
| `${CACHE_PATH}/transcriptor/models` | Modelos do Hugging Face, baixados e conferidos pelo worker | Não: se apagar, baixa de novo |
| `${CACHE_PATH}/transcriptor/work` | Uploads em andamento e o áudio para ouvir (AAC) | Não |

O que fica guardado e por quanto tempo:

- **O arquivo original** é apagado quando a transcrição termina. Se ela falhar, fica 3 dias para "Tentar de novo".
- **O áudio para ouvir** fica `TRANSCRIPTOR_AUDIO_DAYS` dias (padrão 7).
- **As transcrições** ficam `TRANSCRIPTOR_RETENTION_DAYS` dias (padrão 180; `0` guarda até a pessoa apagar).

Transcrições podem conter dados pessoais de quem fala. Ajuste a retenção ao uso.

## Modelos

O catálogo fica em [`app/catalog.py`](app/catalog.py). Cada modelo tem um repositório do Hugging Face, uma revisão fixa e o SHA-256 do `model.bin`.

Na subida, o worker:

1. baixa o que falta, pelo proxy de saída (são ~5 GB na primeira vez);
2. confere o hash de cada modelo e descarta o que não bate;
3. faz uma transcrição de teste na GPU.

Só depois disso ele começa a pegar jobs. Administradores veem o estado em **Conta → Servidor**: GPU, VRAM, modelos e modelo carregado.

| Na tela | Modelo | Para quê |
|---|---|---|
| Rápido | `Systran/faster-whisper-small` | Rascunho; erra mais nomes e termos |
| **Preciso** (padrão) | `dropbox-dash/faster-whisper-large-v3-turbo` | Quase a qualidade do Large v3, bem mais rápido |
| Máximo | `Systran/faster-whisper-large-v3` | Áudio difícil; o mais lento |

Saiu o `medium`: o turbo é mais preciso e, em geral, tão rápido quanto ele ou mais.

**Como roda:**

- **Corte do áudio:** a transcrição usa o pipeline em lotes do faster-whisper, que corta o áudio nos silêncios (VAD). Antes, o corte era a cada 10 minutos e partia palavras.
- **Idioma:** português por padrão, ou detecção automática, entre outros.
- **Vocabulário (opcional):** nomes e termos que ajudam o modelo a escrever certo.

**GPU (GTX 1060 6 GB, Pascal):**

- **Versões fixadas:** int8, CUDA 12 + cuDNN 8 e CTranslate2 4.4.0. Não suba para o CUDA 13 nem para o CTranslate2 4.5+ sem testar: o CUDA 13 não suporta Pascal, e o driver 580 é o último com suporte.
- **Memória:** o modelo sai da VRAM depois de `TRANSCRIPTOR_IDLE_UNLOAD_MINUTES` sem uso (padrão 5), para o Jellyfin e o Ollama. Se faltar VRAM, o worker tenta de novo com metade do lote.

Para trocar ou atualizar um modelo:

1. pegue a revisão com `curl -s https://huggingface.co/api/models/<repo>`;
2. pegue o SHA-256 em `.../tree/<revisão>`;
3. atualize o `catalog.py`.

O worker baixa a versão nova e apaga a antiga.

## Segurança

- **Login:** OIDC com cliente confidencial e PKCE, `id_token` conferido pelo JWKS, nonce de uso único e grupo obrigatório.
- **Sessão:** cookie `__Host-` aleatório; só o hash dele fica no banco.
- **CSRF:** pedidos com cookie que mudam algo exigem `X-Transcriptor: 1` e a mesma origem.
- **Tokens pessoais:** `trs_…`, guardados com hash e revogáveis.
- **Links (SSRF):**
  - a API recusa endereços internos;
  - o worker não tem internet e sai só pelo smokescreen, que recusa redes privadas mesmo depois de redirecionamentos;
  - o NAS, o roteador e os outros containers ficam fora de alcance.
- **Arquivos enviados:** o ffprobe e o ffmpeg rodam só com os demuxers de áudio e vídeo comuns (`-format_whitelist`) e só com o protocolo `file`. Uma "playlist" HLS disfarçada de `.mp3`, que faria o ffmpeg ler outros arquivos, é recusada antes de ser aberta.
- **Containers:** read-only, `cap_drop: ALL`, `no-new-privileges` e usuário 1000.
- **Página:** CSP sem nada de fora, com Trusted Types.
- **Dependências:** fixadas com hash (`api/requirements.txt`, `worker/requirements.txt`).

## Subir

### 1. No Authentik

Crie a aplicação (padrão de [05-acesso.md](../../docs/05-acesso.md#oidc-uma-aplicação-por-app)):

| Campo | Valor |
|---|---|
| Provider | OAuth2/OpenID, *Confidential* |
| Redirect URI | `https://transcriptor.<domínio>/auth/callback` (Strict) |
| Signing key | `authentik Self-signed Certificate` (RS256) |
| Escopos | `openid`, `profile`, `email` (o `profile` do Authentik já manda os grupos) |
| Acesso | Grupos `transcriptor_users` (quem usa) e `transcriptor_admins` (quem também vê o estado do servidor), com *binding* na aplicação |

O issuer é `https://authentik.<domínio>/application/o/<slug>/`.

### 2. No servidor

```bash
cd ~/bergatrix/03-apps/transcriptor
cp .env.example .env        # POSTGRES_PASSWORD, TRANSCRIPTOR_OIDC_ISSUER, *_SSO_CLIENT_ID e *_SSO_CLIENT_SECRET
sudo mkdir -p /srv/appdata/transcriptor/postgres /srv/cache/transcriptor/{models,work}
sudo chown -R 1000:1000 /srv/cache/transcriptor
docker compose config --quiet
docker compose up -d --build
docker compose logs -f worker   # baixando, conferindo, teste da GPU, "ready"
```

Conferir:

- `nvidia-smi` funciona no host;
- `docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi` mostra a GPU, ou seja, o nvidia-container-toolkit está instalado.

### Vindo da versão antiga

- **API v1:** a `X-API-Key` e o `/api/v1` saíram. Crie um token pessoal em **Conta → Tokens da API**.
- **Variáveis do `.env`:** `TRANSCRIPTOR_API_KEY`, `TRANSCRIPTOR_SECRET_KEY` e `HF_TOKEN` não são mais usadas e podem sair.
- **Histórico antigo:** ele era anônimo (cookie por navegador) e expirava em 30 dias, então não é migrado. Depois de conferir a versão nova:

  ```bash
  sudo rm -rf /srv/appdata/transcriptor/data            # JSON e .txt/.vtt antigos
  sudo rm -rf /srv/cache/transcriptor/models/whisper-*  # modelos antigos (sem procedência conferida)
  ```

## API

Autenticação por `Authorization: Bearer trs_…`. O esquema completo fica em `/api/openapi.json`.

| Pedido | Para quê |
|---|---|
| `POST /api/jobs` `{"url", "model", "language", "prompt"}` | Transcrever um link |
| `POST /api/uploads` `{"name", "size", "model", "language", "prompt"}` | Começar um upload (devolve o id e o tamanho do pedaço, 8 MB) |
| `PUT /api/uploads/<id>?offset=N` (corpo binário) | Mandar um pedaço. 409 devolve o `received` certo, para retomar |
| `POST /api/uploads/<id>/complete` | Fechar o upload e pôr na fila |
| `GET /api/jobs/<id>` | Estado, progresso e trechos |
| `GET /api/jobs/<id>/export/{txt,srt,vtt,json}` | Resultado |
| `POST /api/jobs/<id>/cancel`, `.../retry`, `DELETE /api/jobs/<id>` | Controle |

O upload é em pedaços para cada pedido caber no tempo limite do Traefik e para retomar se a conexão cair.

## Testes

```bash
# Unidade (sem banco): formatos, validação de links, ffprobe, id_token
pytest tests/test_units.py
# Integração: veja tests/conftest.py (Postgres de teste migrado pelo dbmate)
TRANSCRIPTOR_TEST_DATABASE_URL=postgresql://postgres:test@127.0.0.1:55432/postgres pytest tests
```
