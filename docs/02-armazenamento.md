# Armazenamento

Onde cada tipo de dado fica, o que entra no backup e como as pastas são montadas no servidor Docker.

Toda stack usa só estas quatro raízes. Nenhum compose aponta para um caminho absoluto do host.

## As quatro raízes

| Variável | Onde fica | Valor padrão | O que guarda | Backup |
|---|---|---|---|---|
| `APPDATA_PATH` | HD local da VM Docker | `/srv/appdata` | Configurações, bancos (Postgres, SQLite, Redis), certificados, segredos em arquivo, logs de segurança | **Sim** |
| `CACHE_PATH` | HD local da VM Docker | `/srv/cache` | O que pode ser apagado e se refaz sozinho: modelos de IA, transcodes, downloads em andamento, temporários | Não |
| `MEDIA_PATH` | NAS (NFS) | `/mnt/nas/media` | Mídia que pode ser baixada de novo: filmes, séries, músicas, downloads concluídos | Não |
| `USERDATA_PATH` | NAS (NFS) | `/mnt/nas/userdata` | Acervos pessoais que **não** podem ser baixados de novo: fotos (Immich), arquivos (Nextcloud) | **Sim** |

`USERDATA_PATH` ainda não é usada por nenhuma stack; está reservada para Immich e Nextcloud.

### Como decidir onde um volume vai

Pergunte, nesta ordem:

1. **É banco de dados, SQLite ou algo que o app trava com lock?** → `APPDATA_PATH`. Nunca em NFS: Postgres e SQLite corrompem ou travam sobre rede. Isso inclui a pasta `/config` dos *arr, do Jellyfin, do Home Assistant, do Vaultwarden, do n8n e do Open WebUI, que guardam SQLite lá dentro.
2. **Se eu apagar, perco algo que não volta?**
   - Sim, e é pequeno e ligado a um app (config, avatar, chave) → `APPDATA_PATH`.
   - Sim, e é um acervo grande de pessoas (fotos, documentos) → `USERDATA_PATH`.
3. **Dá para baixar de novo?** → `MEDIA_PATH`.
4. **O próprio app recria sozinho?** → `CACHE_PATH`.

Na dúvida entre `APPDATA_PATH` e `CACHE_PATH`, use `APPDATA_PATH`: sobra espaço no disco local, e backup a mais não quebra nada.

## Layout das pastas

### `APPDATA_PATH` e `CACHE_PATH`: uma pasta por stack

```
${APPDATA_PATH}/<stack>/<pasta>
${CACHE_PATH}/<stack>/<pasta>
```

- `<stack>` é o nome da pasta da stack no repositório (`jellyfin`, `bergastream`, `bitwarden`…).
- `<pasta>` é um nome curto e único dentro da stack: o nome do serviço (`sonarr`, `vaultwarden`), o motor do banco (`postgres`, `redis`) ou o conteúdo (`media`, `models`), o que for mais claro.
- Quando um serviço tem mais de uma pasta, use subpastas: `legendarr/jobs`, `legendarr/stats`.
- **Nunca** monte a pasta da stack inteira, nem a raiz, num container.

Backup, restauração e migração ficam simples: copiar ou restaurar `${APPDATA_PATH}/<stack>` leva a stack inteira.

### `MEDIA_PATH`: por tipo de mídia, compartilhado entre stacks

```
${MEDIA_PATH}/
├── filmes/                 Radarr, Bazarr, Jellyfin, Legendarr
├── series/                 Sonarr, Bazarr, Jellyfin, Legendarr
├── musica/
│   ├── bergastream/        biblioteca do Bergastream (cache, permanent, variants, covers,
│   │   └── deemix_dl/      image_cache) e downloads do Deemix
│   └── lidarr/             passagem dos álbuns do Lidarr
└── downloads/              qBittorrent e SABnzbd (concluídos), lidos por Sonarr, Radarr e Lidarr
```

A mídia é organizada por tipo, e não por stack, porque vários stacks leem as mesmas pastas e porque é assim que ela aparece quando você navega no NAS pela rede.

Os downloads ficam na mesma raiz da biblioteca de propósito: hardlinks e `mv` só funcionam dentro do mesmo sistema de arquivos.

### `USERDATA_PATH`: uma pasta por stack (futuro)

```
${USERDATA_PATH}/immich/
${USERDATA_PATH}/nextcloud/
```

## Mapa atual por stack

| Stack | `APPDATA_PATH/<stack>/` | `CACHE_PATH/<stack>/` | `MEDIA_PATH/` |
|---|---|---|---|
| cloudbeaver | `workspace` | – | – |
| traefik | `acme` (acme.json), `logs` | – | – |
| authentik | `postgres`, `redis`, `media`, `templates`, `certs` | – | – |
| bitwarden | `vaultwarden` | – | – |
| crowdsec | `config`, `data` (lê `traefik/logs`) | – | – |
| bergalink | `postgres`, `avatars`, `secrets` | – | – |
| bergastream | `postgres`, `redis`, `deemix`, `lidarr`, `youtube` | `pydeps` | `musica/bergastream`, `musica/lidarr`, `downloads` |
| drop | – | – | – |
| homeassistant | `config` | – | – |
| jellyfin | `jellyfin`, `catalogo`, `qbittorrent`, `sonarr`, `radarr`, `prowlarr`, `bazarr`, `sabnzbd`, `recyclarr`, `legendarr/jobs`, `legendarr/stats` | `jellyfin` (transcodes), `optimizer`, `incomplete` | raiz inteira (Jellyfin), `filmes`, `series`, `downloads` |
| litellm | `postgres` | – | – |
| n8n | `data` | – | – |
| openuiweb | `open-webui` | `ollama` | – |
| transcriptor | `data` | `models` | – |
| wazuh | `wazuh_manager`, `wazuh_indexer`, `wazuh_dashboard`, `filebeat`, `config` | – | – |

## Montagem no servidor Docker

### Disco local (HD de 1 TB)

O Proxmox entrega o HD inteiro à VM Docker. Dentro dela, o disco tem um sistema de arquivos montado em `/srv`, com as duas raízes locais:

```
/srv/appdata   → APPDATA_PATH
/srv/cache     → CACHE_PATH
```

Exemplo de `/etc/fstab` (pegue o UUID com `blkid`):

```fstab
UUID=<uuid-do-hd>  /srv  ext4  defaults,noatime  0  2
```

### NAS (OpenMediaVault, NFS)

O OMV exporta duas pastas compartilhadas, uma por raiz, porque elas têm políticas de backup diferentes:

| Pasta no OMV | Montada em | Variável |
|---|---|---|
| `media` | `/mnt/nas/media` | `MEDIA_PATH` |
| `userdata` | `/mnt/nas/userdata` | `USERDATA_PATH` |
| `backups` | não é exportada | Cópias de `APPDATA_PATH` (destino do backup). Nunca compartilhe: contém bancos e segredos. |

No HD do NAS, as três ficam lado a lado na raiz do filesystem: `media/`, `userdata/` e `backups/`.

Exemplo de `/etc/fstab`:

```fstab
<ip-do-nas>:/media     /mnt/nas/media     nfs4  _netdev,x-systemd.automount,x-systemd.mount-timeout=30,hard,noatime  0  0
<ip-do-nas>:/userdata  /mnt/nas/userdata  nfs4  _netdev,x-systemd.automount,x-systemd.mount-timeout=30,hard,noatime  0  0
```

> Com NFSv4 o OMV publica as pastas relativas a `/export`, por isso o caminho é `/media`, e não `/export/media`. Confira em *Serviços → NFS → Compartilhamentos*.

### O Docker só sobe depois dos discos

Se o Docker iniciar antes do NAS, os containers gravam dentro da pasta de montagem vazia, no disco local, e ninguém percebe. Para evitar:

1. **No Proxmox:** VM do OMV com *Start/Shutdown order* `1` e a VM Docker com ordem `2` e *Startup delay* de uns 60 s.
2. **Na VM Docker:** faça o serviço do Docker exigir as montagens:

   ```bash
   sudo systemctl edit docker.service
   ```

   ```ini
   [Unit]
   RequiresMountsFor=/srv /mnt/nas/media
   ```

3. **Nos composes:** toda raiz é usada como `${APPDATA_PATH:?}`. Se a variável faltar no `.env`, o `docker compose` para com erro, em vez de criar pastas em `/`.

### Permissões

- Os containers gravam como `PUID:PGID`, que por padrão é `1000:1000`. As pastas criadas à mão precisam desse dono: `sudo chown -R 1000:1000 <pasta>`.
- **Export `media`:** use `all_squash,anonuid=1000,anongid=1000` no OMV. Todo arquivo gravado pelo NFS fica com o dono 1000, inclusive o de containers que ainda rodam como root (Legendarr, optimizer). O UID 1000 precisa ser o dono da pasta compartilhada no OMV.
- **Export `userdata`:** as opções serão definidas quando o Immich e o Nextcloud entrarem, pois cada um grava com o próprio usuário.

### O que não vai para o NAS

- **Bancos e configs**, pelos motivos do passo 1 de "Como decidir".
- **Downloads em andamento** (`CACHE_PATH/jellyfin/incomplete`): são milhares de gravações pequenas. O SABnzbd move para o NAS só quando termina.
- **Modelos de IA e transcodes:** são lidos o tempo todo e ficam mais rápidos no disco local.

## Backup

| Raiz | Política |
|---|---|
| `APPDATA_PATH` | Diário. Bancos por dump (`pg_dump`, `sqlite3 .backup`), nunca copiando a pasta com o container rodando. Destino: NAS (outro disco) e uma cópia criptografada fora de casa. |
| `CACHE_PATH` | Nunca. |
| `MEDIA_PATH` | Nunca. Perder o disco do NAS significa baixar de novo. |
| `USERDATA_PATH` | Obrigatório quando houver dados: outro disco (ou RAID) e uma cópia fora de casa. |

> **Estado atual:** a política acima ainda não está implementada. Ela é a próxima etapa depois da migração.
