import { useEffect, useState } from "react";
import { api, Dataset, Job, Repository, sendCommand } from "../api";
import { Feedback, Field, lines, NeedAgent, useAction, useAgent, useData } from "../ui";

const CONSISTENCY = {
  none: "Só copiar os arquivos",
  policies: "Dumps dos bancos + política de cada stack",
  cold: "Dumps + parar todas as stacks durante a cópia (backup frio)",
};

function DatasetForm({ dataset, onSaved }: { dataset: Dataset; onSaved: () => void }) {
  const [name, setName] = useState(dataset.name);
  const [paths, setPaths] = useState(dataset.paths.join("\n"));
  const [excludes, setExcludes] = useState(dataset.excludes.join("\n"));
  const [consistency, setConsistency] = useState(dataset.consistency);
  const action = useAction();
  const save = () => action.run(async () => {
    await api(`/api/datasets/${dataset.id}`, "PUT", {
      agent_id: dataset.agent_id, slug: dataset.slug, name, kind: dataset.kind,
      paths: lines(paths), excludes: lines(excludes), consistency,
    });
    onSaved();
    return "Salvo. O agente aplica em até 30 s.";
  });
  const remove = () => {
    if (!confirm(`Remover o conjunto "${dataset.name}" da configuração? Os snapshots no destino continuam lá.`)) return;
    action.run(async () => { await api(`/api/datasets/${dataset.id}`, "DELETE"); onSaved(); });
  };
  return (
    <div className="stack">
      <div className="fields">
        <Field label="Nome"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Consistência">
          <select value={consistency} onChange={(e) => setConsistency(e.target.value as Dataset["consistency"])}>
            {Object.entries(CONSISTENCY).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
      </div>
      <div className="fields" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))" }}>
        <Field label="Pastas (uma por linha)"><textarea value={paths} onChange={(e) => setPaths(e.target.value)} /></Field>
        <Field label="Excluir (padrões do restic, um por linha)" hint="Ex.: /srv/appdata/*/postgres, **/node_modules">
          <textarea value={excludes} onChange={(e) => setExcludes(e.target.value)} />
        </Field>
      </div>
      {consistency !== "none" && (
        <p className="muted small">
          Antes da cópia, o agente faz o dump de todo banco com a label <code>bergatrix.backup.dump</code>. As pastas vivas dos
          bancos ficam excluídas: eles entram pelos dumps. A política de cada stack fica em Stacks e bancos.
        </p>
      )}
      <Feedback error={action.error} message={action.message} />
      <div className="row">
        <button className="primary" disabled={action.busy} onClick={save}>Salvar conjunto</button>
        <button className="danger right" disabled={action.busy} onClick={remove}>Remover</button>
      </div>
    </div>
  );
}

const emptyJob = (repo: Repository): Omit<Job, "id"> => ({
  repository_id: repo.id,
  name: `${repo.dataset_slug} → ${repo.storage_name}`,
  enabled: true,
  schedule: repo.dataset_slug === "userdata" ? "0 2 * * *" : "0 3 * * *",
  retention: repo.storage_kind === "b2" ? { daily: 3, weekly: 4 } : { daily: 7, weekly: 4, monthly: 6 },
  prune_schedule: "30 4 * * 0",
  check_schedule: "0 6 1 * *",
  check_subset: "5%",
  anomaly_pct: 30,
  stale_hours: 26,
  ping_url: "",
});

function JobForm({ repo, job, agentId, blocked, onSaved }: {
  repo: Repository; job: Job | null; agentId: string; blocked?: string; onSaved: () => void;
}) {
  const [form, setForm] = useState<Omit<Job, "id">>(job ?? emptyJob(repo));
  useEffect(() => { setForm(job ?? emptyJob(repo)); }, [job, repo]);
  const action = useAction();
  const set = <K extends keyof Omit<Job, "id">>(key: K, value: Omit<Job, "id">[K]) => setForm({ ...form, [key]: value });
  const setRet = (key: "last" | "daily" | "weekly" | "monthly", value: string) =>
    setForm({ ...form, retention: { ...form.retention, [key]: Number(value) || 0 } });

  const save = () => action.run(async () => {
    await api(job ? `/api/jobs/${job.id}` : "/api/jobs", job ? "PUT" : "POST", form);
    onSaved();
    return job ? "Tarefa salva." : "Tarefa criada.";
  });
  const command = (kind: string, params: Record<string, unknown>, msg: string) =>
    action.run(async () => { await sendCommand(agentId, kind, params); return msg; });

  const r = form.retention;
  const keepDays = (r.daily ?? 0) + (r.weekly ?? 0) * 7 + (r.monthly ?? 0) * 30;
  return (
    <div className="stack">
      {!repo.initialized_at && <div className="notice warn"><p>Repositório ainda não criado: inicialize em Destinos e chaves.</p></div>}
      {blocked && (
        <div className="notice err">
          <p><strong>Retenção suspensa:</strong> {blocked}. Confira o último snapshot em Restaurar. Se a mudança foi legítima, libere.</p>
          <button disabled={action.busy} onClick={() => command("unlock", { job_id: job!.id, repository_id: repo.id },
            "Liberação pedida. A retenção volta no próximo backup.")}>Liberar retenção</button>
        </div>
      )}
      <div className="fields">
        <Field label="Nome"><input value={form.name} onChange={(e) => set("name", e.target.value)} /></Field>
        <Field label="Agenda do backup (cron)" hint="0 3 * * * = todo dia às 3h">
          <input value={form.schedule} onChange={(e) => set("schedule", e.target.value)} />
        </Field>
        <label className="check"><input type="checkbox" checked={form.enabled}
          onChange={(e) => set("enabled", e.target.checked)} /> Tarefa ligada</label>
      </div>
      <h3>Retenção</h3>
      <div className="fields">
        <Field label="Diários"><input type="number" min={0} value={r.daily ?? 0} onChange={(e) => setRet("daily", e.target.value)} /></Field>
        <Field label="Semanais"><input type="number" min={0} value={r.weekly ?? 0} onChange={(e) => setRet("weekly", e.target.value)} /></Field>
        <Field label="Mensais"><input type="number" min={0} value={r.monthly ?? 0} onChange={(e) => setRet("monthly", e.target.value)} /></Field>
        <Field label="Últimos N (qualquer data)"><input type="number" min={0} value={r.last ?? 0} onChange={(e) => setRet("last", e.target.value)} /></Field>
      </div>
      <p className="muted small">
        Cada backup só envia o que mudou. Snapshots a mais custam quase nada quando pouca coisa muda: o custo vem do volume
        alterado. Janela de volta no tempo: ~{keepDays} dias
        {repo.lock_days > 0 && <> (+ {repo.lock_days} dias de Object Lock: o que a retenção descarta continua guardado e cobrado até o lock vencer)</>}.
      </p>
      <details>
        <summary>Avançado: limpeza, verificação e alertas</summary>
        <div className="fields" style={{ marginTop: 12 }}>
          <Field label="Limpeza / prune (cron)" hint="Libera o espaço do que a retenção descartou">
            <input value={form.prune_schedule} onChange={(e) => set("prune_schedule", e.target.value)} />
          </Field>
          <Field label="Verificação (cron)"><input value={form.check_schedule} onChange={(e) => set("check_schedule", e.target.value)} /></Field>
          <Field label="Verificar quanto dos dados" hint="5% lê uma amostra; 100% lê tudo (baixa do B2)">
            <input value={form.check_subset} onChange={(e) => set("check_subset", e.target.value)} />
          </Field>
          <Field label="Anomalia (%)" hint="Mudou ou sumiu mais que isso: suspende a retenção">
            <input type="number" min={0} max={100} value={form.anomaly_pct} onChange={(e) => set("anomaly_pct", Number(e.target.value))} />
          </Field>
          <Field label="Atrasada depois de (horas)"><input type="number" min={1} value={form.stale_hours}
            onChange={(e) => set("stale_hours", Number(e.target.value))} /></Field>
          <Field label="Ping externo (opcional)" hint="Healthchecks: avisa até se o agente morrer">
            <input value={form.ping_url} placeholder="https://hc-ping.com/..." onChange={(e) => set("ping_url", e.target.value)} />
          </Field>
        </div>
      </details>
      <Feedback error={action.error} message={action.message} />
      <div className="row">
        <button className="primary" disabled={action.busy} onClick={save}>{job ? "Salvar tarefa" : "Criar tarefa"}</button>
        {job && <>
          <button disabled={action.busy} onClick={() => command("backup", { job_id: job.id }, "Backup pedido. Veja em Execuções.")}>Rodar agora</button>
          <button disabled={action.busy} onClick={() => command("forget", { job_id: job.id }, "Retenção pedida.")}>Aplicar retenção</button>
          <button disabled={action.busy} onClick={() => command("check", { repository_id: repo.id, subset: form.check_subset }, "Verificação pedida.")}>Verificar</button>
          <button className="danger right" disabled={action.busy} onClick={() => {
            if (confirm("Remover a tarefa? Os snapshots continuam no destino.")) {
              action.run(async () => { await api(`/api/jobs/${job.id}`, "DELETE"); onSaved(); });
            }
          }}>Remover</button>
        </>}
      </div>
    </div>
  );
}

function NewDataset({ agentId, onSaved }: { agentId: string; onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const [slug, setSlug] = useState("");
  const [name, setName] = useState("");
  const [paths, setPaths] = useState("");
  const action = useAction();
  if (!open) return <button onClick={() => setOpen(true)}>Novo conjunto</button>;
  return (
    <div className="card stack">
      <h2>Novo conjunto</h2>
      <div className="fields">
        <Field label="Identificador" hint="minúsculas e hífen; vira o caminho do repositório"><input value={slug} onChange={(e) => setSlug(e.target.value)} /></Field>
        <Field label="Nome"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
      </div>
      <Field label="Pastas (uma por linha)"><textarea value={paths} onChange={(e) => setPaths(e.target.value)} /></Field>
      <Feedback error={action.error} />
      <div className="row">
        <button className="primary" disabled={action.busy} onClick={() => action.run(async () => {
          await api("/api/datasets", "POST", { agent_id: agentId, slug, name, kind: "custom", paths: lines(paths),
            excludes: [], consistency: "none" });
          setOpen(false); onSaved();
        })}>Criar</button>
        <button onClick={() => setOpen(false)}>Cancelar</button>
      </div>
    </div>
  );
}

export default function Datasets() {
  const { agent, loaded } = useAgent();
  const id = agent?.id;
  const datasets = useData<Dataset[]>(id ? `/api/datasets?agent_id=${id}` : null, [id]);
  const repos = useData<Repository[]>(id ? `/api/repositories?agent_id=${id}` : null, [id]);
  const jobs = useData<Job[]>(id ? `/api/jobs?agent_id=${id}` : null, [id]);
  const discovery = useData<{ info: Record<string, unknown> }>(id ? `/api/agents/${id}/discovery` : null, [id], 30_000);
  if (loaded && !agent) return <><h1>Conjuntos e tarefas</h1><NeedAgent /></>;
  const blocked = (discovery.data?.info?.retention_blocked as Record<string, string> | undefined) ?? {};
  const reloadAll = () => { datasets.reload(); repos.reload(); jobs.reload(); };

  return (
    <>
      <div className="row between"><h1>Conjuntos e tarefas</h1>{id && <NewDataset agentId={id} onSaved={reloadAll} />}</div>
      <p className="muted">
        Um conjunto é o que entra no backup. Cada conjunto vai para um ou mais destinos (um repositório restic em cada), e cada
        repositório tem uma tarefa com agenda e retenção.
      </p>
      <Feedback error={datasets.error || repos.error || jobs.error} />
      {(datasets.data ?? []).map((ds) => {
        const dsRepos = (repos.data ?? []).filter((r) => r.dataset_id === ds.id);
        return (
          <div className="card stack" key={ds.id}>
            <div className="row between">
              <h2 style={{ margin: 0 }}>{ds.name}</h2>
              <code className="muted">{ds.slug}</code>
            </div>
            <DatasetForm dataset={ds} onSaved={reloadAll} />
            {dsRepos.length === 0 && (
              <div className="notice info"><p>Sem destino ainda. Crie um repositório deste conjunto em Destinos e chaves.</p></div>
            )}
            {dsRepos.map((repo) => {
              const job = (jobs.data ?? []).find((j) => j.repository_id === repo.id) ?? null;
              return (
                <div key={repo.id} className="card" style={{ background: "var(--bg)" }}>
                  <div className="row between" style={{ marginBottom: 8 }}>
                    <h3 style={{ margin: 0 }}>→ {repo.storage_name}</h3>
                    <code className="small muted">{repo.url}</code>
                  </div>
                  <JobForm repo={repo} job={job} agentId={id!} blocked={job ? blocked[job.id] : undefined} onSaved={reloadAll} />
                </div>
              );
            })}
          </div>
        );
      })}
    </>
  );
}
