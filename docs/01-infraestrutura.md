# Infraestrutura

Visão geral do servidor: as máquinas, os discos, as stacks e o que depende do quê. Sem valores reais (domínio, IPs): eles ficam só nos `.env` do servidor.

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
    └── GPU ───────── passthrough: Jellyfin, Ollama (Legendarr, Berganews, PriceBuddy), Transcriptor, optimizer, Immich (ML)
```

| Disco | Dono | Papel |
|---|---|---|
| SSD | Proxmox | Sistema do host e das VMs |
| HD 1 TB | VM Docker (inteiro) | `APPDATA_PATH` e `CACHE_PATH`: tudo que precisa de disco local |
| HD 4 TB | VM OMV (inteiro) | NAS: `MEDIA_PATH`, `USERDATA_PATH` e compartilhamentos da rede |

Detalhes de pastas, montagem e backup: [02-armazenamento.md](02-armazenamento.md). O backup é feito pelo
[Bergakup](../00-infrastructure/bergakup/README.md).

## Caminho do tráfego

```
Internet ─▶ proxy externo (PROXY protocol) ─▶ Traefik :443 ─▶ CrowdSec (bouncer) ─▶ app
Rede local ─────────────────────────────────▶ Traefik :443 ─▶ app
```

- O **Traefik** termina o TLS com um certificado curinga `*.${DOMAIN}` (Let's Encrypt, desafio DNS no deSEC) e roteia pelos labels dos containers.
- O **CrowdSec** lê o `access.log` do Traefik e bloqueia IPs pelo plugin bouncer.
- O **Authentik** é o provedor de identidade: login OIDC dentro dos apps que sabem falar com ele, e forward-auth no Traefik para os que não sabem (os *arr, o painel do Traefik, o Legendarr). Regras em [05-acesso.md](05-acesso.md).
- O "proxy externo" é uma VPS com filtro por país e um túnel WireGuard até o servidor: [08-trafego-externo.md](08-trafego-externo.md).

## Stacks

| Camada | Stack | O que roda | Endereços (`*.${DOMAIN}`) | Raízes |
|---|---|---|---|---|
| 00 | cloudbeaver | CloudBeaver | `db` | appdata |
| 00 | bergakup | Backup (restic + Backblaze B2): interface e API, Postgres. Quem executa é o `bergakup-agent`, no host (systemd). **Ainda não instalado no servidor** | `bergakup` (só rede local/VPN) | appdata |
| 01 | traefik | Traefik + plugin CrowdSec | `traefik` (painel) | appdata |
| 02 | authentik | Authentik (server, worker), Postgres, Redis | `authentik`, `auth` | appdata |
| 02 | bitwarden | Vaultwarden | `bitwarden` | appdata |
| 02 | crowdsec | CrowdSec | – | appdata |
| 03 | berganews | Notícias (RSS) com IA local: API, coleta, IA (Ollama), proxy de saída, Postgres (pgvector), Redis. Submódulo ([Agelinena/berganews](https://github.com/Agelinena/berganews)) + `03-apps/submodulos/berganews.bergatrix.yml` | `news` | appdata, cache |
| 03 | bergastream | Streaming de música próprio: API, worker, web, Postgres, Redis, Deemix, Lidarr, PO Token. Submódulo ([Agelinena/bergastream](https://github.com/Agelinena/bergastream)) + `03-apps/submodulos/bergastream.bergatrix.yml` | `bergastream`, `lidarr` | appdata, cache, media |
| 03 | doberga | Utilidades do dia a dia (compras, recorrentes, calendário, notas), offline nos apps: API, web, Postgres, Redis. **Ainda não instalado no servidor**. Submódulo ([Agelinena/doberga](https://github.com/Agelinena/doberga)) + `03-apps/submodulos/doberga.bergatrix.yml` | `doberga` | appdata |
| 03 | drop | Texto e arquivos (até 25 MiB) cifrados no navegador, sem disco; rede isolada `bergatrix-drop`. Submódulo ([Agelinena/drop](https://github.com/Agelinena/drop)) + `03-apps/submodulos/drop.bergatrix.yml` | `drop` | – |
| 03 | tarantec | Portfólio (site estático, nginx sem root); imagem pronta do GHCR, atualizada sozinha pelo [auto-deploy](../00-infrastructure/auto-deploy/README.md); rede isolada `bergatrix-tarantec`. Submódulo ([Agelinena/tarantec](https://github.com/Agelinena/tarantec)) + `03-apps/submodulos/tarantec.bergatrix.yml` | `tarantec` | – |
| 03 | homeassistant | Home Assistant | `ha` | appdata |
| 03 | immich | Fotos e vídeos: server, machine learning (GPU), Postgres (VectorChord), Valkey | `fotos` | appdata, cache, userdata |
| 03 | jellyfin | Jellyfin, Seerr, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, FlareSolverr, indexador BR, Recyclarr | `jellyflix`, `catalogo` e um por serviço *arr | appdata, cache, media |
| 03 | legendarr | Legendas (Bazarr + tradução local pelo Ollama), verificação de áudio, optimizer (HEVC). Submódulo ([Agelinena/legendarr](https://github.com/Agelinena/legendarr)) + `03-apps/submodulos/legendarr.bergatrix.yml` | `legendarr` | appdata, cache, media |
| 03 | nextcloud | Arquivos, agenda e contatos: Nextcloud (Apache), cron, Postgres, Redis | `storange` | appdata, userdata |
| 03 | pricebuddy | PriceBuddy: preço de produtos com avisos de queda (app, scraper com Chrome, SearXNG, buscador automático nas outras lojas com IA local, ponte para o Ollama, proxy de saída, relay de e-mail, Postgres); rede isolada `bergatrix-pricebuddy` | `baratinho` | appdata |
| 03 | ollama | Ollama (GPU), sem rota | – | cache |
| 03 | transcriptor | Transcrição com faster-whisper (GPU): API, worker, Postgres, proxy de saída. Submódulo ([Agelinena/transcriptor](https://github.com/Agelinena/transcriptor)) + `03-apps/submodulos/transcriptor.bergatrix.yml` | `transcriptor` | appdata, cache |
| 04 | monitor | Grafana (painéis e alertas por e-mail), Prometheus, Loki, Alloy e exporters (servidor, containers, GPU, Proxmox, OPNsense, sites) | `grafana` (+ portas 5140 e 5141/tcp para o syslog do OPNsense e da VPS) | appdata, cache |

### Ordem de subida

A ordem fica em [`00-infrastructure/stacks.txt`](../00-infrastructure/stacks.txt), e os scripts `subir-tudo.sh` e `derrubar-tudo.sh` a seguem. Veja [07-ligar-e-desligar.md](07-ligar-e-desligar.md).

## Dependências entre stacks

Elas se falam pelo nome do container, numa rede compartilhada ([06-redes.md](06-redes.md)). Mudar um destes nomes, ou tirar o serviço da rede, quebra a stack que depende dele.

| Quem usa | Usa o quê | Endereço | Rede |
|---|---|---|---|
| Traefik (forward-auth) | Authentik | `authentik-server:9000` | `bergatrix-proxy` |
| Bergastream, Berganews, Doberga, Transcriptor, Bergakup e Grafana (OIDC) | Authentik | `authentik-server:9000` | `bergatrix-auth` |
| Jellyfin (plugin Bergafin Auth) | Authentik (OIDC) | `https://auth.${DOMAIN}`, pelo Traefik | `bergatrix-proxy` |
| Traefik (bouncer) | CrowdSec | `crowdsec:8080` | `bergatrix-proxy` |
| CrowdSec | Log do Traefik | `${APPDATA_PATH}/traefik/logs` | (arquivo) |
| Legendarr worker, Berganews (`ai`) | Ollama | `ollama:11434` | `bergatrix-ai` |
| PriceBuddy (buscador, pela ponte `ia`) | Ollama | `ia:11434` → `ollama:11434` | `pricebuddy-internal` → `bergatrix-ai` |
| Lidarr (bergastream) | SABnzbd e Prowlarr (stack jellyfin) | `sabnzbd:8080`, `prowlarr:9696` | `bergatrix-media` |
| Lidarr (bergastream) | Downloads do SABnzbd | `${MEDIA_PATH}/downloads` | (mesma pasta) |
| Lidarr (bergastream) | qBittorrent (stack jellyfin) | `qbittorrent:8080` | `bergatrix-media` |
| Prometheus (monitor) | Métricas do Traefik e do CrowdSec | `traefik:8082`, `crowdsec:6060` | `bergatrix-monitor` |
| Alloy (monitor) | Log do Traefik | `${APPDATA_PATH}/traefik/logs` | (arquivo) |

## Redes Docker

Redes compartilhadas, redes de cada stack e as regras: [06-redes.md](06-redes.md).

## Repositórios

| Repositório | O quê | Visibilidade |
|---|---|---|
| `Agelinena/bergatrix` (este) | Stacks de terceiros, os ajustes deste servidor (`03-apps/submodulos/`), scripts e documentação. Agrega os outros como submódulo | Público por enquanto; vai ficar privado |
| `Agelinena/bergastream`, `berganews`, `doberga`, `transcriptor`, `drop`, `legendarr` | Um app próprio cada, com compose genérico. Submódulos em `03-apps/<app>` | Públicos |
| `Agelinena/Bergafin-auth`, `Bergafin-web`, `Bergafin-android` | Jellyfin com login pelo Authentik (geram imagem e APK). Submódulos sem checkout em `03-apps/jellyfin/repos/` | Públicos |
| `Agelinena/claude-sync` | App dos PCs: conversas do Claude Code no Nextcloud. Fora do Bergatrix | Público |

Valores reais (domínio, IPs, contas) só no `.env` de cada stack no servidor, nunca no git.
