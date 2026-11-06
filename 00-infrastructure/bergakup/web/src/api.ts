// Cliente da API. Pedidos que mudam algo levam X-Bergakup: 1 (proteção contra CSRF).

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export async function api<T = unknown>(path: string, method = "GET", body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    credentials: "same-origin",
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(method !== "GET" ? { "X-Bergakup": "1" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401) {
    const next = encodeURIComponent(location.pathname + location.search);
    location.assign(`/login?next=${next}`);
    throw new ApiError(401, "Entre pelo Authentik.");
  }
  const data = response.headers.get("content-type")?.includes("json") ? await response.json() : null;
  if (!response.ok) {
    const detail = data?.detail;
    const message = typeof detail === "string" ? detail
      : Array.isArray(detail) ? detail.map((d: { msg?: string }) => d.msg).join("; ")
      : `Erro ${response.status}`;
    throw new ApiError(response.status, message);
  }
  return data as T;
}

// ── Tipos ────────────────────────────────────────────────────────────

export type Agent = {
  id: string; name: string; hostname: string; version: string; public_key: string;
  applied_revision: number; latest_revision: number; apply_error: string | null;
  last_seen_at: string | null; online: boolean;
};

export type Storage = {
  id: string; agent_id: string; name: string; kind: "b2" | "local" | "rest" | "sftp";
  endpoint: string; region: string; bucket: string; path: string; username: string;
  lock_days: number; has_secret: boolean;
};

export type Dataset = {
  id: string; agent_id: string; slug: string; name: string;
  kind: "userdata" | "docker" | "servidor" | "custom";
  paths: string[]; excludes: string[]; consistency: "none" | "policies" | "cold";
};

export type Repository = {
  id: string; dataset_id: string; storage_id: string; dataset_slug: string; dataset_name: string;
  storage_name: string; storage_kind: string; lock_days: number; subpath: string; url: string;
  has_password: boolean; initialized_at: string | null; recovery_key_at: string | null;
  snapshot_count: number; last_snapshot: string | null;
};

export type Retention = { last?: number; daily?: number; weekly?: number; monthly?: number };

export type Job = {
  id: string; repository_id: string; name: string; enabled: boolean; schedule: string;
  retention: Retention; prune_schedule: string; check_schedule: string; check_subset: string;
  anomaly_pct: number; stale_hours: number; ping_url: string;
};

export type Run = {
  id: string; kind: string; status: "running" | "success" | "warning" | "failed"; trigger: string;
  job_id: string | null; job: string | null; repository_id: string | null;
  started_at: string; finished_at: string | null; summary: Record<string, unknown>; error: string | null;
};

export type Snapshot = {
  id: string; short_id: string; time: string; hostname: string; paths: string[]; tags: string[];
  summary: Record<string, unknown>;
};

export type Command = {
  id: string; kind: string; status: "pending" | "dispatched" | "done" | "failed" | "canceled";
  run_id: string | null; run_status: string | null; summary: Record<string, unknown> | null; error: string | null;
};

// ── Comandos para o agente ──────────────────────────────────────────

export async function sendCommand(agentId: string, kind: string, params: Record<string, unknown> = {}) {
  return api<{ id: string }>("/api/commands", "POST", { agent_id: agentId, kind, params });
}

// Espera o agente terminar o comando (ele busca a cada ~25 s no máximo).
export async function waitCommand(id: string, timeoutMs = 120_000): Promise<Command> {
  const started = Date.now();
  for (;;) {
    const command = await api<Command>(`/api/commands/${id}`);
    if (command.status === "done" || command.status === "failed" || command.status === "canceled") {
      if (command.status === "failed") throw new Error(command.error || "O agente não conseguiu concluir.");
      return command;
    }
    if (Date.now() - started > timeoutMs) {
      throw new Error("O agente não respondeu a tempo. Ele está online? Veja em Execuções.");
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
}

// ── Formatação ──────────────────────────────────────────────────────

export function bytes(n: unknown): string {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  const i = Math.min(units.length - 1, Math.floor(Math.log(v) / Math.log(1024)));
  return `${(v / 1024 ** i).toFixed(i ? 1 : 0)} ${units[i]}`;
}

export function when(iso: string | null | undefined): string {
  if (!iso) return "nunca";
  return new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
}

export function ago(iso: string | null | undefined): string {
  if (!iso) return "nunca";
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 60) return "agora";
  if (s < 3600) return `há ${Math.round(s / 60)} min`;
  if (s < 86400) return `há ${Math.round(s / 3600)} h`;
  return `há ${Math.round(s / 86400)} d`;
}

export function duration(seconds: unknown): string {
  const s = Number(seconds) || 0;
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}`;
}

export const KIND_LABEL: Record<string, string> = {
  backup: "Backup", forget: "Retenção", prune: "Limpeza (prune)", check: "Verificação", restore: "Restauração",
  import_dumps: "Importar dumps", init: "Criar repositório", snapshots: "Listar snapshots", ls: "Navegar",
  test: "Testar", discover: "Descoberta", unlock: "Liberar",
};
