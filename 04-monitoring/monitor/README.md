# Monitor

Painéis e alertas por e-mail de toda a Bergatrix: o servidor Ubuntu e os containers, o Proxmox e as VMs, o OMV, o OPNsense e a VPS de borda.

| Peça | O que faz |
|---|---|
| **Grafana** (`grafana.${DOMAIN}`) | Painéis e alertas. Login pelo Authentik (OIDC). |
| **Prometheus** | Guarda as métricas (90 dias ou 20 GB). |
| **Loki** + **Alloy** | Guarda os logs (30 dias): containers, journal do Ubuntu, access.log do Traefik e o syslog do OPNsense e da VPS. |
| **Exporters** | node_exporter, cAdvisor (containers), GPU, blackbox (ping e sites), pve-exporter (Proxmox) e opnsense-exporter. |

```
             ┌──────────── bergaserver (esta stack) ─────────────┐
 Proxmox ────┤ :9100 node_exporter + SMART   ◄── Prometheus ──┐  │
   API ──────┤ :8006 (token só leitura)      ◄── pve-exporter │  │
 OMV ────────┤ :9100 node_exporter           ◄────────────────┤  │
 OPNsense ───┤ :9100 os-node_exporter, API   ◄── opnsense-exp.│  │──► Grafana ──► e-mail
   syslog ───┼──────────────────► :5140 Alloy ──► Loki ───────┘  │
 VPS ────────┤ :9100 (túnel) node_exporter + WireGuard/nft/CAKE  │
   HAProxy ──┤ :8405 (túnel)                                     │
   syslog ───┼──────────────────► :5141 Alloy                    │
             └───────────────────────────────────────────────────┘
```

## Painéis

Ficam na pasta **Bergatrix** do Grafana. A *Visão geral* abre como página inicial. Os links no topo de cada painel levam aos outros.

| Painel | O que mostra |
|---|---|
| **Visão geral** | Máquinas, VMs, internet, túnel e sites no ar; alertas ativos; CPU, memória e discos de todas as máquinas; latência; tráfego da WAN e do Traefik |
| **Máquina** | Uma máquina por vez (seletor no topo): CPU, memória, discos, I/O, rede, temperaturas e carga |
| **Proxmox e VMs** | Host, tabela das VMs, CPU, memória, rede e disco por VM, storages, SMART dos discos físicos |
| **Servidor Docker** | Containers (CPU, memória e rede por container e por stack, reinícios), GPU, Traefik (requisições, 5xx, tempo de resposta, quem mais acessa) e CrowdSec |
| **OPNsense** | Gateways (latência e perda), interfaces, tabela de estados, serviços, WireGuard e o log de bloqueios (top origens, portas, últimos bloqueios) |
| **VPS e túnel** | Handshake e tráfego do WireGuard, latência casa ↔ SP, nftables (bloqueio geográfico), CAKE, HAProxy e tentativas de SSH |
| **Logs** | Busca nos logs de tudo, por máquina, origem e container |

## Alertas

Os alertas vão por e-mail para `ALERTAS_EMAIL`. Problemas do mesmo tipo na mesma máquina chegam juntos num e-mail só. Um problema que continua é lembrado a cada 12 h, e outro e-mail avisa quando ele se resolve.

| Grupo | Alertas |
|---|---|
| Máquinas | Coleta parou (máquina ou exporter fora), CPU > 90 % (15 min), memória > 90 %, disco > 85 % e > 95 %, disco vai encher em 24 h, temperatura > 85 °C, serviço do systemd falhou |
| Proxmox | VM com início automático parada, storage > 85 %, SMART reprovado, setores realocados ou pendentes, disco > 55 °C |
| Servidor Docker | Container reiniciando (mais de 2 vezes em 15 min), GPU > 85 °C, mais de 10 % de 5xx num serviço, processo morto por falta de memória (log) |
| Rede | Túnel sem handshake há 5 min, máquina sem responder ao ping, túnel > 100 ms, gateway com problema, perda > 10 %, serviço do OPNsense parado, tabela de estados > 80 % |
| Sites | Site fora pelo caminho público, certificado vencendo em menos de 14 dias |

## Subir

A ordem importa: primeiro as máquinas de fora (que geram os tokens), por último a stack.

### 0. Tirar o Wazuh do servidor

Esta stack substitui o Wazuh. **Antes do `git pull`**, que apaga a pasta dele:

```bash
cd ~/bergatrix/04-monitoring/wazuh && docker compose down -v
# Depois de conferir que não precisa de nada lá:
sudo rm -rf /srv/appdata/wazuh
```

O `vm.max_map_count=262144` que o Wazuh pedia pode sair do `/etc/sysctl.conf`, se estiver lá.

### 1. Authentik

Crie a aplicação conforme [05-acesso.md](../../docs/05-acesso.md#oidc-uma-aplicação-por-app):

| Campo | Valor |
|---|---|
| Nome / slug | Grafana / `grafana` (o slug entra no logout: `/application/o/grafana/end-session/`) |
| Redirect URI (Strict) | `https://grafana.<domínio>/login/generic_oauth` |
| Escopos | `openid`, `profile`, `email` (o `profile` do Authentik já manda o `groups`) |
| Acesso | Grupo `grafana_users`. Quem também estiver em `admins` vira **Admin** no Grafana. Os outros, **Viewer**. |

Copie o client ID e o secret para `GRAFANA_SSO_CLIENT_ID` e `GRAFANA_SSO_CLIENT_SECRET`.

### 2. Proxmox

```bash
scp -r 04-monitoring/monitor/hosts/proxmox root@<proxmox>:/root/bergatrix-monitor
ssh root@<proxmox> 'cd /root/bergatrix-monitor && bash instalar.sh'
```

Instala o node_exporter, o SMART dos discos (a cada 15 min) e cria o usuário `monitor@pve` só leitura, com um token. **O segredo do token aparece uma vez só**: copie o `value` para `PVE_TOKEN_VALUE`.

### 3. OMV

```bash
scp -r 04-monitoring/monitor/hosts/omv root@<omv>:/root/bergatrix-monitor
ssh root@<omv> 'cd /root/bergatrix-monitor && bash instalar.sh'
```

### 4. OPNsense

1. **node_exporter:** *System → Firmware → Plugins*, instale `os-node_exporter`. Em *Services → Node Exporter*, ligue o serviço e escolha a interface **LAN** (porta 9100).
2. **Usuário da API:** em *System → Access → Users*, crie o usuário `monitor`, sem acesso ao shell, com estes privilégios:
   `Diagnostics: Firewall statistics`, `Diagnostics: Netstat`, `Reporting: Traffic`, `Services: Unbound (MVC)`, `Status: DHCP leases`, `Status: DNS Overview`, `Status: OpenVPN`, `Status: Services`, `System: Firmware`, `System: Gateways`, `System: Settings: Cron`, `System: Status`, `VPN: WireGuard`, `Services: DHCP: Kea(v4)`, `Lobby: Dashboard`.
   Ainda no usuário, em *API keys*, crie uma chave. O arquivo baixado tem `key` e `secret`: copie para `OPNSENSE_API_KEY` e `OPNSENSE_API_SECRET`.
3. **DNS:** em *Services → Unbound DNS → Advanced*, ligue **Extended Statistics**.
4. **Logs para o servidor:** em *System → Settings → Logging → Remote*, adicione um destino:
   - Transport: **TCP(4)**, Hostname: IP do bergaserver, Port: **5140**
   - Applications: deixe vazio (todas) ou escolha pelo menos `filter (filterlog)`
   - Levels: todos menos `debug`
   - **RFC5424: marcado**
5. **Log dos bloqueios:** em *Firewall → Settings → Advanced*, ligue **Log packets matched from the default block rules**. Para as regras próprias de bloqueio, marque **Log** em cada uma. Sem isso, o painel de bloqueios fica vazio.

### 5. VPS

```bash
scp -r 04-monitoring/monitor/hosts/vps root@<vps>:/root/bergatrix-monitor
ssh root@<vps> 'cd /root/bergatrix-monitor && SERVIDOR=<ip-do-servidor-pelo-túnel> bash instalar.sh'
```

`SERVIDOR` é o mesmo IP para onde o HAProxy manda o tráfego. Se a interface com CAKE não for a `eth0`, edite `IFACES_CAKE` em `/usr/local/lib/bergatrix/metricas-vps.sh`.

Mais três passos manuais na VPS:

1. **nftables:** libere as portas e o ping do monitor **só pelo túnel**, na chain de entrada, e salve no `/etc/nftables.conf`:
   ```
   iifname "wg0" tcp dport { 9100, 8405 } accept comment "monitor"
   iifname "wg0" icmp type echo-request accept comment "ping do monitor"
   ```
   Para o painel do nftables mostrar nomes, dê um `counter` e um `comment` às regras que interessam. Por exemplo, na regra do bloqueio geográfico: `... counter drop comment "geo-bloqueio"`.
2. **HAProxy:** acrescente o bloco de [`hosts/vps/haproxy-metricas.cfg`](hosts/vps/haproxy-metricas.cfg) ao `haproxy.cfg` e recarregue.
3. **Caminho de volta:** a VPS precisa chegar à porta 5141 do servidor pelo túnel (logs), e o servidor precisa chegar a 9100 e 8405 da VPS. Se o WireGuard termina no OPNsense, libere isso na interface do WireGuard. Teste:
   ```bash
   # na VPS
   nc -vz <ip-do-servidor> 5141
   # no bergaserver
   curl -s http://<ip-da-vps-no-túnel>:9100/metrics | grep -c wireguard_
   ```

### 6. Servidor

```bash
cd ~/bergatrix && git pull

# Rede nova (bergatrix-monitor) e Traefik/CrowdSec entrando nela
cd 01-network/redes && docker compose run --rm redes
cd ../traefik && docker compose up -d
cd ../../02-security/crowdsec && docker compose up -d

# O CrowdSec precisa expor as métricas para fora do container.
# Deve mostrar listen_addr 0.0.0.0, porta 6060:
docker exec crowdsec cscli config show --key Config.Prometheus

# Pastas
sudo mkdir -p /srv/appdata/monitor/grafana /srv/cache/monitor/{prometheus,loki,alloy,gerado}
sudo chown -R 1000:1000 /srv/appdata/monitor /srv/cache/monitor

# Stack
cd ~/bergatrix/04-monitoring/monitor
cp .env.example .env && nano .env
docker compose up -d
docker compose ps
```

Se o `listen_addr` do CrowdSec for `127.0.0.1`, troque para `0.0.0.0` em `/srv/appdata/crowdsec/config/config.yaml` (seção `prometheus`) e reinicie o CrowdSec. A porta não é publicada no host: só a rede `bergatrix-monitor` chega a ela.

### 7. Conferir

1. Abra `https://grafana.<domínio>`. Ele leva ao Authentik e volta para a *Visão geral*.
2. Em *Explore*, com o Prometheus, rode `up == 0`. Cada linha que aparecer é um alvo que o Prometheus não alcança. O `job` e o `instance` dizem qual.
3. Teste o e-mail: *Alerting → Contact points → E-mail → Test*.
4. Em *Explore*, com o Loki, rode `{host="opnsense"}` e `{host="vps"}` para ver se o syslog está chegando.

## Mudar painéis e alertas

As dashboards e os alertas são gerados por [`dashboards/gerar.ts`](dashboards/gerar.ts) (Deno). Mudanças feitas pela tela do Grafana não são salvas.

```bash
cd 04-monitoring/monitor
deno run --allow-write=config dashboards/gerar.ts
git add config/grafana && git commit
```

No servidor, depois do `git pull`, o Grafana relê as dashboards sozinho em até 1 minuto. Os alertas só são relidos com `docker compose restart grafana`.

Para testar um painel novo antes de mexer no gerador, use *Explore* ou *New dashboard* no Grafana (como Admin). O painel vale para teste, mas não fica salvo.

**Sites testados:** a lista fica em [`config/prometheus/sites.yml`](config/prometheus/sites.yml), com `example.com`, que o serviço `config` troca pelo `DOMAIN` a cada subida.

## Particularidades

- **node_exporter do Ubuntu** roda na rede do host, mas escuta só em `172.17.0.1` (o IP do host na `docker0`), onde o Prometheus chega por `host-gateway`. Ele não fica exposto na rede local. Se o `bip` do Docker for diferente, ajuste no compose.
- **Portas 5140 e 5141 (syslog)** ficam abertas na rede local e no túnel. Elas só servem para gravar logs no Loki. Se quiser fechar, restrinja no OPNsense quem chega ao bergaserver nessas portas.
- **IPs fora do Docker** (Proxmox, OMV, OPNsense, VPS) entram pelo `.env` e viram nomes fixos (`proxmox`, `omv`…) pelo `extra_hosts`. Por isso o `prometheus.yml` não tem IP nenhum.
- **Memória do OPNsense** (FreeBSD) é calculada como `1 − (livre + inativa) / total`. É uma aproximação: o FreeBSD não tem o "MemAvailable" do Linux.
- **SMART** é lido no Proxmox, que vê os discos físicos. As VMs não enxergam o SMART.
- **Backup:** só o `grafana.db` (label `bergatrix.backup.sqlite`). Métricas e logs ficam no `CACHE_PATH`: perder isso apaga o histórico, mas não quebra nada.
- **access.log do Traefik** cresce sem rotação. O Alloy lê o arquivo do ponto onde parou. Para rodar o log, use o `logrotate` com `copytruncate`.
