# Nextcloud

Arquivos, agenda (CalDAV) e contatos (CardDAV) da Bergatrix, em `storange.${DOMAIN}`.

> **Antes de colocar arquivos de verdade:** ainda não há backup automático. A pasta de dados no NAS seria a **única cópia** dos seus arquivos. Use só arquivos de teste até o serviço de backup cobrir o que está em [Backup](#backup).

| Container | Imagem | Para quê | Redes |
|---|---|---|---|
| `nextcloud-app` | `nextcloud:34.0.5-apache` | Web, WebDAV, CalDAV e CardDAV (Apache + PHP) | `nextcloud-internal`, `bergatrix-proxy` |
| `nextcloud-cron` | a mesma | Tarefas em segundo plano a cada 5 min (`/cron.sh`) | `nextcloud-internal`, `nextcloud-egress` |
| `nextcloud-db` | `postgres:16-alpine` | Banco | `nextcloud-internal` |
| `nextcloud-redis` | `redis:7-alpine` | Cache e locks de arquivo, sem persistência | `nextcloud-internal` |

**Por que a imagem oficial e não o AIO:** o AIO usa um container mestre com acesso ao socket do Docker, que cria os próprios containers, redes e volumes com nomes fixos. Isso sai do padrão das stacks (versão fixa, raízes, redes, labels do Traefik). A imagem oficial é configurada por variáveis e se atualiza sozinha ao trocar a tag.

## Como funciona

- **Acesso** ([05-acesso.md](../../docs/05-acesso.md)): uma rota só, com `crowdsec-bouncer@file` e sem forward-auth. O login é pelo Authentik, por OIDC (app `user_oidc`).
  - Os clientes de desktop e de celular abrem o navegador (Login Flow v2), passam pelo Authentik e recebem uma senha de app.
  - O WebDAV, o CalDAV e o CardDAV usam senha de app.
- **Pastas:**
  - `${APPDATA_PATH}/nextcloud/html`: código, `config/`, `custom_apps/` e temas. Fica no disco local e o dono é `33:33` (`www-data`).
  - `${APPDATA_PATH}/nextcloud/postgres`: o banco.
  - `${USERDATA_PATH}/nextcloud/data`: arquivos, versões, lixeira, miniaturas e o `nextcloud.log`. Fica no NAS, por NFS.
- **NFS:** o Nextcloud trava os arquivos pelo Redis (`memcache.locking`), e não pelo lock do NFS. O banco nunca fica no NFS.
  - Com o export `userdata` em `all_squash,anonuid=1000,anongid=1000`, tudo que o `www-data` (UID 33) grava fica com o dono 1000 no NAS, e o servidor NFS confere as permissões como 1000.
  - Se o NAS não estiver montado, o Nextcloud se recusa a rodar, porque falta o arquivo `.ncdata`. Ele não grava na pasta de montagem vazia.
- **Atrás do Traefik:** `TRUSTED_PROXIES=172.16.0.0/12`, a faixa das redes do Docker, a mesma do Authentik. Também `APACHE_DISABLE_REWRITE_IP=1`, `OVERWRITEPROTOCOL=https`, `OVERWRITEHOST` e `OVERWRITECLIURL`.
  - Testado: o Nextcloud vê o IP real do cliente, o que importa para a proteção contra força bruta e para os logs.
  - O redirect de `/.well-known/caldav` e `carddav` é feito por um middleware do Traefik (`nextcloud-dav`), porque o Apache do container redirecionaria para `http://`.
- **Instalação que falha:** o hook [`hooks/before-starting/10-exige-instalacao.sh`](hooks/before-starting/10-exige-instalacao.sh) impede o Apache de subir com o Nextcloud sem instalar.
  - Sem ele, um erro na primeira subida (senha vazia, pasta sem permissão) deixaria o instalador web aberto na internet.
  - Para refazer a instalação, veja [Problemas comuns](#problemas-comuns).
- **CrowdSec:** o parser `crowdsecurity/nextcloud-whitelist` (em [`02-security/crowdsec`](../../02-security/crowdsec/docker-compose.yml)) ignora os 404 normais do WebDAV e das miniaturas.
  - Ele foi validado com `cscli explain` em linhas do `access.log` do Traefik.
  - As regras dele valem para qualquer host, não só para o `storange`. Os outros 404 (`/wp-login.php`, `/.env`…) continuam contando.

## 1. Authentik

Use o padrão OIDC de [05-acesso.md](../../docs/05-acesso.md#oidc-uma-aplicação-por-app). Os nomes abaixo são os usados no resto deste guia.

1. **Grupo** `nextcloud_users`, com quem pode usar o Nextcloud.
2. **Scope mapping** (*Customization → Property Mappings → Create → Scope Mapping*):
   - Nome: `Nextcloud Profile`.
   - Scope name: `nextcloud`.
   - Expressão:

     ```python
     groups = [
         entitlement.name
         for entitlement in request.user.app_entitlements(provider.application)
     ]
     quota = (
         request.user.app_entitlements_attributes(provider.application).get("nextcloud_quota")
         or request.user.group_attributes().get("nextcloud_quota")
     )

     return {
         "name": request.user.name,
         "groups": groups,
         "quota": quota,
         "user_id": request.user.attributes.get("nextcloud_user_id", str(request.user.uuid)),
     }
     ```

3. **Provider** OAuth2/OpenID `nextcloud`:

   | Campo | Valor |
   |---|---|
   | Client type | *Confidential* |
   | Redirect URI | `https://storange.example.com/apps/user_oidc/code`, *Strict* (só esta: até a versão 2026.5, toda URI conta como de autorização) |
   | Authorization flow | `default-provider-authorization-implicit-consent` |
   | Signing key | `authentik Self-signed Certificate` (RS256), sem *encryption key* |
   | Subject mode | *Based on the User's UUID* |
   | Scopes | os padrões (`openid`, `email`, `profile`) mais `Nextcloud Profile` |

4. **Application** `nextcloud` (slug `nextcloud`), ligada ao provider, com *binding* ao grupo `nextcloud_users` (Order `0`).
5. **Entitlements** da aplicação (aba *Application entitlements*): viram os grupos do Nextcloud.
   - `admin`: obrigatório, e o nome é fixo. É o grupo de administradores do Nextcloud. Faça o *binding* só da sua conta.
   - Outros grupos, se quiser compartilhar pastas por grupo (ex.: `familia`).
   - Com o provisionamento de grupos ligado, a cada login o Nextcloud deixa a pessoa **só** nos grupos que vieram do Authentik. Crie e mude os grupos sempre por aqui.
6. **Nome da conta** (antes do primeiro login de cada pessoa): nos atributos do usuário, coloque `nextcloud_user_id: lucas`.
   - Sem isso, o ID no Nextcloud e o nome da pasta no NAS ficam sendo o UUID do Authentik.
   - **Não mude depois:** um ID novo cria uma conta nova e vazia.
7. **Cota** (opcional): o atributo `nextcloud_quota: 100 GB` num entitlement ou num grupo. Sem ele, vale a cota padrão do Nextcloud.
8. Copie o client ID e o client secret para `NEXTCLOUD_SSO_CLIENT_ID` e `NEXTCLOUD_SSO_CLIENT_SECRET` no `.env`.

## 2. Pastas no servidor

**Disco local (Ubuntu):**

```bash
sudo mkdir -p /srv/appdata/nextcloud/html
sudo chown 33:33 /srv/appdata/nextcloud/html
```

A pasta `postgres` é criada pelo próprio container.

**NAS:**

1. O export `userdata` precisa de `all_squash,anonuid=1000,anongid=1000` ([02-armazenamento.md](../../docs/02-armazenamento.md#permissões)). Confira em *Serviços → NFS → Compartilhamentos* no OMV.
2. O Docker precisa esperar pela montagem do `userdata`. Se `/mnt/nas/userdata` não aparecer na saída do comando abaixo, acrescente-o em `sudo systemctl edit docker.service`:

   ```bash
   systemctl cat docker.service | grep RequiresMountsFor
   ```

3. Crie a pasta de dados pelo Ubuntu. Com o `all_squash`, o dono fica 1000 mesmo criando com `sudo`.

   ```bash
   mkdir -p /mnt/nas/userdata/nextcloud/data
   chmod 0770 /mnt/nas/userdata/nextcloud/data
   stat -c '%u:%g %a' /mnt/nas/userdata/nextcloud/data   # esperado: 1000:1000 770
   ```

   Se o dono não for `1000:1000`, o export está sem `all_squash`. Corrija no OMV e rode `chown -R 1000:1000 <pasta-userdata-no-omv>/nextcloud` **no shell do OMV**.

A pasta de dados precisa estar **vazia** na primeira subida.

## 3. Primeira subida

```bash
cd ~/bergatrix/03-apps/nextcloud
cp .env.example .env
chmod 600 .env
# Preencha DOMAIN, POSTGRES_PASSWORD, NEXTCLOUD_REDIS_PASSWORD,
# NEXTCLOUD_ADMIN_PASSWORD e o client ID e secret do Authentik.
docker compose config --quiet
docker compose up -d
docker compose logs -f app   # espere "Nextcloud was successfully installed" e "resuming normal operations"
```

A instalação cria:
- o admin local `admin-local`, que vai ser desativado no passo 7;
- o usuário de banco `oc_admin`, guardado no `config.php`. O `POSTGRES_USER` continua sendo o superusuário do banco.

## 4. Teste do NFS (antes de qualquer arquivo)

Os clientes de sincronização dependem de poder gravar a data de alteração e as permissões. Teste com o usuário do container:

```bash
docker exec -u 33 nextcloud-app sh -c 'cd /var/www/data && touch -d "2020-01-01 12:00:00" teste-nfs && chmod 0640 teste-nfs && stat -c "%u:%g %a %y" teste-nfs && rm teste-nfs'
# esperado: 1000:1000 640 2020-01-01 12:00:00...
ls -la /mnt/nas/userdata/nextcloud/data   # tem o .ncdata, com dono 1000
```

Se der `Permission denied` ou `Operation not permitted`, revise o export antes de seguir.

## 5. Configuração inicial (`occ`)

```bash
occ() { docker exec -u 33 nextcloud-app php occ "$@"; }

occ background:cron                                    # o container nextcloud-cron roda a cada 5 min
occ config:system:set default_phone_region --value=BR
occ config:system:set maintenance_window_start --type=integer --value=5   # 05h UTC = 02h em Brasília
occ config:system:set skeletondirectory --value=''     # conta nova começa vazia
occ db:add-missing-indices
occ maintenance:repair --include-expensive             # migrações de mimetype (pode demorar)
occ app:install user_oidc
occ app:install calendar
occ app:install contacts
```

Confira a configuração atrás do proxy:

```bash
for k in trusted_proxies overwriteprotocol overwritehost overwrite.cli.url memcache.locking datadirectory; do
  printf '%s = ' "$k"; occ config:system:get "$k"
done
```

## 6. Login pelo Authentik (OIDC)

1. **O Nextcloud alcança o Authentik?** Ele baixa a configuração OIDC pelo endereço público:

   ```bash
   . ./.env
   docker exec -u 33 nextcloud-app curl -sS -o /dev/null -w '%{http_code} %{remote_ip}\n' \
     "https://authentik.${DOMAIN}/application/o/nextcloud/.well-known/openid-configuration"
   ```

   - Se der `200` com IP público, siga para o passo 2.
   - Se o IP for privado (`10.x`, `172.16–31.x`, `192.168.x`), o Nextcloud bloqueia a conexão por padrão. Libere com:

     ```bash
     occ config:system:set allow_local_remote_servers --type=boolean --value=true
     ```

2. **Cadastre o provider.** O secret sai do `.env` e não fica no histórico do shell:

   ```bash
   set -a; . ./.env; set +a
   occ user_oidc:provider Authentik \
     --clientid="$NEXTCLOUD_SSO_CLIENT_ID" \
     --clientsecret="$NEXTCLOUD_SSO_CLIENT_SECRET" \
     --discoveryuri="https://authentik.${DOMAIN}/application/o/nextcloud/.well-known/openid-configuration" \
     --scope="openid email profile nextcloud" \
     --unique-uid=0 \
     --mapping-uid=user_id \
     --mapping-display-name=name \
     --mapping-email=email \
     --mapping-quota=quota \
     --mapping-groups=groups \
     --group-provisioning=1 \
     --send-id-token-hint=1
   occ user_oidc:provider Authentik   # confere
   ```

   O `--unique-uid=0` usa o `user_id` do Authentik como está, e não um hash. É isso que mantém os IDs legíveis (`nextcloud_user_id`) e entrega o grupo `admin`.

3. **Teste** numa janela anônima:
   - Abra `https://storange.example.com`, clique em *Entrar com Authentik* e passe pelo login com 2FA.
   - Depois confira:

     ```bash
     occ user:list
     occ group:list   # sua conta deve estar em "admin"
     ```

## 7. Fechar o login local

Só depois que a sua conta do Authentik estiver no grupo `admin`:

```bash
occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends   # a página de login vai direto para o Authentik
occ user:disable admin-local
```

**Emergência** (Authentik fora do ar), pelo SSH via VPN:
1. Rode `occ user:enable admin-local`.
2. Entre por `https://storange.example.com/login?direct=1` com a senha do `.env`.
3. Quando terminar, rode `occ user:disable admin-local` de novo.

## 8. Clientes

- **Desktop e app do celular:** servidor `https://storange.example.com`. O app abre o navegador e passa pelo Authentik. Depois, clique em *Conceder acesso*.
- **Agenda e contatos no Android:**
  - Pelo app do Nextcloud: *Configurações → Sincronizar agenda e contatos*. Ele configura o DAVx⁵ sozinho.
  - Ou direto no DAVx⁵, com URL `https://storange.example.com/remote.php/dav`, o seu usuário do Nextcloud e uma senha de app.
- **iPhone (CalDAV/CardDAV):** servidor `storange.example.com`, o seu usuário e uma senha de app.
- **WebDAV:** `https://storange.example.com/remote.php/dav/files/<usuário>/`, com senha de app.

As senhas de app são criadas em *Configurações pessoais → Segurança → Dispositivos e sessões*, uma por dispositivo, e é ali que você revoga uma senha de um aparelho perdido. Elas não passam pelo 2FA do Authentik.

## 9. Conferir

```bash
curl -sI https://storange.example.com/.well-known/caldav | grep -iE '^(HTTP|location)'
# 301 e location: https://storange.example.com/remote.php/dav/
curl -sI https://storange.example.com/status.php | grep -i strict-transport-security
occ setupchecks
docker exec crowdsec cscli parsers list | grep nextcloud-whitelist
```

No `setupchecks`, alguns avisos podem ficar:
- "*two-factor authentication is not enforced*": o 2FA é feito no Authentik.
- "*Email test*": só some depois de configurar o SMTP.
- "*AppAPI deploy daemon*": é para Ex-Apps, que não usamos.

## Atualizar

- **Uma versão major por vez**, sempre a partir do último patch da atual: `34.0.x` → último `34` → `35.0.x`. O container se recusa a pular uma major e a fazer downgrade.
- Antes, faça o dump do banco ([Backup](#backup)).
- Troque a tag nos **dois** serviços (`app` e `cron`) e rode:

  ```bash
  docker compose pull && docker compose up -d && docker compose logs -f app
  occ app:update --all
  occ db:add-missing-indices
  ```

## Backup

O que o serviço de backup precisa copiar, com `occ maintenance:mode --on` durante a cópia e `--off` no fim:

| O quê | Como |
|---|---|
| Banco | `docker exec nextcloud-db pg_dump -U nextcloud -Fc nextcloud > nextcloud.dump` |
| `${APPDATA_PATH}/nextcloud/html/config/` | Cópia. O `config.php` tem o `instanceid`, o `secret` e a senha do banco. Sem ele, a restauração não funciona. |
| `${USERDATA_PATH}/nextcloud/data/` | Cópia. Pode excluir `appdata_*/preview`, que é recriado. |

O resto de `html/` (código e `custom_apps`) volta com a imagem e com `occ app:install`.

## Problemas comuns

- **A instalação falhou e o container fica reiniciando** ("o Nextcloud não está instalado; o Apache não vai subir"):
  1. Veja a causa no começo do log (`docker compose logs app | head -80`).
  2. Corrija e apague o que a tentativa criou: `docker compose down`, `sudo rm -rf /srv/appdata/nextcloud/{html,postgres}` e o conteúdo de `/mnt/nas/userdata/nextcloud/data`.
  3. Recrie a pasta `html` (passo 2) e suba de novo.
- **Arquivos mexidos direto no NAS** não aparecem no Nextcloud. Não edite a pasta por fora. Se editar, rode `occ files:scan --all`.
- **Criptografia no servidor:** não ligue. O OIDC não entrega a senha ao Nextcloud, e isso complica a restauração.
- **Upload grande por WebDAV puro** (Explorer do Windows, davfs), sem pedaços, depende do `readTimeout` do entrypoint `websecure` no `traefik.yml`. O app e os clientes oficiais enviam em pedaços.
