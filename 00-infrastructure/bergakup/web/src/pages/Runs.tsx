import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api, bytes, duration, KIND_LABEL, Run, when } from "../api";
import { Feedback, StatusBadge, useData } from "../ui";

export default function Runs() {
  const [status, setStatus] = useState("");
  const [light, setLight] = useState(false);
  const navigate = useNavigate();
  const query = `/api/runs?limit=200${status ? `&status=${status}` : ""}${light ? "&include_light=true" : ""}`;
  const { data, error } = useData<Run[]>(query, [query], 10_000);
  return (
    <>
      <h1>Execuções</h1>
      <div className="row" style={{ marginBottom: 12 }}>
        <select value={status} onChange={(e) => setStatus(e.target.value)} style={{ width: "auto" }}>
          <option value="">Todas</option>
          <option value="running">Rodando</option>
          <option value="failed">Falhas</option>
          <option value="warning">Com avisos</option>
          <option value="success">Sucesso</option>
        </select>
        <label className="check"><input type="checkbox" checked={light} onChange={(e) => setLight(e.target.checked)} />
          Mostrar consultas (navegar, listar)</label>
      </div>
      <Feedback error={error} />
      <div className="card scroll-x">
        <table>
          <thead><tr><th>Início</th><th>O quê</th><th>Tarefa</th><th>Duração</th><th>Enviado</th><th>Estado</th></tr></thead>
          <tbody>
            {(data ?? []).map((r) => (
              <tr key={r.id} className="clickable" onClick={() => navigate(`/execucoes/${r.id}`)}>
                <td>{when(r.started_at)}</td>
                <td>{KIND_LABEL[r.kind] ?? r.kind} <span className="small muted">{r.trigger === "schedule" ? "agenda" : "manual"}</span></td>
                <td>{r.job ?? "—"}</td>
                <td className="small">{r.finished_at ? duration(r.summary?.duration_seconds) : "…"}</td>
                <td className="small">{r.kind === "backup" && r.finished_at ? bytes(r.summary?.data_added_packed || r.summary?.data_added) : ""}</td>
                <td><StatusBadge status={r.status} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

type LogLine = { seq: number; ts: string; level: string; line: string };

export function RunDetail() {
  const { id } = useParams();
  const { data: run } = useData<Run>(`/api/runs/${id}`, [id], 3000);
  const [logs, setLogs] = useState<LogLine[]>([]);
  const lastSeq = useRef(-1);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let stopped = false;
    lastSeq.current = -1;
    setLogs([]);
    const load = async () => {
      try {
        const more = await api<LogLine[]>(`/api/runs/${id}/logs?after=${lastSeq.current}`);
        if (!stopped && more.length) {
          lastSeq.current = more[more.length - 1].seq;
          setLogs((prev) => [...prev, ...more]);
          requestAnimationFrame(() => box.current?.scrollTo({ top: box.current.scrollHeight }));
        }
      } catch { /* tenta de novo no próximo ciclo */ }
    };
    load();
    const t = setInterval(load, 2000);
    return () => { stopped = true; clearInterval(t); };
  }, [id]);

  const s = run?.summary ?? {};
  const warnings = (s.warnings as string[] | undefined) ?? [];
  return (
    <>
      <p><Link to="/execucoes">← Execuções</Link></p>
      <div className="row between">
        <h1>{KIND_LABEL[run?.kind ?? ""] ?? run?.kind} {run?.job && `· ${run.job}`}</h1>
        <StatusBadge status={run?.status} />
      </div>
      {run && (
        <div className="card fields">
          <div><div className="muted small">Início</div>{when(run.started_at)}</div>
          <div><div className="muted small">Fim</div>{run.finished_at ? when(run.finished_at) : "rodando…"}</div>
          <div><div className="muted small">Duração</div>{duration(s.duration_seconds)}</div>
          {run.kind === "backup" && <>
            <div><div className="muted small">Snapshot</div><code>{String(s.snapshot_id ?? "—").slice(0, 8)}</code></div>
            <div><div className="muted small">Enviado</div>{bytes(s.data_added_packed || s.data_added)}</div>
            <div><div className="muted small">Arquivos</div>{Number(s.files_new ?? 0)} novos · {Number(s.files_changed ?? 0)} alterados
              · {Number(s.total_files ?? 0).toLocaleString("pt-BR")} no total</div>
            <div><div className="muted small">Tamanho da origem</div>{bytes(s.total_bytes)}</div>
          </>}
          {Array.isArray(s.stopped_stacks) && <div><div className="muted small">Stacks paradas</div>{(s.stopped_stacks as string[]).join(", ")}</div>}
        </div>
      )}
      {run?.error && <div className="notice err"><p>{run.error}</p></div>}
      {typeof s.retention_blocked === "string" && <div className="notice err"><p>Retenção suspensa: {s.retention_blocked}</p></div>}
      {warnings.length > 0 && <div className="notice warn"><ul>{warnings.map((w, i) => <li key={i}>{w}</li>)}</ul></div>}
      <div className="log" ref={box}>
        {logs.length === 0 && <span className="ts">Sem log ainda. Se o agente estiver sem acesso à API, o log chega depois.</span>}
        {logs.map((l) => (
          <div key={l.seq} className={l.level}>
            <span className="ts">{new Date(l.ts).toLocaleTimeString("pt-BR")} </span>{l.line}
          </div>
        ))}
      </div>
    </>
  );
}
