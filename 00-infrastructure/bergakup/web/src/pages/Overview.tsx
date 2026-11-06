import { Link } from "react-router-dom";
import { ago, bytes, duration, KIND_LABEL, sendCommand, when } from "../api";
import { Feedback, NeedAgent, StatusBadge, useAction, useAgent, useData } from "../ui";

type OverviewJob = {
  id: string; name: string; enabled: boolean; schedule: string; dataset: string; dataset_kind: string;
  storage: string; storage_kind: string; agent_id: string; snapshots: number; late: boolean;
  last_success: string | null;
  last_run: { id: string; status: string; started_at: string; finished_at: string | null;
    summary: Record<string, unknown>; error: string | null } | null;
};
type OverviewData = {
  jobs: OverviewJob[];
  recent_runs: { id: string; kind: string; status: string; started_at: string; job: string | null; trigger: string }[];
  unread_notifications: number;
};

const DATASET_HINT: Record<string, string> = {
  userdata: "NAS: fotos e arquivos das pessoas",
  docker: "Repositório, composes e .env",
  servidor: "HD do servidor: appdata e bancos",
};

export default function Overview() {
  const { agent, loaded } = useAgent();
  const { data, reload } = useData<OverviewData>("/api/overview", [], 15_000);
  const discovery = useData<{ info: Record<string, unknown> }>(agent ? `/api/agents/${agent.id}/discovery` : null,
    [agent?.id]);
  const action = useAction();

  if (loaded && !agent) return <><h1>Painel</h1><NeedAgent /></>;

  const warnings = (discovery.data?.info?.warnings as string[] | undefined) ?? [];
  const blocked = (discovery.data?.info?.retention_blocked as Record<string, string> | undefined) ?? {};
  const resticVersion = discovery.data?.info?.restic_version as string | undefined;
  const groups = new Map<string, OverviewJob[]>();
  for (const job of data?.jobs ?? []) groups.set(job.dataset, [...(groups.get(job.dataset) ?? []), job]);

  const runNow = (job: OverviewJob) => action.run(async () => {
    await sendCommand(job.agent_id, "backup", { job_id: job.id });
    setTimeout(reload, 3000);
    return `Backup "${job.name}" pedido ao agente. Acompanhe em Execuções.`;
  });

  return (
    <>
      <h1>Painel</h1>
      {agent && (
        <div className="card row between">
          <div className="row">
            <span className={`dot ${agent.online ? "ok" : "err"}`} />
            <strong>{agent.name}</strong>
            <span className="muted small">{agent.hostname} · agente {agent.version} · visto {ago(agent.last_seen_at)}</span>
          </div>
          <div className="row small">
            {agent.applied_revision === agent.latest_revision
              ? <span className="badge ok">configuração aplicada (rev {agent.applied_revision})</span>
              : <span className="badge warn">aplicando rev {agent.latest_revision} (agente na {agent.applied_revision})</span>}
            {resticVersion === "" && <span className="badge err">restic não instalado</span>}
          </div>
        </div>
      )}
      {agent?.apply_error && <div className="notice err"><p><strong>O agente recusou a configuração:</strong> {agent.apply_error}</p></div>}
      {Object.keys(blocked).length > 0 && (
        <div className="notice err">
          <p><strong>Retenção suspensa por anomalia.</strong> Nada é apagado até você liberar em <Link to="/conjuntos">Conjuntos</Link>.</p>
          <ul>{Object.values(blocked).map((reason, i) => <li key={i}>{reason}</li>)}</ul>
        </div>
      )}
      {warnings.length > 0 && (
        <div className="notice warn">
          <p><strong>Avisos do agente</strong> (veja <Link to="/stacks">Stacks e bancos</Link>):</p>
          <ul>{warnings.slice(0, 5).map((w, i) => <li key={i}>{w}</li>)}</ul>
        </div>
      )}
      {data?.unread_notifications ? (
        <div className="notice info"><p>{data.unread_notifications} alerta(s) não lido(s) em <Link to="/agente">Agente e alertas</Link>.</p></div>
      ) : null}
      <Feedback error={action.error} message={action.message} />

      {data && data.jobs.length === 0 && (
        <div className="notice info">
          <p>Nenhuma tarefa ainda. Comece por <Link to="/destinos">Destinos e chaves</Link> (B2 e NAS), crie os repositórios e
            depois as tarefas em <Link to="/conjuntos">Conjuntos e tarefas</Link>.</p>
        </div>
      )}

      <div className="grid">
        {[...groups.entries()].map(([dataset, jobs]) => (
          <div className="card stack" key={dataset}>
            <div>
              <h2 style={{ margin: 0 }}>{dataset}</h2>
              <div className="muted small">{DATASET_HINT[jobs[0].dataset_kind] ?? ""}</div>
            </div>
            {jobs.map((job) => {
              const s = job.last_run?.summary ?? {};
              return (
                <div key={job.id} className="stack" style={{ gap: 4, borderTop: "1px solid var(--border)", paddingTop: 8 }}>
                  <div className="row between">
                    <strong>{job.storage}</strong>
                    <div className="row">
                      {!job.enabled && <span className="badge">desligada</span>}
                      {job.late && job.enabled && <span className="badge err">atrasada</span>}
                      {blocked[job.id] && <span className="badge err">retenção suspensa</span>}
                      <StatusBadge status={job.last_run?.status} />
                    </div>
                  </div>
                  <div className="muted small">
                    Último sucesso: {when(job.last_success)} · {job.snapshots} snapshot(s) · <code>{job.schedule}</code>
                  </div>
                  {job.last_run && job.last_run.status !== "running" && (
                    <div className="small">
                      {bytes(s.data_added_packed || s.data_added)} enviados · {Number(s.files_new ?? 0)} novos,{" "}
                      {Number(s.files_changed ?? 0)} alterados · {duration(s.duration_seconds)}
                    </div>
                  )}
                  {job.last_run?.error && <div className="small" style={{ color: "var(--err)" }}>{job.last_run.error}</div>}
                  <div className="row">
                    <button disabled={action.busy || !agent?.online} onClick={() => runNow(job)}>Rodar agora</button>
                    {job.last_run && <Link className="small" to={`/execucoes/${job.last_run.id}`}>ver execução</Link>}
                  </div>
                </div>
              );
            })}
          </div>
        ))}
      </div>

      <div className="card">
        <h2>Últimas execuções</h2>
        <div className="scroll-x">
          <table>
            <thead><tr><th>Quando</th><th>O quê</th><th>Tarefa</th><th>Origem</th><th>Estado</th></tr></thead>
            <tbody>
              {(data?.recent_runs ?? []).map((r) => (
                <tr key={r.id} className="clickable" onClick={() => (location.href = `/execucoes/${r.id}`)}>
                  <td>{when(r.started_at)}</td>
                  <td>{KIND_LABEL[r.kind] ?? r.kind}</td>
                  <td>{r.job ?? "—"}</td>
                  <td className="muted">{r.trigger === "schedule" ? "agenda" : "manual"}</td>
                  <td><StatusBadge status={r.status} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
