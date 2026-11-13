// Peças para montar dashboards do Grafana em código. Usado por gerar.ts.

export const PROM = { type: "prometheus", uid: "prometheus" };
export const LOKI = { type: "loki", uid: "loki" };

// Cores de estado (Grafana): reservadas para bom/atenção/grave/crítico.
export const OK = "green";
export const ATENCAO = "yellow";
export const GRAVE = "orange";
export const CRITICO = "red";

// ── Consultas ──────────────────────────────────────────────────

type Alvo = Record<string, unknown>;
const REFS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/** Consulta PromQL ao longo do tempo. */
export function q(expr: string, legenda = "", extra: Alvo = {}): Alvo {
  return { datasource: PROM, expr, legendFormat: legenda || "__auto", range: true, instant: false, ...extra };
}
/** Consulta PromQL do valor atual (stat, tabela, barras). */
export function qi(expr: string, legenda = "", extra: Alvo = {}): Alvo {
  return { datasource: PROM, expr, legendFormat: legenda || "__auto", range: false, instant: true, ...extra };
}
/** Consulta PromQL do valor atual em formato de tabela (uma coluna por consulta). */
export function qt(expr: string, extra: Alvo = {}): Alvo {
  return { datasource: PROM, expr, format: "table", range: false, instant: true, ...extra };
}
/** Consulta LogQL (logs ou métrica ao longo do tempo). */
export function l(expr: string, legenda = "", extra: Alvo = {}): Alvo {
  return { datasource: LOKI, expr, legendFormat: legenda, queryType: "range", ...extra };
}
/** Consulta LogQL do valor no período inteiro (tabelas de "top"). */
export function li(expr: string, legenda = "", extra: Alvo = {}): Alvo {
  return { datasource: LOKI, expr, legendFormat: legenda, queryType: "instant", ...extra };
}

// ── Limites, mapeamentos e campos ──────────────────────────────

export type Passo = [number | null, string];
export function limites(...passos: Passo[]) {
  return { mode: "absolute", steps: passos.map(([value, color]) => ({ value, color })) };
}
/** Verde até `atencao`, amarelo, laranja em `grave`, vermelho em `critico`. */
export function sobe(atencao: number, grave: number, critico: number) {
  return limites([null, OK], [atencao, ATENCAO], [grave, GRAVE], [critico, CRITICO]);
}
/** Vermelho abaixo de 1, verde em 1 (no ar / saudável). */
export const binario = limites([null, CRITICO], [1, OK]);

export function mapa(valores: Record<string, [string, string]>) {
  const options: Record<string, unknown> = {};
  let index = 0;
  for (const [valor, [text, color]] of Object.entries(valores)) {
    options[valor] = { text, color, index: index++ };
  }
  return [{ type: "value", options }];
}
export const NO_AR = mapa({ "0": ["Fora", CRITICO], "1": ["No ar", OK] });
export const SAUDE = mapa({ "0": ["FALHA", CRITICO], "1": ["OK", OK] });
export const SERVICO = mapa({ "0": ["Parado", CRITICO], "1": ["Rodando", OK] });

type Campo = {
  unit?: string; decimals?: number; min?: number; max?: number;
  thresholds?: unknown; mappings?: unknown[]; color?: unknown; custom?: Record<string, unknown>;
  noValue?: string;
};
function padroes(c: Campo = {}, customPadrao: Record<string, unknown> = {}) {
  const d: Record<string, unknown> = {
    unit: c.unit ?? "short",
    thresholds: c.thresholds ?? limites([null, OK]),
    mappings: c.mappings ?? [],
    color: c.color ?? (c.thresholds ? { mode: "thresholds" } : { mode: "palette-classic" }),
    custom: { ...customPadrao, ...(c.custom ?? {}) },
  };
  if (c.decimals !== undefined) d.decimals = c.decimals;
  if (c.min !== undefined) d.min = c.min;
  if (c.max !== undefined) d.max = c.max;
  if (c.noValue !== undefined) d.noValue = c.noValue;
  return d;
}

/** Sobrescreve propriedades das séries cujo nome casa com a regex. */
export function sobrescrever(regex: string, props: Record<string, unknown>) {
  return {
    matcher: { id: "byRegexp", options: regex },
    properties: Object.entries(props).map(([id, value]) => ({ id, value })),
  };
}
/** Séries de envio/escrita para baixo do zero (tráfego e disco). */
export const PARA_BAIXO = (regex: string) => sobrescrever(regex, { "custom.transform": "negative-Y" });
/** Coluna da tabela. */
export function coluna(nome: string, props: Record<string, unknown>) {
  return {
    matcher: { id: "byName", options: nome },
    properties: Object.entries(props).map(([id, value]) => ({ id, value })),
  };
}

// ── Painéis ────────────────────────────────────────────────────

type Painel = Record<string, unknown>;
function comRefs(alvos: Alvo[]) {
  return alvos.map((a, i) => ({ refId: REFS[i], ...a }));
}
function base(type: string, title: string, alvos: Alvo[], descricao?: string): Painel {
  const p: Painel = { type, title, targets: comRefs(alvos) };
  const ds = alvos[0]?.datasource;
  if (ds) p.datasource = ds;
  if (descricao) p.description = descricao;
  return p;
}

export function stat(title: string, alvos: Alvo[], c: Campo & {
  descricao?: string; grafico?: boolean; texto?: "auto" | "value" | "value_and_name" | "name";
  calculo?: string; cor?: "value" | "background" | "none";
} = {}): Painel {
  return {
    ...base("stat", title, alvos, c.descricao),
    fieldConfig: { defaults: padroes({ ...c, thresholds: c.thresholds ?? limites([null, "text"]) }), overrides: [] },
    options: {
      reduceOptions: { calcs: [c.calculo ?? "lastNotNull"], fields: "", values: false },
      colorMode: c.cor ?? "value",
      graphMode: c.grafico ? "area" : "none",
      justifyMode: "auto",
      textMode: c.texto ?? "auto",
      orientation: "auto",
      wideLayout: true,
      showPercentChange: false,
    },
  };
}

export function barras(title: string, alvos: Alvo[], c: Campo & { descricao?: string; ordenar?: boolean } = {}): Painel {
  return {
    ...base("bargauge", title, alvos, c.descricao),
    fieldConfig: { defaults: padroes(c), overrides: [] },
    options: {
      reduceOptions: { calcs: ["lastNotNull"], fields: "", values: false },
      orientation: "horizontal",
      displayMode: "basic",
      valueMode: "text",
      namePlacement: "left",
      showUnfilled: true,
      sizing: "auto",
      minVizHeight: 14,
      maxVizHeight: 22,
      legend: { showLegend: false },
    },
    ...(c.ordenar ? { transformations: [{ id: "sortBy", options: { sort: [{ field: "Value", desc: true }] } }] } : {}),
  };
}

export function serie(title: string, alvos: Alvo[], c: Campo & {
  descricao?: string; empilhar?: boolean; preencher?: number; barras?: boolean;
  overrides?: unknown[]; legenda?: "list" | "table" | "hidden"; linhaLimite?: boolean;
} = {}): Painel {
  const custom: Record<string, unknown> = {
    drawStyle: c.barras ? "bars" : "line",
    lineWidth: 2,
    fillOpacity: c.preencher ?? (c.empilhar ? 60 : 10),
    gradientMode: "none",
    showPoints: "never",
    pointSize: 8,
    spanNulls: false,
    lineInterpolation: "smooth",
    stacking: { mode: c.empilhar ? "normal" : "none", group: "A" },
    axisPlacement: "auto",
    axisSoftMin: 0,
    thresholdsStyle: { mode: c.linhaLimite ? "dashed" : "off" },
  };
  const legenda = c.legenda ?? "list";
  return {
    ...base("timeseries", title, alvos, c.descricao),
    fieldConfig: { defaults: padroes({ ...c, color: c.color ?? { mode: "palette-classic" } }, custom), overrides: c.overrides ?? [] },
    options: {
      tooltip: { mode: "multi", sort: "desc" },
      legend: {
        showLegend: legenda !== "hidden",
        displayMode: legenda === "hidden" ? "list" : legenda,
        placement: "bottom",
        calcs: legenda === "table" ? ["mean", "max", "lastNotNull"] : [],
      },
    },
  };
}

export function tabela(title: string, alvos: Alvo[], c: Campo & {
  descricao?: string; transformacoes?: unknown[]; colunas?: unknown[]; ordenarPor?: string; desc?: boolean;
} = {}): Painel {
  return {
    ...base("table", title, alvos, c.descricao),
    fieldConfig: { defaults: padroes(c, { align: "auto", cellOptions: { type: "auto" }, filterable: false }), overrides: c.colunas ?? [] },
    options: {
      showHeader: true,
      cellHeight: "sm",
      footer: { show: false, reducer: ["sum"], fields: "" },
      ...(c.ordenarPor ? { sortBy: [{ displayName: c.ordenarPor, desc: c.desc ?? true }] } : {}),
    },
    transformations: c.transformacoes ?? [],
  };
}

export function logs(title: string, expr: string, descricao?: string): Painel {
  return {
    ...base("logs", title, [l(expr)], descricao),
    options: {
      showTime: true, showLabels: false, showCommonLabels: false, wrapLogMessage: true,
      prettifyLogMessage: false, enableLogDetails: true, dedupStrategy: "none", sortOrder: "Descending",
    },
  };
}

export function alertas(title: string): Painel {
  return {
    type: "alertlist",
    title,
    options: {
      viewMode: "list",
      groupMode: "default",
      groupBy: [],
      maxItems: 20,
      sortOrder: 1,
      dashboardAlerts: false,
      alertName: "",
      alertInstanceLabelFilter: "",
      showInactiveAlerts: false,
      stateFilter: { firing: true, pending: true, noData: false, normal: false, error: true },
      folder: "",
    },
  };
}

export function texto(title: string, conteudo: string): Painel {
  return { type: "text", title, options: { mode: "markdown", content: conteudo } };
}

// ── Transformações de tabela ───────────────────────────────────

/** Junta várias consultas de tabela (uma coluna "Value #X" por consulta) e
 * renomeia/esconde colunas. */
export function juntar(nomes: Record<string, string>, esconder: string[] = []) {
  const excludeByName: Record<string, boolean> = { Time: true, job: true, instance: true, __name__: true };
  for (const e of esconder) excludeByName[e] = true;
  const indexByName: Record<string, number> = {};
  Object.values(nomes).forEach((n, i) => (indexByName[n] = i));
  return [
    { id: "merge", options: {} },
    { id: "organize", options: { excludeByName, renameByName: nomes, indexByName: {} } },
  ];
}

// ── Layout ─────────────────────────────────────────────────────

export class Grade {
  painels: Painel[] = [];
  private x = 0;
  private y = 0;
  private alturaLinha = 0;
  private id = 1;

  /** Linha de título que separa seções. */
  secao(title: string) {
    this.quebra();
    this.painels.push({ type: "row", title, id: this.id++, collapsed: false, panels: [], gridPos: { x: 0, y: this.y, w: 24, h: 1 } });
    this.y += 1;
  }
  /** Painel com largura w (de 24) e altura h; quebra a linha quando não cabe. */
  add(w: number, h: number, p: Painel) {
    if (this.x + w > 24) this.quebra();
    this.painels.push({ ...p, id: this.id++, gridPos: { x: this.x, y: this.y, w, h } });
    this.x += w;
    this.alturaLinha = Math.max(this.alturaLinha, h);
  }
  quebra() {
    if (this.x === 0) return;
    this.y += this.alturaLinha;
    this.x = 0;
    this.alturaLinha = 0;
  }
}

// ── Dashboard ──────────────────────────────────────────────────

export const LINKS = [{
  type: "dashboards", tags: ["bergatrix"], asDropdown: false, title: "Painéis",
  includeVars: false, keepTime: true, targetBlank: false, icon: "external link",
}];

export function dashboard(uid: string, title: string, grade: Grade, c: {
  descricao?: string; variaveis?: unknown[]; de?: string; atualizar?: string;
} = {}) {
  return {
    uid,
    title,
    description: c.descricao ?? "",
    tags: ["bergatrix"],
    editable: false,
    graphTooltip: 1, // crosshair compartilhado entre os gráficos
    timezone: "browser",
    refresh: c.atualizar ?? "1m",
    time: { from: c.de ?? "now-6h", to: "now" },
    timepicker: {},
    schemaVersion: 41,
    version: 1,
    links: LINKS,
    annotations: { list: [] },
    templating: { list: c.variaveis ?? [] },
    panels: grade.painels,
  };
}

// ── Variáveis ──────────────────────────────────────────────────

export function varProm(name: string, label: string, query: string, c: { todos?: boolean; multi?: boolean; padrao?: string } = {}) {
  return {
    type: "query", name, label, datasource: PROM,
    query: { qryType: 1, query, refId: "PrometheusVariableQueryEditor-VariableQuery" },
    definition: query, refresh: 2, sort: 1,
    includeAll: c.todos ?? false, multi: c.multi ?? false, allValue: c.todos ? ".+" : undefined,
    current: c.padrao ? { text: c.padrao, value: c.padrao } : {},
  };
}
export function varLokiLabel(name: string, label: string, rotulo: string, seletor: string, c: { todos?: boolean } = {}) {
  return {
    type: "query", name, label, datasource: LOKI,
    query: { type: 1, label: rotulo, stream: seletor, refId: "LokiVariableQueryEditor-VariableQuery" },
    refresh: 2, sort: 1, includeAll: c.todos ?? true, multi: true, allValue: ".+",
    current: { text: "All", value: "$__all" },
  };
}
export function varFixa(name: string, label: string, valores: string[], c: { todos?: boolean } = {}) {
  return {
    type: "custom", name, label, query: valores.join(","),
    includeAll: c.todos ?? true, multi: true, allValue: ".+",
    current: { text: "All", value: "$__all" },
    options: [],
  };
}
export function varTexto(name: string, label: string) {
  return { type: "textbox", name, label, query: "", current: { text: "", value: "" } };
}
