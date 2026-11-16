// Gera as dashboards do Grafana (config/grafana/dashboards/*.json) e os alertas
// (config/grafana/provisioning/alerting/regras.yml).
//
//   cd 04-monitoring/monitor && deno run --allow-write=config dashboards/gerar.ts
//
// Edite aqui, gere de novo e faça o commit dos JSON. O Grafana relê a pasta
// sozinho em até 1 minuto; os alertas só são relidos ao reiniciar o Grafana.

import { stringify } from "jsr:@std/yaml@1.0.5";
import {
  alertas, barras, binario, coluna, CRITICO, dashboard, GRAVE, Grade, juntar, l, li, limites, logs, mapa,
  NO_AR, OK, PARA_BAIXO, q, qi, qt, SAUDE, SERVICO, serie, sobe, sobrescrever, stat, tabela, varFixa,
  varLokiLabel, varProm, varTexto, ATENCAO,
} from "./lib.ts";

// ── Expressões reutilizadas ────────────────────────────────────

// Sistemas de arquivos que importam (sem os virtuais, sem NFS: o NAS aparece
// pelo próprio OMV).
const FS = 'fstype!~"tmpfs|devtmpfs|devfs|fdescfs|procfs|linprocfs|overlay|squashfs|ramfs|nfs.*|fuse.*|autofs|nsfs|efivarfs|vfat",mountpoint!~"/boot.*"';
// Interfaces que importam (sem as virtuais do Docker e do Proxmox)
const NET = 'device!~"lo.*|veth.*|br-.*|docker.*|tap.*|fwbr.*|fwln.*|fwpr.*|enc.*|pflog.*|pfsync.*"';

const cpu = (sel: string) => `100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"${sel}}[$__rate_interval])))`;
// Linux (MemAvailable) ou FreeBSD do OPNsense (livre + inativa)
const mem = (sel: string) =>
  `max by (host) (100 * (1 - node_memory_MemAvailable_bytes{${sel}} / node_memory_MemTotal_bytes{${sel}})` +
  ` or 100 * (1 - (node_memory_free_bytes{${sel}} + node_memory_inactive_bytes{${sel}}) / node_memory_size_bytes{${sel}}))`;
const disco = (sel: string) => `100 * (1 - node_filesystem_avail_bytes{${FS}${sel}} / node_filesystem_size_bytes{${FS}${sel}})`;
// Latência do ping só quando ele respondeu (sem resposta, o blackbox grava 0 s)
const RTT = (alvo: string) =>
  `probe_icmp_duration_seconds{job="ping", phase="rtt", instance="${alvo}"} and on (instance) (probe_success{job="ping", instance="${alvo}"} == 1)`;
const GUEST = '{id=~"(qemu|lxc)/.*"}';
const comNome = (expr: string) => `${expr} * on (id) group_left (name) pve_guest_info`;

// smartmon (prometheus-node-exporter-collectors): versão nova (smartmon.py,
// atributos em smartmon_attr_raw_value) ou antiga (smartmon.sh, um nome por atributo)
const smart = (attr: string) =>
  `max by (disk) (smartmon_attr_raw_value{name="${attr}"}) or max by (disk) (smartmon_${attr}_raw_value)`;

// Vida útil restante dos SSDs, em %: SATA (valor normalizado do atributo de
// desgaste, 100 = novo) ou NVMe (100 − percentage_used).
const VIDA_SSD =
  'max by (disk) (smartmon_attr_value{name=~"wear_leveling_count|media_wearout_indicator|ssd_life_left|percent_lifetime_remain"})' +
  ' or label_replace(100 - 100 * nvme_percentage_used_ratio, "disk", "$1", "device", "(.*)")';

// filterlog do OPNsense, IPv4: protocolo, origem, destino e portas
const FILTERLOG_RE =
  '`^(?:[^,]*,){8}4,(?:[^,]*,){7}(?P<proto>[^,]*),[^,]*,(?P<src>[^,]*),(?P<dst>[^,]*),?(?P<srcport>[^,]*),?(?P<dstport>[^,]*)`';
// Nomes das colunas do painel Acessos
const ROTULOS_ACESSO: Record<string, string> = {
  ClientHost: "IP", pais: "País", cidade: "Cidade", asn_org: "Operadora", RequestHost: "App",
  RequestPath: "Caminho", DownstreamStatus: "Status", ua: "User-Agent",
};
// IPs da rede local e do Docker (não contam nos alertas de volume)
const PRIVADO = 'ClientHost !~ `^(10|127|192\\.168|172\\.(1[6-9]|2[0-9]|3[01]))\\..*`';

// CrowdSec: decisões por ataques vistos aqui x lista preventiva da comunidade
const COMUNIDADE = 'origin=~"(?i)capi|lists"';
const LOCAL = 'origin!~"(?i)capi|lists"';
// Traefik: "immich-service@docker" vira "immich"
const SVC = (expr: string) => `label_replace(${expr}, "service", "$1", "service", "(.+?)(-service)?@.*")`;
const BLOQUEIOS = '{host="opnsense", program="filterlog", action="block"}';

const GATEWAY = mapa({
  "0": ["Fora", CRITICO], "1": ["No ar", OK], "2": ["Desconhecido", GRAVE], "3": ["Aguardando", ATENCAO],
  "4": ["Perda de pacotes", GRAVE], "5": ["Latência alta", ATENCAO], "6": ["Desligado", CRITICO],
});

const dashboards: Record<string, unknown> = {};

// ════════════════════════════════════════════════════════════════
// 00 · Visão geral
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  g.add(9, 4, stat("Máquinas", [qi('up{job="node"}', "{{host}}")], { mappings: NO_AR, thresholds: binario, cor: "background", texto: "value_and_name" }));
  g.add(5, 4, stat("VMs", [qi(comNome(`pve_up${GUEST}`), "{{name}}")], { mappings: NO_AR, thresholds: binario, cor: "background", texto: "value_and_name" }));
  g.add(3, 4, stat("Internet", [qi("opnsense_gateways_status", "{{name}}")], { mappings: GATEWAY, cor: "background", texto: "value_and_name", descricao: "Estado dos gateways do OPNsense" }));
  g.add(3, 4, stat("Túnel SP ↔ casa", [qi('time() - max(wireguard_latest_handshake_seconds{host="vps"})')], {
    unit: "s", thresholds: sobe(150, 180, 300), cor: "background",
    descricao: "Tempo desde o último handshake do WireGuard na VPS. Acima de 3 min o túnel provavelmente caiu.",
  }));
  g.add(4, 4, stat("Sites fora", [qi('count(probe_success{job="sites"} == 0) or vector(0)')], {
    thresholds: limites([null, OK], [1, CRITICO]), cor: "background", descricao: "Sites testados pelo caminho público (VPS → túnel → Traefik)",
  }));

  g.add(8, 9, alertas("Alertas ativos"));
  g.add(8, 9, barras("CPU", [qi(cpu(""), "{{host}}")], { unit: "percent", min: 0, max: 100, thresholds: sobe(70, 85, 95) }));
  g.add(8, 9, barras("Memória", [qi(mem(""), "{{host}}")], { unit: "percent", min: 0, max: 100, thresholds: sobe(80, 90, 95) }));

  g.add(12, 10, barras("Discos mais cheios", [qi(`topk(12, ${disco("")})`, "{{host}} · {{mountpoint}}")], {
    unit: "percent", min: 0, max: 100, thresholds: sobe(75, 85, 95), ordenar: true,
  }));
  g.add(12, 10, tabela("Sites", [
    qt('probe_success{job="sites"}'),
    qt('probe_duration_seconds{job="sites"}'),
    qt('(probe_ssl_earliest_cert_expiry{job="sites"} - time()) / 86400'),
  ], {
    transformacoes: juntar({ instance: "Site", "Value #A": "Estado", "Value #B": "Resposta", "Value #C": "Certificado (dias)" }, ["host"]),
    colunas: [
      coluna("Estado", { mappings: NO_AR, "custom.cellOptions": { type: "color-text" } }),
      coluna("Resposta", { unit: "s", decimals: 2 }),
      coluna("Certificado (dias)", { decimals: 0, thresholds: limites([null, CRITICO], [7, GRAVE], [14, OK]), color: { mode: "thresholds" }, "custom.cellOptions": { type: "color-text" } }),
    ],
    ordenarPor: "Estado", desc: false,
  }));

  g.add(12, 8, serie("CPU por máquina", [q(cpu(""), "{{host}}")], { unit: "percent", min: 0, max: 100 }));
  g.add(12, 8, serie("Internet (WAN do OPNsense)", [
    q('sum(rate(opnsense_interfaces_received_bytes_total{interface=~"(?i)wan.*"}[$__rate_interval])) * 8', "Download"),
    q('sum(rate(opnsense_interfaces_transmitted_bytes_total{interface=~"(?i)wan.*"}[$__rate_interval])) * 8', "Upload"),
  ], { unit: "bps", overrides: [PARA_BAIXO("Upload")], descricao: "Upload para baixo do zero" }));
  g.add(12, 8, serie("Latência (ping)", [
    q(RTT("vps"), "Casa → VPS (túnel)"),
    q(RTT("1.1.1.1"), "Casa → internet (1.1.1.1)"),
  ], { unit: "s" }));
  g.add(12, 8, serie("Requisições no Traefik", [
    q('sum by (code) (rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[$__rate_interval]))', "{{code}}"),
  ], { unit: "reqps", empilhar: true }));
  g.add(24, 8, serie("Velocidade da internet (teste a cada hora)", [
    q("speedtest_download_bits_per_second", "Download"),
    q("speedtest_upload_bits_per_second", "Upload"),
  ], { unit: "bps", preencher: 0, descricao: "Teste da Ookla rodado pelo bergaserver, passando pelo OPNsense" }));

  dashboards["00-visao-geral"] = dashboard("bergatrix-geral", "Visão geral", g, {
    descricao: "Estado de tudo: máquinas, VMs, internet, túnel, sites e alertas",
  });
}

// ════════════════════════════════════════════════════════════════
// 01 · Máquina (uma por vez: servidor, Proxmox, OMV, OPNsense, VPS)
// ════════════════════════════════════════════════════════════════
{
  const h = 'host="$host"';
  const g = new Grade();
  g.add(4, 4, stat("No ar há", [qi(`time() - node_boot_time_seconds{${h}}`)], { unit: "s", decimals: 0 }));
  g.add(4, 4, stat("CPU", [q(cpu("," + h))], { unit: "percent", thresholds: sobe(70, 85, 95), grafico: true }));
  g.add(4, 4, stat("Memória", [q(mem(h))], { unit: "percent", thresholds: sobe(80, 90, 95), grafico: true }));
  g.add(4, 4, stat("Disco mais cheio", [qi(`max(${disco("," + h)})`)], { unit: "percent", thresholds: sobe(75, 85, 95) }));
  g.add(4, 4, stat("Carga (1 min)", [q(`node_load1{${h}}`)], { decimals: 2, grafico: true, descricao: "Comparar com o número de núcleos" }));
  g.add(4, 4, stat("Núcleos", [qi(`count(count by (cpu) (node_cpu_seconds_total{${h}}))`)]));

  g.add(12, 8, serie("CPU por modo", [q(`100 * avg by (mode) (rate(node_cpu_seconds_total{${h}, mode!="idle"}[$__rate_interval]))`, "{{mode}}")], {
    unit: "percent", empilhar: true, min: 0,
  }));
  g.add(12, 8, serie("Memória", [
    q(`(node_memory_MemTotal_bytes{${h}} - node_memory_MemAvailable_bytes{${h}}) or (node_memory_size_bytes{${h}} - node_memory_free_bytes{${h}} - node_memory_inactive_bytes{${h}})`, "Em uso"),
    q(`node_memory_MemTotal_bytes{${h}} or node_memory_size_bytes{${h}}`, "Total"),
    q(`(node_memory_SwapTotal_bytes{${h}} - node_memory_SwapFree_bytes{${h}})`, "Swap em uso"),
  ], { unit: "bytes", overrides: [sobrescrever("Total", { "custom.fillOpacity": 0, "custom.lineStyle": { fill: "dash", dash: [10, 10] } })] }));

  g.add(12, 9, barras("Discos (uso)", [qi(disco("," + h), "{{mountpoint}}")], { unit: "percent", min: 0, max: 100, thresholds: sobe(75, 85, 95) }));
  g.add(12, 9, serie("Leitura e escrita em disco", [
    q(`sum by (device) (rate(node_disk_read_bytes_total{${h}}[$__rate_interval]))`, "{{device}} leitura"),
    q(`sum by (device) (rate(node_disk_written_bytes_total{${h}}[$__rate_interval]))`, "{{device}} escrita"),
  ], { unit: "Bps", overrides: [PARA_BAIXO(".*escrita")], descricao: "Escrita para baixo do zero" }));

  g.add(12, 8, serie("Rede", [
    q(`rate(node_network_receive_bytes_total{${h}, ${NET}}[$__rate_interval]) * 8`, "{{device}} recebe"),
    q(`rate(node_network_transmit_bytes_total{${h}, ${NET}}[$__rate_interval]) * 8`, "{{device}} envia"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia")], descricao: "Envio para baixo do zero" }));
  g.add(12, 8, serie("Temperaturas", [q(`node_hwmon_temp_celsius{${h}}`, "{{chip}} {{sensor}}")], {
    unit: "celsius", thresholds: limites([null, OK], [80, CRITICO]), linhaLimite: true, legenda: "table",
    descricao: "Sensores do hardware. VMs normalmente não têm.",
  }));
  g.add(12, 7, serie("Carga", [
    q(`node_load1{${h}}`, "1 min"), q(`node_load5{${h}}`, "5 min"), q(`node_load15{${h}}`, "15 min"),
  ], { decimals: 2 }));
  g.add(12, 7, serie("Erros e descartes de rede", [
    q(`rate(node_network_receive_errs_total{${h}, ${NET}}[$__rate_interval]) + rate(node_network_transmit_errs_total{${h}, ${NET}}[$__rate_interval])`, "{{device}} erros"),
    q(`rate(node_network_receive_drop_total{${h}, ${NET}}[$__rate_interval]) + rate(node_network_transmit_drop_total{${h}, ${NET}}[$__rate_interval])`, "{{device}} descartes"),
  ], { unit: "pps" }));

  // Interfaces físicas: as virtuais não informam velocidade
  const fisica = `node_network_speed_bytes{${h}, ${NET}} > 0`;
  g.add(12, 8, tabela("Links de rede", [
    qt(`(${fisica}) * 8`),
    qt(`node_network_up{${h}, ${NET}} and on (device) (${fisica})`),
    qt(`node_network_mtu_bytes{${h}, ${NET}} and on (device) (${fisica})`),
  ], {
    transformacoes: juntar({ device: "Interface", "Value #A": "Velocidade", "Value #B": "Estado", "Value #C": "MTU" }, ["host", "papel"]),
    colunas: [
      coluna("Velocidade", { unit: "bps" }),
      coluna("Estado", { mappings: mapa({ "0": ["Desconectado", CRITICO], "1": ["Conectado", OK] }), "custom.cellOptions": { type: "color-text" } }),
    ],
    descricao: "Velocidade negociada com o switch ou o roteador. Um link de 1 Gb/s em 100 Mb/s costuma ser cabo ou porta ruim. VMs mostram a velocidade da placa virtual.",
  }));
  g.add(12, 8, serie("Velocidade dos links (histórico)", [q(`(${fisica}) * 8`, "{{device}}")], {
    unit: "bps", preencher: 0, descricao: "Degraus aqui são renegociações do link",
  }));

  dashboards["01-maquina"] = dashboard("bergatrix-maquina", "Máquina", g, {
    descricao: "CPU, memória, discos, rede e temperatura de uma máquina",
    variaveis: [varProm("host", "Máquina", 'label_values(node_uname_info, host)', { padrao: "bergaserver" })],
  });
}

// ════════════════════════════════════════════════════════════════
// 02 · Proxmox e VMs
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  const NODE = '{id=~"node/.*"}';
  g.add(4, 4, stat("Proxmox", [qi(`pve_up${NODE}`)], { mappings: NO_AR, thresholds: binario, cor: "background" }));
  g.add(4, 4, stat("VMs ligadas", [qi(`count(pve_up${GUEST} == 1) or vector(0)`)]));
  g.add(4, 4, stat("CPU do host", [q(`pve_cpu_usage_ratio${NODE} * 100`)], { unit: "percent", thresholds: sobe(70, 85, 95), grafico: true }));
  g.add(4, 4, stat("Memória do host", [q(`100 * pve_memory_usage_bytes${NODE} / pve_memory_size_bytes${NODE}`)], { unit: "percent", thresholds: sobe(80, 90, 95), grafico: true }));
  g.add(4, 4, stat("No ar há", [qi(`pve_uptime_seconds${NODE}`)], { unit: "s", decimals: 0 }));
  g.add(4, 4, stat("Discos (SMART)", [qi('min(smartmon_device_smart_healthy{host="proxmox"})')], {
    mappings: SAUDE, thresholds: binario, cor: "background", noValue: "sem dados",
    descricao: "Saúde SMART dos discos físicos, lida no Proxmox (prometheus-node-exporter-collectors)",
  }));

  g.add(24, 7, tabela("VMs e containers", [
    qt(comNome(`pve_up${GUEST}`)),
    qt(comNome(`pve_cpu_usage_ratio${GUEST} * 100`)),
    qt(comNome(`pve_memory_usage_bytes${GUEST}`)),
    qt(comNome(`pve_memory_size_bytes${GUEST}`)),
    qt(comNome(`pve_disk_size_bytes${GUEST}`)),
    qt(comNome(`pve_uptime_seconds${GUEST}`)),
  ], {
    transformacoes: juntar(
      { id: "ID", name: "Nome", "Value #A": "Estado", "Value #B": "CPU", "Value #C": "Memória em uso", "Value #D": "Memória", "Value #E": "Disco", "Value #F": "No ar há" },
      ["host"],
    ),
    colunas: [
      coluna("Estado", { mappings: [{ type: "value", options: { "0": { text: "Parada", color: CRITICO }, "1": { text: "Ligada", color: OK } } }], "custom.cellOptions": { type: "color-text" } }),
      coluna("CPU", { unit: "percent", decimals: 1, "custom.cellOptions": { type: "gauge", mode: "basic" }, max: 100, min: 0, thresholds: sobe(70, 85, 95), color: { mode: "thresholds" } }),
      coluna("Memória em uso", { unit: "bytes" }),
      coluna("Memória", { unit: "bytes" }),
      coluna("Disco", { unit: "bytes" }),
      coluna("No ar há", { unit: "s", decimals: 0 }),
    ],
    ordenarPor: "Nome", desc: false,
  }));

  g.add(12, 8, serie("CPU por VM", [q(comNome(`pve_cpu_usage_ratio${GUEST} * 100`), "{{name}}")], { unit: "percent", min: 0 }));
  g.add(12, 8, serie("Memória por VM", [q(comNome(`pve_memory_usage_bytes${GUEST}`), "{{name}}")], { unit: "bytes" }));
  g.add(12, 8, serie("Rede por VM", [
    q(comNome(`rate(pve_network_receive_bytes_total${GUEST}[$__rate_interval]) * 8`), "{{name}} recebe"),
    q(comNome(`rate(pve_network_transmit_bytes_total${GUEST}[$__rate_interval]) * 8`), "{{name}} envia"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia")] }));
  g.add(12, 8, serie("Disco por VM", [
    q(comNome(`rate(pve_disk_read_bytes_total${GUEST}[$__rate_interval])`), "{{name}} leitura"),
    q(comNome(`rate(pve_disk_written_bytes_total${GUEST}[$__rate_interval])`), "{{name}} escrita"),
  ], { unit: "Bps", overrides: [PARA_BAIXO(".*escrita")] }));

  g.add(24, 6, barras("Storages do Proxmox", [qi('100 * pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"}', "{{id}}")], {
    unit: "percent", min: 0, max: 100, thresholds: sobe(75, 85, 95),
  }));
  g.add(24, 8, tabela("Discos físicos (SMART)", [
    qt("max by (disk) (smartmon_device_smart_healthy)"),
    qt(smart("temperature_celsius")),
    qt(smart("power_on_hours")),
    qt(smart("reallocated_sector_ct")),
    qt(smart("current_pending_sector")),
    qt(VIDA_SSD),
  ], {
    transformacoes: juntar({ disk: "Disco", "Value #A": "Saúde", "Value #B": "Temperatura", "Value #C": "Horas ligado", "Value #D": "Setores realocados", "Value #E": "Setores pendentes", "Value #F": "Vida útil (SSD)" }),
    colunas: [
      coluna("Saúde", { mappings: SAUDE, "custom.cellOptions": { type: "color-text" } }),
      coluna("Temperatura", { unit: "celsius", thresholds: limites([null, OK], [45, ATENCAO], [55, CRITICO]), color: { mode: "thresholds" }, "custom.cellOptions": { type: "color-text" } }),
      coluna("Setores realocados", { thresholds: limites([null, OK], [1, GRAVE]), color: { mode: "thresholds" }, "custom.cellOptions": { type: "color-text" } }),
      coluna("Setores pendentes", { thresholds: limites([null, OK], [1, CRITICO]), color: { mode: "thresholds" }, "custom.cellOptions": { type: "color-text" } }),
      coluna("Vida útil (SSD)", { unit: "percent", decimals: 0, thresholds: limites([null, CRITICO], [10, GRAVE], [20, OK]), color: { mode: "thresholds" }, "custom.cellOptions": { type: "color-text" } }),
    ],
    descricao: "Qualquer setor realocado ou pendente é sinal de disco começando a falhar. Vida útil só para SSD e NVMe (100% = novo). O SMART roda a cada 15 min; os autotestes (curto toda madrugada, longo todo dia 1º) são do smartd.",
  }));
  g.add(24, 8, serie("Temperaturas do Proxmox", [
    q('node_hwmon_temp_celsius{host="proxmox"}', "{{chip}} {{sensor}}"),
    q(smart("temperature_celsius"), "disco {{disk}}"),
  ], { unit: "celsius", legenda: "table", thresholds: limites([null, OK], [80, CRITICO]), linhaLimite: true }));

  dashboards["02-proxmox"] = dashboard("bergatrix-proxmox", "Proxmox e VMs", g, {
    descricao: "Host Proxmox, cada VM, storages e saúde dos discos físicos",
  });
}

// ════════════════════════════════════════════════════════════════
// 03 · Servidor Docker (bergaserver): containers, GPU, Traefik, CrowdSec
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  const C = 'name!=""';
  g.add(4, 4, stat("Containers", [qi("count(count by (name) (container_start_time_seconds))")]));
  g.add(4, 4, stat("Reinícios (1 h)", [qi("sum(changes(container_start_time_seconds[1h])) or vector(0)")], {
    thresholds: limites([null, OK], [1, ATENCAO], [5, CRITICO]), descricao: "Containers que começaram de novo na última hora",
  }));
  g.add(4, 4, stat("Requisições", [q('sum(rate(traefik_entrypoint_requests_total{entrypoint="websecure"}[$__rate_interval]))')], { unit: "reqps", grafico: true }));
  g.add(4, 4, stat("Bans do CrowdSec", [qi(`sum(cs_active_decisions{${LOCAL}}) or vector(0)`)], {
    descricao: "IPs banidos por ataques vistos aqui (fora a lista preventiva da comunidade)",
  }));
  g.add(4, 4, stat("GPU", [q("nvidia_smi_utilization_gpu_ratio * 100")], { unit: "percent", grafico: true, thresholds: sobe(80, 90, 98) }));
  g.add(4, 4, stat("Temperatura da GPU", [q("nvidia_smi_temperature_gpu")], { unit: "celsius", thresholds: sobe(70, 80, 87), grafico: true }));

  g.add(12, 9, serie("CPU por container (100% = 1 núcleo)", [
    q(`topk(10, sum by (name) (rate(container_cpu_usage_seconds_total{${C}}[$__rate_interval]))) * 100`, "{{name}}"),
  ], { unit: "percent", min: 0, legenda: "table" }));
  g.add(12, 9, serie("Memória por container", [
    q(`topk(10, sum by (name) (container_memory_working_set_bytes{${C}}))`, "{{name}}"),
  ], { unit: "bytes", legenda: "table" }));

  g.add(12, 10, tabela("Por stack", [
    qt("sum by (container_label_com_docker_compose_project) (rate(container_cpu_usage_seconds_total[5m])) * 100"),
    qt("sum by (container_label_com_docker_compose_project) (container_memory_working_set_bytes)"),
    qt("sum by (container_label_com_docker_compose_project) (rate(container_network_receive_bytes_total[5m]) + rate(container_network_transmit_bytes_total[5m])) * 8"),
    qt("count by (container_label_com_docker_compose_project) (count by (container_label_com_docker_compose_project, name) (container_start_time_seconds))"),
  ], {
    transformacoes: juntar({ container_label_com_docker_compose_project: "Stack", "Value #A": "CPU", "Value #B": "Memória", "Value #C": "Rede", "Value #D": "Containers" }),
    colunas: [
      coluna("CPU", { unit: "percent", decimals: 1 }),
      coluna("Memória", { unit: "bytes" }),
      coluna("Rede", { unit: "bps" }),
    ],
    ordenarPor: "Memória",
  }));
  g.add(12, 10, serie("Rede por container", [
    q(`topk(8, sum by (name) (rate(container_network_receive_bytes_total{${C}}[$__rate_interval]))) * 8`, "{{name}} recebe"),
    q(`topk(8, sum by (name) (rate(container_network_transmit_bytes_total{${C}}[$__rate_interval]))) * 8`, "{{name}} envia"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia")] }));

  g.secao("GPU (GTX 1060)");
  g.add(8, 8, serie("Uso da GPU", [
    q("nvidia_smi_utilization_gpu_ratio * 100", "Processamento"),
    q("nvidia_smi_utilization_memory_ratio * 100", "Memória (banda)"),
  ], { unit: "percent", min: 0, max: 100 }));
  g.add(8, 8, serie("Memória da GPU", [
    q("nvidia_smi_memory_used_bytes", "Em uso"), q("nvidia_smi_memory_total_bytes", "Total"),
  ], { unit: "bytes", overrides: [sobrescrever("Total", { "custom.fillOpacity": 0 })] }));
  g.add(8, 8, serie("Temperatura da GPU", [q("nvidia_smi_temperature_gpu", "Temperatura")], {
    unit: "celsius", thresholds: limites([null, OK], [85, CRITICO]), linhaLimite: true,
  }));

  g.secao("Traefik (entrada de tráfego)");
  g.add(12, 8, serie("Requisições por serviço", [
    q(SVC("sum by (service) (rate(traefik_service_requests_total[$__rate_interval]))"), "{{service}}"),
  ], { unit: "reqps", legenda: "table" }));
  g.add(12, 8, serie("Erros 5xx por serviço (%)", [
    q(SVC("100 * sum by (service) (rate(traefik_service_requests_total{code=~\"5..\"}[5m])) / sum by (service) (rate(traefik_service_requests_total[5m]))"), "{{service}}"),
  ], { unit: "percent", min: 0, thresholds: limites([null, OK], [10, CRITICO]), linhaLimite: true }));
  g.add(12, 8, serie("Tempo de resposta (p95)", [
    q(SVC("histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))"), "{{service}}"),
  ], { unit: "s", legenda: "table" }));
  g.add(12, 8, tabela("Quem mais acessa (período)", [
    li('topk(15, sum by (ClientHost) (count_over_time({job="traefik"} | json ClientHost="ClientHost" [$__range])))', "{{ClientHost}}"),
  ], {
    transformacoes: [
      { id: "reduce", options: { reducers: ["lastNotNull"], mode: "seriesToRows" } },
      { id: "organize", options: { renameByName: { Field: "IP", "Last *": "Requisições" } } },
    ],
    ordenarPor: "Requisições",
    descricao: "IPs reais (via Proxy Protocol da VPS), do access.log do Traefik",
  }));

  g.secao("CrowdSec");
  g.add(12, 4, stat("Bans por ataques vistos aqui", [qi(`sum(cs_active_decisions{${LOCAL}}) or vector(0)`)], {
    descricao: "Detectados pelo CrowdSec nos logs do Traefik, ou dados à mão (cscli)",
  }));
  g.add(12, 4, stat("Lista preventiva da comunidade", [qi(`sum(cs_active_decisions{${COMUNIDADE}}) or vector(0)`)], {
    descricao: "IPs que outros usuários do CrowdSec denunciaram. São bloqueados antes de chegar aqui; a maioria nunca tentou nada contra você.",
  }));
  g.add(12, 8, serie("Bans locais por motivo", [q(`sum by (reason) (cs_active_decisions{${LOCAL}})`, "{{reason}}")], { legenda: "table", barras: false }));
  g.add(12, 8, serie("Respostas 4xx e 5xx por rota", [
    l('sum by (RouterName) (count_over_time({job="traefik"} | json RouterName="RouterName", DownstreamStatus="DownstreamStatus" | DownstreamStatus >= 400 [$__auto]))', "{{RouterName}}"),
  ], { barras: true, empilhar: true, preencher: 80 }));

  dashboards["03-docker"] = dashboard("bergatrix-docker", "Servidor Docker", g, {
    descricao: "Containers do bergaserver, GPU, Traefik e CrowdSec",
  });
}

// ════════════════════════════════════════════════════════════════
// 04 · OPNsense
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  const h = 'host="opnsense"';
  g.add(3, 4, stat("Firewall", [qi("opnsense_up")], { mappings: NO_AR, thresholds: binario, cor: "background" }));
  g.add(6, 4, stat("Gateways", [qi("opnsense_gateways_status", "{{name}}")], { mappings: GATEWAY, cor: "background", texto: "value_and_name" }));
  g.add(3, 4, stat("CPU", [q(cpu("," + h))], { unit: "percent", thresholds: sobe(70, 85, 95), grafico: true }));
  g.add(3, 4, stat("Memória", [q(mem(h))], { unit: "percent", thresholds: sobe(80, 90, 95), grafico: true }));
  g.add(3, 4, stat("Tabela de estados", [q("100 * opnsense_pf_states_current / opnsense_pf_states_limit")], { unit: "percent", thresholds: sobe(60, 80, 90), grafico: true }));
  g.add(3, 4, stat("Serviços parados", [qi("opnsense_services_stopped_total")], { thresholds: limites([null, OK], [1, CRITICO]) }));
  g.add(3, 4, stat("Temperatura", [q("max(opnsense_temperature_celsius)")], { unit: "celsius", thresholds: sobe(70, 80, 90), grafico: true, noValue: "sem sensor" }));

  g.add(12, 8, serie("Latência dos gateways", [q("opnsense_gateways_rtt_milliseconds", "{{name}}")], { unit: "ms" }));
  g.add(12, 8, serie("Perda de pacotes dos gateways", [q("opnsense_gateways_loss_percentage", "{{name}}")], {
    unit: "percent", min: 0, thresholds: limites([null, OK], [10, CRITICO]), linhaLimite: true,
  }));
  g.add(12, 9, serie("Tráfego por interface", [
    q("rate(opnsense_interfaces_received_bytes_total[$__rate_interval]) * 8", "{{interface}} recebe"),
    q("rate(opnsense_interfaces_transmitted_bytes_total[$__rate_interval]) * 8", "{{interface}} envia"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia")], legenda: "table" }));
  g.add(12, 9, serie("Pacotes bloqueados pelo pf", [
    q("sum by (interface) (rate(opnsense_firewall_in_ipv4_block_packets[5m]) + rate(opnsense_firewall_in_ipv6_block_packets[5m]))", "{{interface}}"),
  ], { unit: "pps", legenda: "table" }));
  g.add(8, 8, serie("Conexões TCP por estado", [q("opnsense_protocol_tcp_connection_count_by_state", "{{state}}")], {}));
  g.add(8, 8, tabela("Serviços", [qt("opnsense_services_status")], {
    transformacoes: juntar({ description: "Serviço", "Value": "Estado" }, ["name", "opnsense_instance", "host"]),
    colunas: [coluna("Estado", { mappings: SERVICO, "custom.cellOptions": { type: "color-text" } })],
    ordenarPor: "Estado", desc: false,
  }));
  g.add(8, 8, tabela("WireGuard no OPNsense", [
    qt("opnsense_wireguard_peer_status"),
    qt("time() - opnsense_wireguard_peer_last_handshake_seconds"),
  ], {
    transformacoes: juntar({ device_name: "Túnel", peer_name: "Peer", "Value #A": "Estado", "Value #B": "Último handshake" }, ["device", "device_type", "opnsense_instance", "host"]),
    colunas: [
      coluna("Estado", { mappings: mapa({ "0": ["Fora", CRITICO], "1": ["No ar", OK], "2": ["?", GRAVE] }), "custom.cellOptions": { type: "color-text" } }),
      coluna("Último handshake", { unit: "s", decimals: 0 }),
    ],
    descricao: "Só aparece se o OPNsense tiver túneis WireGuard",
  }));

  g.secao("Internet (teste de velocidade a cada hora)");
  g.add(6, 4, stat("Download", [qi("speedtest_download_bits_per_second")], { unit: "bps", decimals: 0 }));
  g.add(6, 4, stat("Upload", [qi("speedtest_upload_bits_per_second")], { unit: "bps", decimals: 0 }));
  g.add(6, 4, stat("Ping do teste", [qi("speedtest_ping_latency_milliseconds")], { unit: "ms", thresholds: sobe(30, 60, 100) }));
  g.add(6, 4, stat("Jitter", [qi("speedtest_jitter_latency_milliseconds")], { unit: "ms", thresholds: sobe(10, 30, 60) }));
  g.add(12, 8, serie("Download e upload", [
    q("speedtest_download_bits_per_second", "Download"),
    q("speedtest_upload_bits_per_second", "Upload"),
  ], { unit: "bps", preencher: 0 }));
  g.add(12, 8, serie("Ping e jitter do teste", [
    q("speedtest_ping_latency_milliseconds", "Ping"),
    q("speedtest_jitter_latency_milliseconds", "Jitter"),
  ], { unit: "ms", preencher: 0 }));

  g.secao("Log do firewall (bloqueios)");
  g.add(24, 8, serie("Bloqueios por interface", [
    l(`sum by (interface) (count_over_time(${BLOQUEIOS} [$__auto]))`, "{{interface}}"),
  ], { barras: true, empilhar: true, preencher: 80, descricao: "Só regras com log ligado entram aqui (bloqueio padrão: Firewall → Settings → Advanced)" }));
  g.add(8, 10, tabela("Quem mais foi bloqueado (origem)", [
    li(`topk(15, sum by (src) (count_over_time(${BLOQUEIOS} | regexp ${FILTERLOG_RE} [$__range])))`, "{{src}}"),
  ], {
    transformacoes: [
      { id: "reduce", options: { reducers: ["lastNotNull"], mode: "seriesToRows" } },
      { id: "organize", options: { renameByName: { Field: "Origem", "Last *": "Bloqueios" } } },
    ],
    ordenarPor: "Bloqueios",
  }));
  g.add(8, 10, tabela("Portas mais procuradas", [
    li(`topk(15, sum by (dstport, proto) (count_over_time(${BLOQUEIOS} | regexp ${FILTERLOG_RE} | dstport != "" [$__range])))`, "{{dstport}}/{{proto}}"),
  ], {
    transformacoes: [
      { id: "reduce", options: { reducers: ["lastNotNull"], mode: "seriesToRows" } },
      { id: "organize", options: { renameByName: { Field: "Porta", "Last *": "Bloqueios" } } },
    ],
    ordenarPor: "Bloqueios",
  }));
  g.add(8, 10, logs("Últimos bloqueios",
    `${BLOQUEIOS} | regexp ${FILTERLOG_RE} | line_format "{{.interface}} {{.direction}} {{.proto}}  {{.src}}:{{.srcport}} → {{.dst}}:{{.dstport}}"`));
  g.add(24, 10, logs("Outros logs do OPNsense", '{host="opnsense", program!="filterlog"}'));

  dashboards["04-opnsense"] = dashboard("bergatrix-opnsense", "OPNsense", g, {
    descricao: "Firewall: gateways, interfaces, pf, serviços e log de bloqueios",
  });
}

// ════════════════════════════════════════════════════════════════
// 05 · VPS e túnel
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  const h = 'host="vps"';
  g.add(3, 4, stat("VPS", [qi('up{job="node", host="vps"}')], { mappings: NO_AR, thresholds: binario, cor: "background" }));
  g.add(4, 4, stat("Último handshake", [qi(`time() - max(wireguard_latest_handshake_seconds{${h}})`)], { unit: "s", thresholds: sobe(150, 180, 300), cor: "background" }));
  g.add(4, 4, stat("Latência do túnel", [q(RTT("vps"))], { unit: "s", noValue: "sem resposta", thresholds: sobe(0.05, 0.08, 0.15), grafico: true }));
  g.add(3, 4, stat("Perda (5 min)", [q('100 * (1 - avg_over_time(probe_success{job="ping", instance="vps"}[5m]))')], { unit: "percent", thresholds: sobe(1, 5, 20) }));
  g.add(3, 4, stat("CPU", [q(cpu("," + h))], { unit: "percent", thresholds: sobe(70, 85, 95), grafico: true }));
  g.add(3, 4, stat("Memória", [q(mem(h))], { unit: "percent", thresholds: sobe(80, 90, 95), grafico: true }));
  g.add(4, 4, stat("Conexões no HAProxy", [q("sum(haproxy_frontend_current_sessions)")], { grafico: true }));

  g.add(12, 8, serie("Latência casa ↔ SP", [
    q(RTT("vps"), "Túnel (casa → VPS)"),
    q(RTT("1.1.1.1"), "Internet (casa → 1.1.1.1)"),
  ], { unit: "s", descricao: "Se as duas sobem juntas, o problema é a internet de casa" }));
  g.add(12, 8, serie("Tráfego da VPS", [
    q(`rate(node_network_receive_bytes_total{${h}, ${NET}}[$__rate_interval]) * 8`, "{{device}} recebe"),
    q(`rate(node_network_transmit_bytes_total{${h}, ${NET}}[$__rate_interval]) * 8`, "{{device}} envia"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia")], legenda: "table" }));

  g.add(12, 8, serie("Tráfego do túnel (por peer)", [
    q(`rate(wireguard_received_bytes_total{${h}}[$__rate_interval]) * 8`, "{{interface}} recebe ({{allowed_ips}})"),
    q(`rate(wireguard_sent_bytes_total{${h}}[$__rate_interval]) * 8`, "{{interface}} envia ({{allowed_ips}})"),
  ], { unit: "bps", overrides: [PARA_BAIXO(".*envia.*")], legenda: "table" }));
  g.add(12, 8, serie("Pacotes descartados pelo nftables", [
    q(`sum by (rule) (rate(nftables_rule_packets_total{${h}, verdict="drop"}[5m]))`, "{{rule}}"),
  ], { unit: "pps", descricao: "Inclui o bloqueio geográfico (pacotes de fora do Brasil nas portas 80/443)", legenda: "table" }));

  g.add(8, 8, serie("CAKE: atraso na fila", [
    q(`qdisc_cake_tin_avg_delay_seconds{${h}}`, "{{device}} tin {{tin}} média"),
    q(`qdisc_cake_tin_peak_delay_seconds{${h}}`, "{{device}} tin {{tin}} pico"),
  ], { unit: "s", descricao: "Atraso que o controle de fila (anti-bufferbloat) está segurando" }));
  g.add(8, 8, serie("CAKE: descartes", [q(`rate(qdisc_cake_drops_total{${h}}[$__rate_interval])`, "{{device}}")], { unit: "pps" }));
  g.add(8, 8, serie("HAProxy: conexões novas", [q("sum by (proxy) (rate(haproxy_frontend_connections_total[$__rate_interval]))", "{{proxy}}")], { unit: "cps" }));

  g.add(12, 8, tabela("Regras do nftables (contadores)", [
    qt(`nftables_rule_packets_total{${h}}`),
    qt(`nftables_rule_bytes_total{${h}}`),
  ], {
    transformacoes: juntar({ table: "Tabela", chain: "Chain", rule: "Regra", verdict: "Ação", "Value #A": "Pacotes", "Value #B": "Bytes" }, ["family", "host", "papel"]),
    colunas: [coluna("Bytes", { unit: "decbytes" })],
    ordenarPor: "Pacotes",
  }));
  g.add(12, 8, serie("Tentativas de SSH que falharam", [
    l(`sum(count_over_time({${h}, program=~"sshd.*"} |~ "Failed password|Invalid user|authentication failure" [$__auto]))`, "Falhas"),
  ], { barras: true, preencher: 80 }));
  g.add(24, 10, logs("Logs da VPS", `{${h}}`));

  dashboards["05-vps"] = dashboard("bergatrix-vps", "VPS e túnel", g, {
    descricao: "VPS de borda: túnel WireGuard, latência, nftables, CAKE e HAProxy",
  });
}

// ════════════════════════════════════════════════════════════════
// 06 · Logs
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  const sel = '{host=~"$host", job=~"$job"}';
  g.add(24, 7, serie("Volume de logs", [
    l(`sum by (host, job) (count_over_time(${sel} |~ "(?i)$busca" [$__auto]))`, "{{host}} · {{job}}"),
  ], { barras: true, empilhar: true, preencher: 80 }));
  g.add(24, 7, serie("Erros por container", [
    l('sum by (container) (count_over_time({job="docker", container=~"$container"} |~ "(?i)(error|erro|fatal|panic|exception|traceback)" [$__auto]))', "{{container}}"),
  ], { barras: true, empilhar: true, preencher: 80, legenda: "table" }));
  g.add(24, 14, logs("Logs (máquina e origem escolhidas)", `${sel} |~ "(?i)$busca"`));
  g.add(24, 14, logs("Logs dos containers", '{job="docker", container=~"$container"} |~ "(?i)$busca"'));

  dashboards["06-logs"] = dashboard("bergatrix-logs", "Logs", g, {
    descricao: "Busca nos logs do servidor, dos containers, do OPNsense e da VPS",
    de: "now-1h",
    atualizar: "30s",
    variaveis: [
      varFixa("host", "Máquina", ["bergaserver", "opnsense", "vps"]),
      varFixa("job", "Origem", ["docker", "journal", "traefik", "syslog"]),
      varLokiLabel("container", "Container", "container", '{job="docker"}'),
      varTexto("busca", "Buscar (regex)"),
    ],
  });
}

// ════════════════════════════════════════════════════════════════
// 07 · Acessos (quem acessa os apps pelo Traefik)
// ════════════════════════════════════════════════════════════════
{
  const g = new Grade();
  // IP, app, caminho e status vêm do JSON do access.log; país, cidade e
  // operadora são metadados que o Alloy põe em cada linha (GeoLite2).
  const AC = '{job="traefik"} | json ClientHost="ClientHost", RequestHost="RequestHost", RequestPath="RequestPath", DownstreamStatus="DownstreamStatus" | ClientHost=~"$ip" | RequestHost=~"$app"';
  const linhas = (expr: string) => [
    { id: "reduce", options: { reducers: ["lastNotNull"], mode: "seriesToRows", labelsToFields: true } },
    { id: "organize", options: { excludeByName: { Field: true }, renameByName: { ...ROTULOS_ACESSO, "Last *": expr } } },
  ];
  const IP_LINKS = coluna("IP", {
    links: [
      { title: "Tudo deste IP", url: "/d/bergatrix-acessos/?var-ip=${__value.raw}&${__url_time_range}" },
      { title: "Reputação (AbuseIPDB)", url: "https://www.abuseipdb.com/check/${__value.raw}", targetBlank: true },
    ],
  });

  g.add(6, 4, stat("Requisições", [li(`sum(count_over_time(${AC} [$__range]))`)], {}));
  g.add(6, 4, stat("IPs diferentes", [li(`count(sum by (ClientHost) (count_over_time(${AC} [$__range])))`)], {}));
  g.add(6, 4, stat("IPs de fora do Brasil", [li(`count(sum by (ClientHost) (count_over_time(${AC} | pais != "" | pais != "Brazil" [$__range]))) or vector(0)`)], {
    thresholds: limites([null, OK], [1, ATENCAO]),
    descricao: "A VPS bloqueia o que vem de fora do Brasil. IP estrangeiro aqui entrou por outro caminho (rede local, VPN) ou a base de países discorda.",
  }));
  g.add(6, 4, stat("Negados (401/403)", [li(`sum(count_over_time(${AC} | DownstreamStatus =~ "401|403" [$__range])) or vector(0)`)], {
    descricao: "Login recusado ou acesso proibido. Muitos do mesmo IP = tentativa de adivinhar senha.",
  }));

  g.add(24, 10, tabela("Quem acessou (clique no IP para ver só ele)", [
    li(`topk(100, sum by (ClientHost, pais, cidade, asn_org) (count_over_time(${AC} [$__range])))`),
  ], { transformacoes: linhas("Requisições"), colunas: [IP_LINKS], ordenarPor: "Requisições" }));

  g.add(12, 10, tabela("IP × app", [
    li(`topk(100, sum by (ClientHost, RequestHost) (count_over_time(${AC} [$__range])))`),
  ], { transformacoes: linhas("Requisições"), colunas: [IP_LINKS], ordenarPor: "Requisições" }));
  g.add(12, 10, tabela("Erros por IP (4xx e 5xx)", [
    li(`topk(100, sum by (ClientHost, pais, DownstreamStatus) (count_over_time(${AC} | DownstreamStatus >= 400 [$__range])))`),
  ], { transformacoes: linhas("Respostas"), colunas: [IP_LINKS], ordenarPor: "Respostas" }));

  g.add(12, 8, serie("Requisições por app", [l(`sum by (RequestHost) (count_over_time(${AC} [$__auto]))`, "{{RequestHost}}")], {
    barras: true, empilhar: true, preencher: 80, legenda: "table",
  }));
  g.add(12, 8, serie("Requisições por país", [l(`sum by (pais) (count_over_time(${AC} | pais != "" [$__auto]))`, "{{pais}}")], {
    barras: true, empilhar: true, preencher: 80, legenda: "table",
  }));

  g.add(8, 10, tabela("Operadoras (ASN)", [li(`topk(30, sum by (asn_org) (count_over_time(${AC} | asn_org != "" [$__range])))`)], {
    transformacoes: linhas("Requisições"), ordenarPor: "Requisições",
    descricao: "Datacenters (Amazon, Google, DigitalOcean, OVH…) costumam ser robôs; operadoras residenciais, pessoas.",
  }));
  g.add(8, 10, tabela("Caminhos procurados que não existem (404)", [
    li(`topk(30, sum by (RequestPath) (count_over_time(${AC} | DownstreamStatus = "404" [$__range])))`),
  ], {
    transformacoes: linhas("Vezes"), ordenarPor: "Vezes",
    descricao: "/.env, /wp-admin, /.git… são varreduras atrás de falhas conhecidas.",
  }));
  g.add(8, 10, tabela("Navegadores e robôs (User-Agent)", [
    li(`topk(30, sum by (ua) (count_over_time({job="traefik"} | json ClientHost="ClientHost", RequestHost="RequestHost", ua="[\\"request_User-Agent\\"]" | ClientHost=~"$ip" | RequestHost=~"$app" [$__range])))`),
  ], { transformacoes: linhas("Requisições"), ordenarPor: "Requisições" }));

  g.add(24, 14, logs("Acessos",
    '{job="traefik"} | json | ClientHost=~"$ip" | RequestHost=~"$app" | line_format "{{.ClientHost}} {{.pais}} {{.asn_org}} · {{.RequestMethod}} {{.RequestHost}}{{.RequestPath}} → {{.DownstreamStatus}} · {{.request_User_Agent}}"'));

  dashboards["07-acessos"] = dashboard("bergatrix-acessos", "Acessos", g, {
    descricao: "Quem acessa os apps pelo Traefik: IP, país, operadora, app, erros e robôs",
    de: "now-24h",
    variaveis: [
      varTexto("ip", "IP (regex)", ".*"),
      varTexto("app", "App (regex do endereço)", ".*"),
    ],
  });
}

// ════════════════════════════════════════════════════════════════
// Alertas (Grafana, e-mail)
// ════════════════════════════════════════════════════════════════

type Regra = {
  uid: string; titulo: string; expr: string; op: "gt" | "lt"; limite: number; para: string;
  resumo: string; descricao?: string; gravidade?: "critico" | "aviso"; fonte?: "prometheus" | "loki";
};

// Templates do Grafana: $labels e $values com um $ só (o Grafana 13 não
// troca $$ por $ nas regras de alerta provisionadas).
const V = "{{ printf \"%.0f\" $values.A.Value }}";
const V1 = "{{ printf \"%.1f\" $values.A.Value }}";
const L = (x: string) => `{{ $labels.${x} }}`;

const grupos: Record<string, Regra[]> = {
  "Máquinas": [
    { uid: "maquina-fora", titulo: "Máquina fora do ar", expr: 'up{job="node"}', op: "lt", limite: 1, para: "5m", gravidade: "critico",
      resumo: `${L("host")} não responde há 5 min`,
      descricao: "A máquina caiu, o node_exporter parou ou a rede até ela caiu." },
    { uid: "alvo-fora", titulo: "Coleta parou", expr: 'up{job!="node"}', op: "lt", limite: 1, para: "10m",
      resumo: `${L("job")} (${L("instance")}) não responde há 10 min`,
      descricao: "Um exporter parou: os painéis dele ficam sem dados, a máquina pode estar bem." },
    { uid: "cpu-alta", titulo: "CPU alta", expr: '100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))', op: "gt", limite: 90, para: "15m",
      resumo: `CPU de ${L("host")} em ${V}% há 15 min` },
    { uid: "memoria-alta", titulo: "Memória alta",
      expr: "max by (host) (100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) or 100 * (1 - (node_memory_free_bytes + node_memory_inactive_bytes) / node_memory_size_bytes))",
      op: "gt", limite: 90, para: "10m", resumo: `Memória de ${L("host")} em ${V}%` },
    { uid: "disco-cheio", titulo: "Disco quase cheio", expr: `100 * (1 - node_filesystem_avail_bytes{${FS}} / node_filesystem_size_bytes{${FS}})`,
      op: "gt", limite: 85, para: "10m", resumo: `${L("mountpoint")} em ${L("host")} com ${V}% de uso` },
    { uid: "disco-critico", titulo: "Disco cheio", expr: `100 * (1 - node_filesystem_avail_bytes{${FS}} / node_filesystem_size_bytes{${FS}})`,
      op: "gt", limite: 95, para: "5m", gravidade: "critico", resumo: `${L("mountpoint")} em ${L("host")} com ${V}% de uso` },
    { uid: "disco-enche-24h", titulo: "Disco vai encher em 24 h",
      expr: `predict_linear(node_filesystem_avail_bytes{${FS}}[6h], 86400) / 1e9`, op: "lt", limite: 0, para: "1h",
      resumo: `${L("mountpoint")} em ${L("host")} enche em menos de 24 h no ritmo atual` },
    { uid: "temperatura-cpu", titulo: "Temperatura alta", expr: "max by (host, chip, sensor) (node_hwmon_temp_celsius)", op: "gt", limite: 85, para: "5m",
      gravidade: "critico", resumo: `${L("host")} (${L("chip")} ${L("sensor")}) a ${V} °C` },
    { uid: "systemd-falhou", titulo: "Serviço do systemd falhou", expr: 'node_systemd_unit_state{state="failed"}', op: "gt", limite: 0, para: "5m",
      resumo: `${L("name")} falhou em ${L("host")}` },
  ],
  "Proxmox": [
    { uid: "vm-parada", titulo: "VM parada",
      expr: `(pve_up${GUEST} * on (id) group_left (name) pve_guest_info) and on (id) (pve_onboot_status == 1)`, op: "lt", limite: 1, para: "5m",
      gravidade: "critico", resumo: `A VM ${L("name")} (${L("id")}) está parada`, descricao: "Só VMs com início automático (onboot)." },
    { uid: "storage-cheio", titulo: "Storage do Proxmox quase cheio",
      expr: '100 * pve_disk_usage_bytes{id=~"storage/.*"} / pve_disk_size_bytes{id=~"storage/.*"}', op: "gt", limite: 85, para: "15m",
      resumo: `${L("id")} com ${V}% de uso` },
    { uid: "smart-falha", titulo: "Disco com falha SMART", expr: "smartmon_device_smart_healthy", op: "lt", limite: 1, para: "0s",
      gravidade: "critico", resumo: `O disco ${L("disk")} reprovou no SMART`, descricao: "Faça backup e planeje a troca." },
    { uid: "smart-setores", titulo: "Disco com setores ruins",
      expr: 'max by (disk) (smartmon_attr_raw_value{name=~"reallocated_sector_ct|current_pending_sector"}) or max by (disk) (smartmon_reallocated_sector_ct_raw_value) or max by (disk) (smartmon_current_pending_sector_raw_value)',
      op: "gt", limite: 0, para: "0s", resumo: `O disco ${L("disk")} tem ${V} setores realocados ou pendentes` },
    { uid: "disco-quente", titulo: "Disco quente",
      expr: 'max by (disk) (smartmon_attr_raw_value{name="temperature_celsius"}) or max by (disk) (smartmon_temperature_celsius_raw_value)',
      op: "gt", limite: 55, para: "10m", resumo: `O disco ${L("disk")} está a ${V} °C` },
    { uid: "ssd-desgaste", titulo: "SSD perto do fim da vida útil", expr: VIDA_SSD, op: "lt", limite: 20, para: "1h",
      resumo: `O SSD ${L("disk")} tem ${V}% de vida útil restante`, descricao: "Planeje a troca; abaixo de 10% o fabricante não garante mais nada." },
    { uid: "nvme-aviso", titulo: "NVMe com aviso crítico", expr: "nvme_critical_warning", op: "gt", limite: 0, para: "0s",
      gravidade: "critico", resumo: `O NVMe ${L("device")} acendeu o aviso crítico (código ${V})`,
      descricao: "Pode ser falta de blocos reserva, temperatura, modo só leitura ou falha de backup de energia. Faça backup." },
  ],
  "Servidor Docker": [
    { uid: "container-reiniciando", titulo: "Container reiniciando", expr: 'changes(container_start_time_seconds{name!=""}[15m])', op: "gt", limite: 2, para: "0s",
      resumo: `${L("name")} reiniciou ${V} vezes em 15 min` },
    { uid: "gpu-quente", titulo: "GPU quente", expr: "nvidia_smi_temperature_gpu", op: "gt", limite: 85, para: "5m", resumo: `GPU a ${V} °C` },
    { uid: "traefik-5xx", titulo: "Muitos erros 5xx",
      expr: SVC('(100 * sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[10m])) / sum by (service) (rate(traefik_service_requests_total[10m]))) and on (service) (sum by (service) (rate(traefik_service_requests_total[10m])) > 0.05)'),
      op: "gt", limite: 10, para: "10m", resumo: `${L("service")} com ${V}% de respostas 5xx` },
    { uid: "oom", titulo: "Processo morto por falta de memória", fonte: "loki",
      expr: 'sum by (host) (count_over_time({job=~"journal|syslog"} |~ "(?i)out of memory: killed process" [10m]))', op: "gt", limite: 0, para: "0s",
      resumo: `O kernel de ${L("host")} matou um processo por falta de memória`, descricao: "Veja o painel Logs (busca: out of memory)." },
  ],
  "Rede": [
    { uid: "tunel-caiu", titulo: "Túnel WireGuard sem handshake", expr: 'time() - wireguard_latest_handshake_seconds{host="vps"}', op: "gt", limite: 300, para: "2m",
      gravidade: "critico", resumo: `Túnel SP ↔ casa sem handshake há ${V} s (${L("allowed_ips")})`, descricao: "Os sites ficam fora do ar para quem vem pela VPS." },
    { uid: "ping-falhou", titulo: "Sem resposta ao ping", expr: 'probe_success{job="ping"}', op: "lt", limite: 1, para: "5m",
      resumo: `${L("instance")} não responde ao ping há 5 min` },
    { uid: "link-mudou", titulo: "Velocidade de link mudou", expr: `changes(node_network_speed_bytes{${NET}}[30m])`, op: "gt", limite: 0, para: "0s",
      resumo: `${L("device")} em ${L("host")} renegociou a velocidade`,
      descricao: "Cabo, porta ou placa com problema costuma aparecer assim (ex.: 1 Gb/s caindo para 100 Mb/s). Veja o painel Máquina." },
    { uid: "internet-lenta", titulo: "Internet lenta",
      expr: "100 * speedtest_download_bits_per_second / quantile_over_time(0.5, speedtest_download_bits_per_second[7d])", op: "lt", limite: 50, para: "2h",
      resumo: `Download em ${V}% do normal da última semana há 2 h`, descricao: "Pelo teste de velocidade de hora em hora." },
    { uid: "tunel-lento", titulo: "Túnel lento", expr: `(${RTT("vps")}) * 1000`, op: "gt", limite: 100, para: "10m",
      resumo: `Latência casa → VPS em ${V} ms` },
    { uid: "gateway", titulo: "Gateway com problema", expr: "opnsense_gateways_status", op: "lt", limite: 1, para: "3m",
      gravidade: "critico", resumo: `Gateway ${L("name")} não está "no ar" (código ${V})`, descricao: "0 fora, 2 desconhecido, 3 aguardando, 4 perda, 5 latência, 6 desligado." },
    { uid: "gateway-perda", titulo: "Perda de pacotes na internet", expr: "opnsense_gateways_loss_percentage", op: "gt", limite: 10, para: "5m",
      resumo: `Gateway ${L("name")} com ${V}% de perda` },
    { uid: "opnsense-servico", titulo: "Serviço do OPNsense parado", expr: "opnsense_services_status", op: "lt", limite: 1, para: "5m",
      resumo: `${L("description")} (${L("name")}) parado no OPNsense` },
    { uid: "pf-estados", titulo: "Tabela de estados do pf enchendo", expr: "100 * opnsense_pf_states_current / opnsense_pf_states_limit", op: "gt", limite: 80, para: "10m",
      resumo: `Tabela de estados do OPNsense em ${V}%` },
  ],
  "Sites": [
    { uid: "site-fora", titulo: "Site fora do ar", expr: 'probe_success{job="sites"}', op: "lt", limite: 1, para: "3m",
      gravidade: "critico", resumo: `${L("instance")} não responde pelo caminho público há 3 min` },
    { uid: "certificado", titulo: "Certificado perto de vencer", expr: '(probe_ssl_earliest_cert_expiry{job="sites"} - time()) / 86400', op: "lt", limite: 14, para: "1h",
      resumo: `O certificado de ${L("instance")} vence em ${V} dias`, descricao: "O Traefik renova sozinho com 30 dias; se chegou aqui, a renovação está falhando (deSEC)." },
  ],
  "Acessos": [
    { uid: "acesso-estrangeiro", titulo: "Acesso de fora do Brasil", fonte: "loki",
      expr: 'sum by (ip, pais, asn_org) (count_over_time({job="traefik"} | pais != "" | pais != "Brazil" [15m]))', op: "gt", limite: 0, para: "0s",
      resumo: `${L("ip")} (${L("pais")}, ${L("asn_org")}) fez ${V} requisições em 15 min`,
      descricao: "A VPS bloqueia fora do Brasil: veio por outro caminho (VPN, rede local) ou a base de países discorda. Painel Acessos, filtre pelo IP." },
    { uid: "forca-bruta", titulo: "Muitos logins recusados", fonte: "loki",
      expr: 'sum by (ClientHost) (count_over_time({job="traefik"} | json ClientHost="ClientHost", DownstreamStatus="DownstreamStatus" | DownstreamStatus =~ "401|403" [10m]))',
      op: "gt", limite: 30, para: "0s",
      resumo: `${L("ClientHost")} teve ${V} respostas 401/403 em 10 min`,
      descricao: "Pode ser alguém tentando senhas, ou um app com a senha antiga salva. O CrowdSec costuma banir sozinho." },
    { uid: "varredura", titulo: "Varredura de caminhos", fonte: "loki",
      expr: 'sum by (ClientHost) (count_over_time({job="traefik"} | json ClientHost="ClientHost", DownstreamStatus="DownstreamStatus" | DownstreamStatus = "404" [10m]))',
      op: "gt", limite: 100, para: "0s",
      resumo: `${L("ClientHost")} pediu ${V} caminhos inexistentes em 10 min`,
      descricao: "Robô procurando falhas conhecidas (/.env, /wp-admin…). Veja no painel Acessos o que ele tentou." },
    { uid: "volume-ip", titulo: "IP com volume muito alto", fonte: "loki",
      expr: `sum by (ClientHost) (count_over_time({job="traefik"} | json ClientHost="ClientHost" | ${PRIVADO} [10m]))`,
      op: "gt", limite: 5000, para: "0s",
      resumo: `${L("ClientHost")} fez ${V} requisições em 10 min`,
      descricao: "Raspagem, abuso ou um app seu em loop. Rede local fica de fora." },
  ],
};

function regraGrafana(r: Regra) {
  const ds = r.fonte ?? "prometheus";
  return {
    uid: r.uid,
    title: r.titulo,
    condition: "C",
    data: [
      {
        refId: "A",
        relativeTimeRange: { from: 600, to: 0 },
        datasourceUid: ds,
        model: ds === "loki"
          ? { refId: "A", expr: r.expr, queryType: "instant", intervalMs: 1000, maxDataPoints: 43200 }
          : { refId: "A", expr: r.expr, instant: true, range: false, intervalMs: 1000, maxDataPoints: 43200 },
      },
      {
        refId: "C",
        datasourceUid: "__expr__",
        model: {
          refId: "C", type: "threshold", expression: "A",
          conditions: [{ evaluator: { type: r.op, params: [r.limite] } }],
        },
      },
    ],
    noDataState: "OK",
    execErrState: "Error",
    for: r.para,
    labels: { gravidade: r.gravidade ?? "aviso" },
    annotations: { summary: r.resumo, ...(r.descricao ? { description: r.descricao } : {}) },
    isPaused: false,
  };
}

const regras = {
  apiVersion: 1,
  groups: Object.entries(grupos).map(([name, rs]) => ({
    orgId: 1, name, folder: "Bergatrix", interval: "1m", rules: rs.map(regraGrafana),
  })),
};

// ── Gravar ─────────────────────────────────────────────────────

const pasta = new URL("../config/grafana/dashboards/", import.meta.url);
for (const [nome, d] of Object.entries(dashboards)) {
  await Deno.writeTextFile(new URL(`${nome}.json`, pasta), JSON.stringify(d, null, 2) + "\n");
}
const cabecalho = "# GERADO por dashboards/gerar.ts — não edite à mão.\n# Alertas do Grafana; destino em contato.yml.\n";
await Deno.writeTextFile(
  new URL("../config/grafana/provisioning/alerting/regras.yml", import.meta.url),
  cabecalho + stringify(regras, { lineWidth: -1 }),
);
console.log(`${Object.keys(dashboards).length} dashboards e ${Object.values(grupos).flat().length} alertas gerados.`);
