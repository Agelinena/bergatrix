# Infraestrutura

Visão geral do servidor: as máquinas, os discos, as stacks e o que depende do quê. Valores reais (domínio, IPs, hardware exato) ficam no repositório privado.

## Máquinas e discos

```
Servidor físico ─ Proxmox VE
│
├── SSD ───────────── Proxmox e discos de sistema das VMs
│
├── VM OpenMediaVault (NAS)
│   └── HD 4 TB ───── pastas compartilhadas por NFS: media, userdata
│                     (mais discos no futuro, com RAID ou mergerfs)
│
└── VM Ubuntu Server (Docker)
    ├── HD 1 TB ───── /srv: appdata (configs e bancos) e cache
    ├── NFS ───────── /mnt/nas/media, /mnt/nas/userdata
    └── GPU ───────── passthrough: Jellyfin, Ollama, Transcriptor, optimizer
```

| Disco | Dono | Papel |
|---|---|---|
| SSD | Proxmox | Sistema do host e das VMs |
| HD 1 TB | VM Docker (inteiro) | `APPDATA_PATH` e `CACHE_PATH`: tudo que precisa de disco local |
| HD 4 TB | VM OMV (inteiro) | NAS: `MEDIA_PATH`, `USERDATA_PATH` e compartilhamentos da rede |

Detalhes de pastas, montagem e backup: [02-armazenamento.md](02-armazenamento.md).

## Caminho do tráfego

```
Internet ─▶ proxy externo (PROXY protocol) ─▶ Traefik :443 ─▶ CrowdSec (bouncer) ─▶ app
Rede local ─────────────────────────────────▶ Traefik :443 ─▶ app
```

- O **Traefik** termina o TLS com um certificado curinga `*.${DOMAIN}` (Let's Encrypt, desafio DNS no deSEC) e roteia pelos labels dos containers.
- O **CrowdSec** lê o `access.log` do Traefik e bloqueia IPs pelo plugin bouncer.
- O **Authentik** é o provedor de identidade. Hoje protege a maioria dos apps por forward-auth no Traefik; o destino é login OIDC dentro de cada app (ver [03-padrao-stacks.md](03-padrao-stacks.md#acesso-traefik-e-autenticação)).

## Stacks

| Camada | Stack | O que roda | Endereços (`*.${DOMAIN}`) | Raízes |
|---|---|---|---|---|
| 00 | cloudbeaver | CloudBeaver | `db` | appdata |
| 01 | traefik | Traefik + plugin CrowdSec | `traefik` (painel) | appdata |
| 02 | authentik | Authentik (server, worker, outpost LDAP), Postgres, Redis | `authentik`, `auth` | appdata |
| 02 | bitwarden | Vaultwarden | `bitwarden` | appdata |
| 02 | crowdsec | CrowdSec | – | appdata |
| 03 | bergalink | API própria (localização em família), Postgres | `bergalink` | appdata |
| 03 | bergastream | Streaming de música próprio: API, worker, web, Postgres, Redis, Deemix, Lidarr, PO Token | `bergastream`, `lidarr` | appdata, cache, media |
| 03 | drop | Transferência de arquivos cifrada (sem disco) | `drop` | – |
| 03 | homeassistant | Home Assistant | `ha` | appdata |
| 03 | jellyfin | Jellyfin, Seerr, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, FlareSolverr, indexador BR, Recyclarr, Legendarr (web, worker, optimizer) | `jellyflix`, `catalogo`, `legendarr` e um por serviço *arr | appdata, cache, media |
| 03 | ollama | Ollama (GPU), sem rota | – | cache |
| 03 | transcriptor | Transcrição com faster-whisper (GPU) | `transcriptor` | appdata, cache |
| 04 | wazuh | Wazuh manager, indexer, dashboard | `wazuh` (+ portas 1514, 1515, 514/udp, 55000 para agentes) | appdata |

### Ordem de subida

A ordem fica em [`00-infrastructure/stacks.txt`](../00-infrastructure/stacks.txt), e os scripts `subir-tudo.sh` e `derrubar-tudo.sh` a seguem. Veja [07-ligar-e-desligar.md](07-ligar-e-desligar.md).

## Dependências entre stacks

Elas se falam pelo nome do container, numa rede compartilhada ([06-redes.md](06-redes.md)). Mudar um destes nomes, ou tirar o serviço da rede, quebra a stack que depende dele.

| Quem usa | Usa o quê | Endereço | Rede |
|---|---|---|---|
| Traefik (forward-auth), Bergalink e Bergastream (OIDC) | Authentik | `authentik-server:9000` | `bergatrix-proxy` |
| Jellyfin (plugin LDAP) | Outpost LDAP do Authentik | `authentik-ldap:3389` | `bergatrix-ldap` |
| Traefik (bouncer) | CrowdSec | `crowdsec:8080` | `bergatrix-proxy` |
| CrowdSec | Log do Traefik | `${APPDATA_PATH}/traefik/logs` | (arquivo) |
| Legendarr worker | Ollama | `ollama:11434` | `bergatrix-ai` |
| Lidarr (bergastream) | SABnzbd e Prowlarr (stack jellyfin) | `sabnzbd:8080`, `prowlarr:9696` | `bergatrix-media` |
| Lidarr (bergastream) | Downloads do SABnzbd | `${MEDIA_PATH}/downloads` | (mesma pasta) |

## Redes Docker

Redes compartilhadas, redes de cada stack e as regras: [06-redes.md](06-redes.md).

## Repositórios

- **Este repositório (público):** stacks, código dos apps próprios e documentação de padrão, sem valores reais.
- **Repositório privado (planejado):** complemento com domínios, IPs, configuração do Authentik, Proxmox e OMV, e o passo a passo com dados reais.
