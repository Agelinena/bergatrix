import { createContext, ReactNode, useCallback, useContext, useEffect, useState } from "react";
import { Agent, api } from "./api";

// ── Agente atual ────────────────────────────────────────────────────
// Hoje há um agente (o servidor). A estrutura já aceita vários.

type AgentCtx = { agent: Agent | null; agents: Agent[]; reload: () => void; loaded: boolean };
const AgentContext = createContext<AgentCtx>({ agent: null, agents: [], reload: () => {}, loaded: false });

export function AgentProvider({ children }: { children: ReactNode }) {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [loaded, setLoaded] = useState(false);
  const reload = useCallback(() => {
    api<Agent[]>("/api/agents").then((a) => { setAgents(a); setLoaded(true); }).catch(() => setLoaded(true));
  }, []);
  useEffect(() => {
    reload();
    const t = setInterval(reload, 20_000);
    return () => clearInterval(t);
  }, [reload]);
  return (
    <AgentContext.Provider value={{ agent: agents[0] ?? null, agents, reload, loaded }}>
      {children}
    </AgentContext.Provider>
  );
}

export const useAgent = () => useContext(AgentContext);

// ── Dados ───────────────────────────────────────────────────────────

export function useData<T>(path: string | null, deps: unknown[] = [], intervalMs = 0) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => {
    if (!path) return;
    api<T>(path).then((d) => { setData(d); setError(null); }).catch((e) => setError(e.message));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path, ...deps]);
  useEffect(() => {
    load();
    if (!intervalMs) return;
    const t = setInterval(load, intervalMs);
    return () => clearInterval(t);
  }, [load, intervalMs]);
  return { data, error, reload: load, setData };
}

// Executa uma ação com estado de "ocupado" e mensagem de erro.
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const run = useCallback(async (fn: () => Promise<string | void>) => {
    setBusy(true); setError(null); setMessage(null);
    try {
      const msg = await fn();
      if (msg) setMessage(msg);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }, []);
  return { busy, error, message, run, setMessage, setError };
}

// ── Componentes ─────────────────────────────────────────────────────

const STATUS: Record<string, [string, string]> = {
  success: ["ok", "sucesso"], warning: ["warn", "com avisos"], failed: ["err", "falhou"],
  running: ["info", "rodando"], pending: ["", "na fila"], dispatched: ["info", "enviado"], done: ["ok", "feito"],
};

export function StatusBadge({ status }: { status: string | null | undefined }) {
  const [cls, label] = STATUS[status ?? ""] ?? ["", status ?? "—"];
  return <span className={`badge ${cls}`}>{label}</span>;
}

export function Feedback({ error, message }: { error?: string | null; message?: string | null }) {
  if (error) return <div className="notice err">{error}</div>;
  if (message) return <div className="notice ok">{message}</div>;
  return null;
}

export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: ReactNode }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
      {hint && <small className="muted">{hint}</small>}
    </label>
  );
}

export function Modal({ children, onClose }: { children: ReactNode; onClose?: () => void }) {
  return (
    <div className="modal-back" onClick={(e) => e.target === e.currentTarget && onClose?.()}>
      <div className="modal" role="dialog" aria-modal="true">{children}</div>
    </div>
  );
}

// Campo de segredo: nunca mostra o valor guardado, só se ele existe.
export function SecretInput({ value, onChange, isSet, placeholder }: {
  value: string; onChange: (v: string) => void; isSet: boolean; placeholder?: string;
}) {
  return (
    <input
      type="password"
      autoComplete="new-password"
      value={value}
      placeholder={isSet ? "•••••• definido (digite para trocar)" : placeholder ?? "não definido"}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

export function NeedAgent() {
  return (
    <div className="notice warn">
      <p>Nenhum agente registrado ainda. Instale o agente no servidor em <a href="/agente">Agente</a>.</p>
    </div>
  );
}

export const lines = (text: string) => text.split("\n").map((s) => s.trim()).filter(Boolean);
