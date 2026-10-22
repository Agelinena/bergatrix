# Migração para o novo armazenamento

Passo a passo para levar os dados do servidor antigo (Ubuntu com tudo no HD de 1 TB) para o novo layout: configs e bancos no HD local, mídia no NAS. As regras de destino estão em [02-armazenamento.md](02-armazenamento.md).

> Este documento é de uso único. Depois da migração, ele fica só como histórico.

## Antes de começar

- [ ] VM do OMV no ar, com as pastas compartilhadas `media` e `userdata` exportadas por NFS.
- [ ] VM Docker com o HD de 1 TB montado em `/srv` e o NFS em `/mnt/nas/media` ([montagem](02-armazenamento.md#montagem-no-servidor-docker)).
- [ ] `RequiresMountsFor` no `docker.service` e a ordem de boot configurada no Proxmox.
- [ ] Nenhum container rodando sobre os dados antigos (`docker compose down` em todas as stacks).

### Dois cenários para o HD de 1 TB

**A. O HD continua com os dados antigos (recomendado).** Entregue o disco inteiro à VM Docker sem formatar e monte-o em `/srv`. As configs mudam de lugar com `mv` dentro do mesmo disco, o que é instantâneo. Só a mídia atravessa a rede até o NAS.

```bash
# No Proxmox: disco físico inteiro para a VM (troque o id da VM e do disco)
qm set <vmid> -scsi1 /dev/disk/by-id/<id-do-hd-1tb>
```

**B. O HD vai ser formatado.** Antes de formatar, copie **tudo** para o NAS: a mídia direto para o destino final e as configs para uma pasta temporária, como `userdata/_migracao`. Depois, formate, monte em `/srv` e traga as configs de volta. A pasta temporária vale como um backup de segurança até tudo estar funcionando.

Nos comandos abaixo, `ANTIGO` é a pasta de dados antiga de cada stack (o valor que `STORAGE_PATH`, `VOLUMES_BASE` ou `*_DATA_DIR` tinha no `.env`). No cenário A, ela agora aparece embaixo de `/srv`.

## 1. Criar as raízes

```bash
sudo mkdir -p /srv/appdata /srv/cache
sudo chown 1000:1000 /srv/appdata /srv/cache
mkdir -p /mnt/nas/media/{filmes,series,downloads,musica/bergastream/deemix_dl,musica/lidarr}
```

## 2. Mover os dados de cada stack

No cenário A, o script [`scripts/migrar-dados.py`](../scripts/migrar-dados.py) aplica o mapa abaixo inteiro de dentro de `/srv/docker_volumes`:

- só usa `mv`, que é instantâneo no mesmo disco, e não apaga nada;
- copia o `acme.json` do repositório;
- leva para `/srv/_legado` tudo que não está no mapa: stacks que saíram e pastas fora de `docker_volumes`.

```bash
sudo python3 scripts/migrar-dados.py             # mostra o que faria, com os tamanhos
sudo python3 scripts/migrar-dados.py --aplicar   # move
```

**Mídia provisória no HD:** se o NFS do NAS ainda não estiver pronto, o script põe a mídia em `/srv/media` (padrão do `--media`). Use `MEDIA_PATH=/srv/media` nos `.env` até lá: `python3 scripts/migrar-env.py --media /srv/media --aplicar`. Quando o NAS estiver montado, copie com `rsync` (próximo item) e troque o valor em todas as stacks:

```bash
sed -i 's#^MEDIA_PATH=.*#MEDIA_PATH=/mnt/nas/media#' ~/bergatrix/0*/*/.env
```

Para fazer à mão, ou no cenário B:

- **Configs e bancos** (cenário A): `sudo mv ANTIGO/x /srv/appdata/<stack>/y`. No cenário B, use `sudo rsync -aHAX`.
- **Mídia** (rede): `sudo rsync -aHAX --info=progress2 ANTIGO/x/ /mnt/nas/media/y/`. Confira o resultado antes de apagar a origem.
- Sempre com os containers parados. Os bancos Postgres usam a mesma imagem (`postgres:16`), então a pasta é copiada como está.

### Mapa antigo → novo

| Stack | Antes | Depois |
|---|---|---|
| cloudbeaver | `ANTIGO/cloudbeaver` | `${APPDATA_PATH}/cloudbeaver/workspace` |
| traefik | `01-network/traefik/config/acme.json` (dentro do repositório) | `${APPDATA_PATH}/traefik/acme/acme.json` (`chmod 600`) |
| traefik | `ANTIGO/traefik/logs` | `${APPDATA_PATH}/traefik/logs` |
| authentik | `ANTIGO/authentik/database` | `${APPDATA_PATH}/authentik/postgres` |
| authentik | `ANTIGO/authentik/{redis,media,certs}` | `${APPDATA_PATH}/authentik/{redis,media,certs}` |
| authentik | `ANTIGO/authentik/custom-templates` | `${APPDATA_PATH}/authentik/templates` |
| bitwarden | `ANTIGO/vaultwarden` | `${APPDATA_PATH}/bitwarden/vaultwarden` |
| crowdsec | `ANTIGO/crowdsec/{config,data}` | `${APPDATA_PATH}/crowdsec/{config,data}` |
| bergalink | `ANTIGO/bergalink/{postgres,avatars,secrets}` | `${APPDATA_PATH}/bergalink/{postgres,avatars,secrets}` |
| bergastream | `ANTIGO/db` | `${APPDATA_PATH}/bergastream/postgres` |
| bergastream | `ANTIGO/redis` | `${APPDATA_PATH}/bergastream/redis` |
| bergastream | `ANTIGO/deemix/config` | `${APPDATA_PATH}/bergastream/deemix` |
| bergastream | `ANTIGO/lidarr/config` | `${APPDATA_PATH}/bergastream/lidarr` |
| bergastream | `ANTIGO/youtube` | `${APPDATA_PATH}/bergastream/youtube` |
| bergastream | `ANTIGO/pydeps` | `${CACHE_PATH}/bergastream/pydeps` (ou não copiar: é baixado de novo) |
| bergastream | `ANTIGO/music` | `${MEDIA_PATH}/musica/bergastream` |
| bergastream | `ANTIGO/deemix/downloads` | `${MEDIA_PATH}/musica/bergastream/deemix_dl` |
| bergastream | `ANTIGO/lidarr/music` | `${MEDIA_PATH}/musica/lidarr` |
| homeassistant | `ANTIGO/homeassistant/config` | `${APPDATA_PATH}/homeassistant/config` |
| jellyfin | `ANTIGO/config/{jellyfin,catalogo,qbittorrent,sonarr,radarr,prowlarr,bazarr,sabnzbd,recyclarr}` | `${APPDATA_PATH}/jellyfin/<mesmo nome>` |
| jellyfin | `ANTIGO/config/legendarr/{jobs,stats}` | `${APPDATA_PATH}/jellyfin/legendarr/{jobs,stats}` |
| jellyfin | `ANTIGO/{filmes,series,downloads}` | `${MEDIA_PATH}/{filmes,series,downloads}` |
| jellyfin | Outras pastas de biblioteca na raiz de `ANTIGO` | `${MEDIA_PATH}/<mesmo nome>` |
| jellyfin | `ANTIGO/incomplete` | não copiar: deixe a fila do SABnzbd terminar antes |
| jellyfin | `03-apps/jellyfin/temp` (dentro do repositório) | não copiar (era temporário do optimizer) |
| litellm | `ANTIGO` (`LITELLM_DATA_DIR`) | `${APPDATA_PATH}/litellm/postgres` |
| n8n | `ANTIGO` (`N8N_DATA_DIR`) | `${APPDATA_PATH}/n8n/data` |
| openuiweb | `ANTIGO` (`OPENWEBUI_DATA_DIR`) | `${APPDATA_PATH}/openuiweb/open-webui` |
| openuiweb | `ANTIGO` (`DATA_DIR`, Ollama) | `${CACHE_PATH}/openuiweb/ollama` (ver atenção abaixo) |
| transcriptor | `ANTIGO/transcriptor`, sem a pasta `models` | `${APPDATA_PATH}/transcriptor/data` |
| transcriptor | `ANTIGO/transcriptor/models` | `${CACHE_PATH}/transcriptor/models` |
| homepage | `ANTIGO/config` (`HOMEPAGE_PATH`) | `${APPDATA_PATH}/homepage/config` |
| wazuh | `ANTIGO` (`WAZUH_DATA_DIR`), tudo | `${APPDATA_PATH}/wazuh` (mesma estrutura interna) |

## 3. Atualizar os `.env`

O script [`scripts/migrar-env.py`](../scripts/migrar-env.py) converte todos os `.env` de uma vez:

- renomeia as variáveis que mudaram;
- comenta as que saíram, deixando o valor antigo no arquivo para consulta;
- acrescenta o bloco base que faltar;
- no fim, lista onde os dados de cada stack estão hoje.

```bash
cd ~/bergatrix
python3 scripts/migrar-env.py             # mostra o que mudaria, sem gravar
python3 scripts/migrar-env.py --aplicar   # grava; backup em .env.antes-migracao-<data>
```

As raízes padrão são `/srv/appdata`, `/srv/cache` e `/mnt/nas/media`; para trocar, use `--appdata`, `--cache` e `--media`. Com `--aplicar`, ele também roda `docker compose config` em cada stack. Rodar de novo não muda nada.

Stacks sem `.env` são listadas no fim. Crie o `.env` delas a partir do `.env.example`. Variáveis que mudaram:

| Stack | Antes | Agora |
|---|---|---|
| todas | `STORAGE_PATH`, `VOLUMES_BASE`, `*_DATA_DIR`, `HOMEPAGE_PATH` | `APPDATA_PATH`, `CACHE_PATH`, `MEDIA_PATH` (só as que a stack usa) |
| traefik | `SUBDOMAIN_TRAEFIK_DASHBOARD` | removida: o painel fica em `traefik.${DOMAIN}` |
| authentik | `PG_PASS` | `POSTGRES_PASSWORD` |
| bitwarden | `ADMIN_TOKEN` | `VAULTWARDEN_ADMIN_TOKEN` |
| bitwarden, crowdsec, homepage | fuso e IDs fixos no compose | `TZ`, `PUID`, `PGID` no `.env` |
| bergastream | `USENET_DOWNLOADS_DIR` | removida: é sempre `${MEDIA_PATH}/downloads` |
| litellm | `LITELLM_DB_PASSWORD` | `POSTGRES_PASSWORD` |
| n8n | `N8N_DOMAIN` | removida: o n8n fica em `n8n.${DOMAIN}` |
| n8n | `TIMEZONE` | `TZ` |
| openuiweb | `WEBUI_SECRET_KEY` | `OPENWEBUI_SECRET_KEY` |
| transcriptor | `API_KEY`, `SECRET_KEY` | `TRANSCRIPTOR_API_KEY`, `TRANSCRIPTOR_SECRET_KEY` |

Antes de subir cada stack, valide: `docker compose config --quiet`. Uma raiz faltando dá o erro `required variable … is missing a value`.

## 4. Pontos de atenção

- **Endereço do n8n:** agora é fixo em `n8n.${DOMAIN}`. Se o antigo `N8N_DOMAIN` era outro, ajuste o subdomínio no compose: webhooks cadastrados em serviços de terceiros dependem dele.
- **Painel do Traefik:** agora em `traefik.${DOMAIN}`. Ajuste o compose se o antigo era outro.
- **Ollama:** o compose antigo dizia que a pasta do Ollama também guardava a pasta do "Mímesis". Se ela tiver algo além de modelos, separe antes: `CACHE_PATH` não tem backup.
- **Legendarr e optimizer** agora veem só `filmes` e `series`, e não mais a pasta inteira de dados com as configs e chaves dos outros apps.
- **Jellyfin** ganhou uma pasta `/cache` própria (`${CACHE_PATH}/jellyfin/jellyfin`). Transcodes e imagens temporárias saem da config.
- **SABnzbd:** a pasta de downloads em andamento (`/incomplete-downloads`) agora fica no disco local. As pastas internas dos containers não mudaram, então nenhuma configuração dentro dos apps (bibliotecas do Jellyfin, pastas raiz dos *arr, clientes de download) precisa ser refeita.
- **CloudBeaver:** a rede `bergatrix-db-internal` saiu do compose (o Postgres global não existe mais). Ele sobe, mas não alcança os bancos, que estão em redes internas.
- **Ambiente local do Bergastream:** o `.env` de desenvolvimento precisa trocar `STORAGE_PATH=./.data` por:

  ```bash
  APPDATA_PATH=./.data/appdata
  CACHE_PATH=./.data/cache
  MEDIA_PATH=./.data/media
  ```

  E reorganizar `./.data` pelo mesmo mapa da seção 2.

## 5. Conferir depois de subir

- [ ] `docker compose ps` em cada stack: tudo `running` ou `healthy`.
- [ ] Nada foi criado fora das raízes: `ls /` não mostra pastas com nome de stack (`/jellyfin`, `/bergastream`…).
- [ ] Certificado válido (o Traefik reaproveitou o `acme.json`, sem pedir um novo).
- [ ] Jellyfin reproduz um filme; Sonarr e Radarr enxergam as pastas raiz; o SABnzbd conclui um download de teste.
- [ ] Bergastream toca uma música do cache e uma nova.
- [ ] Reiniciar a VM Docker com o NAS desligado: o Docker deve esperar, e não subir os containers sobre pastas vazias.
