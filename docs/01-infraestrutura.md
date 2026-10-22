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
| 03 | litellm | LiteLLM, Postgres, sincronizador de modelos | `llm` | appdata |
| 03 | n8n | n8n com Python | `n8n` | appdata |
| 03 | openuiweb | Open WebUI, Ollama (GPU) | `chat` | appdata, cache |
| 03 | transcriptor | Transcrição com faster-whisper (GPU) | `transcriptor` | appdata, cache |
| 04 | wazuh | Wazuh manager, indexer, dashboard | `wazuh` (+ portas 1514, 1515, 514/udp, 55000 para agentes) | appdata |

### Ordem de subida

1. `docker network create bergatrix-proxy` (uma vez)
2. `01-network/traefik` e `02-security/crowdsec`
3. `02-security/authentik`
4. Demais stacks, em qualquer ordem, respeitando as dependências abaixo.

## Dependências entre stacks

Elas se falam pelo nome do container na rede `bergatrix-proxy`. Mudar um destes nomes, ou tirar o serviço da rede, quebra a stack que depende dele.

| Quem usa | Usa o quê | Endereço |
|---|---|---|
| Traefik (forward-auth), Bergalink (JWKS) | Authentik | `authentik-server:9000` |
| Jellyfin (plugin LDAP) | Outpost LDAP do Authentik | `authentik-ldap:3389` |
| Traefik (bouncer) | CrowdSec | `crowdsec:8080` |
| CrowdSec | Log do Traefik | `${APPDATA_PATH}/traefik/logs` (arquivo) |
| Open WebUI, sincronizador do LiteLLM, Legendarr worker | Ollama (stack openuiweb) | `ollama:11434` |
| Open WebUI | LiteLLM | `litellm:4000` |
| Lidarr (bergastream) | SABnzbd e Prowlarr (stack jellyfin) | `sabnzbd:8080`, `prowlarr:9696` |
| Lidarr (bergastream) | Downloads do SABnzbd | `${MEDIA_PATH}/downloads` (mesma pasta) |

## Redes Docker

| Rede | Tipo | Quem cria |
|---|---|---|
| `bergatrix-proxy` | Compartilhada entre stacks | Manual: `docker network create bergatrix-proxy` |
| `bergastream-internal`, `bergalink-internal`, `litellm-internal` | Internas, sem internet | A própria stack |
| `bergastream-egress`, `litellm-egress` | Saída para a internet de serviços internos | A própria stack |
| `authentik-internal`, `media-internal` | Internas da stack (com internet) | A própria stack |

## Repositórios

- **Este repositório (público):** stacks, código dos apps próprios e documentação de padrão, sem valores reais.
- **Repositório privado (planejado):** complemento com domínios, IPs, configuração do Authentik, Proxmox e OMV, e o passo a passo com dados reais.
