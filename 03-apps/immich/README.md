# Immich

Fotos e vídeos da família: backup automático do celular, álbuns, compartilhamento, busca por texto ("praia", "cachorro"), rostos e OCR. Versão: **v3.3.5**.

Endereço: `fotos.${DOMAIN}`, modelo A de [05-acesso.md](../../docs/05-acesso.md): uma rota só, com CrowdSec e sem forward-auth, porque o app do celular fala direto com a API. O login é pelo Authentik (OIDC), e o login por senha fica desligado.

> ⚠️ **Ainda não há backup automático** ([02-armazenamento.md](../../docs/02-armazenamento.md#backup)). Até existir, o `USERDATA_PATH` é uma cópia só, num disco só. Use o Immich para testar, mas **não apague fotos do celular** nem trate o Immich como a cópia principal.

## Serviços

| Serviço | Container | O que faz | Redes |
|---|---|---|---|
| `immich-server` | `immich-server` | Interface web, API dos apps e jobs (miniaturas, vídeos, metadados) | `immich-internal`, `bergatrix-proxy` |
| `immich-machine-learning` | `immich-ml` | Busca inteligente (CLIP), rostos e OCR na GPU (imagem `-cuda`) | `immich-internal`, `immich-egress` (só para baixar modelos) |
| `redis` | `immich-redis` | Fila de jobs (Valkey) | `immich-internal` |
| `database` | `immich-db` | Postgres 14 com VectorChord (imagem do próprio Immich) | `immich-internal` |

Os nomes dos serviços são os do compose oficial. O servidor acha os outros por eles, sem configuração. Todos rodam como `PUID:PGID` (1000), com `no-new-privileges` e sem `NET_RAW`. Nenhuma porta fica aberta no host.

### GPU

O machine learning usa a GTX 1060 por CUDA (o Immich exige compute capability 5.2 e driver 545 ou mais novos; a imagem usa CUDA 12).

**A GPU é dividida** com o Ollama, o Jellyfin (transcodificação), o Transcriptor e o Legendarr. Os modelos do Immich saem da VRAM depois de 5 min sem uso (`MACHINE_LEARNING_MODEL_TTL`, no padrão). Se faltar VRAM, um dos serviços falha ao carregar o modelo. Nesse caso, olhe o `nvidia-smi` e evite rodar a importação inicial do Immich junto com um modelo grande do Ollama.

A transcodificação de vídeo fica na CPU. O NVENC é possível (`hwaccel.transcoding.yml` da release), mas gera arquivos maiores e de qualidade pior, segundo a documentação.

## Armazenamento

| Onde | Montado em | O quê | Backup |
|---|---|---|---|
| `${USERDATA_PATH}/immich` (NAS) | `/data` | `library/` (originais, por ano e mês), `upload/` (chegando do celular), `profile/` (avatares), `backups/` (dumps diários do banco) | **Sim** |
| `${CACHE_PATH}/immich/thumbs` | `/data/thumbs` | Miniaturas, prévias e rostos | Não: os jobs refazem |
| `${CACHE_PATH}/immich/encoded-video` | `/data/encoded-video` | Vídeos convertidos | Não: os jobs refazem |
| `${CACHE_PATH}/immich/model-cache` | `/cache` (ML) | Modelos do Hugging Face | Não: baixa de novo |
| `${CACHE_PATH}/immich/redis` | `/data` (Valkey) | Fila de jobs | Não |
| `${APPDATA_PATH}/immich/postgres` | banco | Álbuns, pessoas, metadados, usuários, configuração (inclusive o OIDC) | **Sim**, por dump |

- **Nunca mexa nos arquivos do NAS** fora do Immich (apagar, renomear, editar). O Immich não percebe a mudança, e as fotos ficam quebradas. Ler e copiar pode.
- As pastas `thumbs/` e `encoded-video/` também aparecem no NAS, vazias: são só os pontos de montagem. Não apague.
- O Immich grava um arquivo `.immich` em cada pasta e **não sobe** se uma delas sumir (por exemplo, com o NFS desmontado). Não apague esses arquivos.
- O Immich grava um dump do banco em `backups/` todo dia às 02:00 e guarda os 14 últimos (*Administration → Settings → Backup*). Ele fica no NAS, num disco diferente do banco.

### Backup (quando o serviço de backup existir)

- **Copiar:** `${USERDATA_PATH}/immich` inteiro e um `pg_dump` do `immich-db` (ou os dumps de `backups/`).
- **Ordem:** o banco **antes** dos arquivos. Ao contrário, o banco restaurado pode apontar para fotos que não estão na cópia.
- **Não copiar:** `${CACHE_PATH}/immich`. Depois de uma restauração, rode os jobs de miniaturas e vídeos (*Administration → Jobs*, "Missing").

## Subir

Os passos com valores reais (domínio, contas) ficam no repositório privado. Aqui, `example.com` é o seu domínio.

### 1. Export `userdata` no OMV

O Immich grava como o usuário 1000, e o export precisa de `all_squash,anonuid=1000,anongid=1000` ([02-armazenamento.md](../../docs/02-armazenamento.md#permissões)). Confira no OMV:

```bash
sudo exportfs -v | grep -A1 userdata   # deve mostrar all_squash,anonuid=1000,anongid=1000
```

Se faltar, acrescente em *Serviços → NFS → Compartilhamentos → userdata → Opções extras* e aplique.

### 2. Pastas

Na VM Docker:

```bash
# Disco local: banco e cache
sudo mkdir -p /srv/appdata/immich/postgres \
  /srv/cache/immich/{thumbs,encoded-video,model-cache,redis}
sudo chown -R 1000:1000 /srv/appdata/immich /srv/cache/immich
sudo chmod 700 /srv/appdata/immich/postgres

# NAS: com all_squash, o dono vira 1000 sozinho
mkdir -p /mnt/nas/userdata/immich/{thumbs,encoded-video}
ls -ln /mnt/nas/userdata/immich    # dono e grupo: 1000 1000
```

Se o `ls -ln` mostrar outro dono, corrija **no OMV**, e não no Ubuntu (pelo NFS, o `chown` é ignorado):

```bash
# No OMV: a pasta userdata fica em /srv/dev-disk-by-uuid-<uuid>/userdata
sudo chown -R 1000:1000 /srv/dev-disk-by-uuid-<uuid>/userdata/immich
```

### 3. Traefik: timeout de upload

O Traefik corta requisições em 60 s por padrão, e o upload de um vídeo grande pelo celular falha (erro 499). O `traefik.yml` já sobe esse limite para 600 s. Depois do `git pull`, reinicie o Traefik para ler a configuração:

```bash
cd ~/bergatrix/01-network/traefik && docker compose restart traefik
```

### 4. Authentik

1. **Grupo:** *Directory → Groups → Create* `immich_users`. Ponha nele quem vai usar o Immich. Toda conta precisa ter **e-mail** preenchido: o Immich identifica as pessoas por ele.
2. **Aplicação:** *Applications → Applications → Create with provider*.
   - **Application:** nome `Immich`, slug `immich`, *Launch URL* `https://fotos.example.com/auth/login?autoLaunch=1`.
   - **Provider:** *OAuth2/OpenID Connect*.
     - *Authorization flow:* `default-provider-authorization-implicit-consent`.
     - *Client type:* **Confidential**.
     - *Redirect URIs*, as três com *matching* **Strict**:
       - `app.immich:///oauth-callback` (app do celular; três barras)
       - `https://fotos.example.com/auth/login`
       - `https://fotos.example.com/user-settings` (vincular uma conta que já existe)
     - *Signing key:* `authentik Self-signed Certificate` (RS256). Sem *encryption key*.
     - *Advanced protocol settings → Scopes:* `openid`, `email` e `profile` (os padrões).
   - **Bindings:** grupo `immich_users`, Order `0`. Sem binding, qualquer conta do Authentik entraria.
3. Copie o **Client ID** e o **Client Secret** para o Vaultwarden. O Immich guarda essa configuração no banco, e não no `.env`. Por isso, ela não segue o `<APP>_SSO_CLIENT_SECRET` de [05-acesso.md](../../docs/05-acesso.md).

O issuer fica `https://authentik.example.com/application/o/immich/`.

### 5. Subir a stack

```bash
cd ~/bergatrix/03-apps/immich
cp .env.example .env && chmod 600 .env
# Preencha DOMAIN e POSTGRES_PASSWORD (openssl rand -hex 32)
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps        # os quatro "healthy" em ~1 min
```

A stack já está no [`stacks.txt`](../../00-infrastructure/stacks.txt). Daqui em diante, o `subir-tudo.sh` cuida dela.

### 6. Primeiro acesso: crie o admin na hora

Até alguém criar a conta de administrador, **a tela de cadastro do admin fica aberta para quem chegar primeiro**. Abra `https://fotos.example.com` logo depois do `up` e crie o admin com o **mesmo e-mail** da sua conta no Authentik.

### 7. Configurar o Immich

Em *Administration → Settings*:

- **Authentication Settings → OAuth:** ligue e preencha.

  | Campo | Valor |
  |---|---|
  | Issuer URL | `https://authentik.example.com/application/o/immich/` |
  | Client ID / Client Secret | os do passo 4 |
  | Scope | `openid email profile` |
  | Signing algorithm | `RS256` |
  | Storage label claim | `preferred_username` (o nome de usuário no Authentik vira a pasta da pessoa em `library/`) |
  | Role claim / Storage quota claim | deixe o padrão (o Authentik não manda essas claims; papéis e cotas ficam no Immich) |
  | Button text | `Entrar com o Authentik` |
  | Auto register | ligado (o binding do grupo já filtra quem entra) |
  | Auto launch | ligado |
  | Mobile redirect URI override | **desligado** |

  Se o app do celular não voltar do Authentik depois do login, ligue o *override* com `https://fotos.example.com/api/oauth/mobile-redirect` e acrescente essa URI ao provider no Authentik.

- **Server Settings → External domain:** `https://fotos.example.com` (usado nos links de compartilhamento).
- **Storage Template:** ligue **antes de subir fotos**, com o modelo `{{y}}/{{MM}}/{{filename}}`. Os originais ficam em `library/<pessoa>/<ano>/<mês>/`, uma pasta legível sem o Immich. Se ligar depois, rode o job *Storage Template Migration*.
  - O admin criado no passo 6 tem a pasta `admin`. Para usar o seu nome de usuário, troque o *Storage label* em *Administration → Users*.
  - Fotos que ainda estão chegando do celular passam por `upload/` e vão para `library/` quando o upload termina.

### 8. Vincular, testar e desligar a senha

1. Logado como admin (com senha): *Account Settings → OAuth → Link to OAuth*. Ao voltar do Authentik, a sua conta fica ligada a ele.
2. Numa janela anônima, entre com uma conta de `immich_users`: o Immich abre o Authentik direto (auto launch), pede o 2FA e cria o usuário.
3. Tente com uma conta **fora** do grupo: o Authentik deve negar.
4. No celular, no app oficial: servidor `https://fotos.example.com` e **Login with OAuth**.
5. Funcionou tudo? Desligue a senha em *Authentication Settings → Password login*.

Se o Authentik cair e ninguém conseguir entrar, religue a senha pelo servidor:

```bash
docker exec -it immich-server immich-admin enable-password-login
```

### 9. Conferir a GPU

Faça uma busca por texto na interface (isso carrega o modelo CLIP) e veja:

```bash
docker logs immich-ml 2>&1 | grep -i provider    # deve citar CUDAExecutionProvider
nvidia-smi                                       # um processo python do immich-ml
```

## Atualizar

1. Leia as notas da release (<https://github.com/immich-app/immich/releases>). O Immich avisa quando uma versão exige um passo manual.
2. Troque a versão do `immich-server` **e** do `immich-machine-learning` (as duas iguais; o ML mantém o `-cuda`).
3. Se o `docker-compose.yml` da release trouxer outra imagem do `database` ou do `redis`, copie a linha inteira, com o digest.
4. `docker compose pull && docker compose up -d`.

Antes de uma atualização com mudança no banco, confira se o dump mais recente em `backups/` é de hoje.

## Particularidades

- **CrowdSec:** o app do celular pede muitas miniaturas de uma vez. Nos primeiros dias, veja se aparecem bans de IPs da casa (`docker exec crowdsec cscli decisions list`). Se aparecerem, crie uma exceção como a do Jellyfin em `02-security/crowdsec/whitelists/bergatrix.yaml`.
- **OIDC sem `.env`:** o issuer, o client ID e o secret ficam no banco do Immich (*Administration → Settings*). Eles entram no backup do banco, e a cópia de referência fica no Vaultwarden.
- **Saída para a internet:** o servidor sai pela `bergatrix-proxy`, para buscar o issuer do Authentik pela URL pública e para conferir se há versão nova. O machine learning sai pela `immich-egress`, só para baixar modelos. O banco e a fila ficam sem internet.
