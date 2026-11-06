import { useState } from "react";
import { Link } from "react-router-dom";
import { bytes, Repository, sendCommand, Snapshot, waitCommand, when } from "../api";
import { Feedback, Field, Modal, NeedAgent, useAction, useAgent, useData } from "../ui";

type Entry = { name: string; type: string; path: string; size: number; mtime: string };

function Browser({ agentId, repo, snapshot }: { agentId: string; repo: Repository; snapshot: Snapshot }) {
  const [path, setPath] = useState<string | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [truncated, setTruncated] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [confirming, setConfirming] = useState(false);
  const [target, setTarget] = useState("");
  const [stopStacks, setStopStacks] = useState(true);
  const action = useAction();

  const open = (dir: string) => action.run(async () => {
    const { id } = await sendCommand(agentId, "ls", { repository_id: repo.id, snapshot_id: snapshot.id, path: dir });
    const result = await waitCommand(id);
    const list = ((result.summary?.entries as Entry[]) ?? []).sort((a, b) =>
      (a.type === "dir" ? 0 : 1) - (b.type === "dir" ? 0 : 1) || a.name.localeCompare(b.name));
    setEntries(list);
    setTruncated(!!result.summary?.truncated);
    setPath(dir);
  });

  const toggle = (p: string) => {
    const next = new Set(selected);
    if (next.has(p)) next.delete(p); else next.add(p);
    setSelected(next);
  };

  const restore = () => action.run(async () => {
    await sendCommand(agentId, "restore", {
      repository_id: repo.id, snapshot_id: snapshot.id, includes: [...selected], target: target.trim(),
      stop_stacks: !target.trim() && stopStacks,
    });
    setConfirming(false);
    return "Restauração pedida ao agente. Acompanhe em Execuções.";
  });

  const parts = (path ?? "").split("/").filter(Boolean);
  return (
    <div className="stack">
      {path === null
        ? <div className="row">
            {snapshot.paths.map((p) => <button key={p} disabled={action.busy} onClick={() => open(p)}>Abrir {p}</button>)}
            <button disabled={action.busy} onClick={() => open("/")}>Abrir /</button>
          </div>
        : <div className="crumbs">
            <button className="link" onClick={() => open("/")}>/</button>
            {parts.map((part, i) => {
              const p = "/" + parts.slice(0, i + 1).join("/");
              return <span key={p}><button className="link" onClick={() => open(p)}>{part}</button> /</span>;
            })}
          </div>}
      {action.busy && <p className="muted">Pedindo ao agente...</p>}
      <Feedback error={action.error} message={action.message} />
      {path !== null && (
        <div className="scroll-x" style={{ maxHeight: 420, overflowY: "auto" }}>
          <table>
            <tbody>
              {entries.map((e) => (
                <tr key={e.path}>
                  <td style={{ width: 28 }}><input type="checkbox" checked={selected.has(e.path)} onChange={() => toggle(e.path)} /></td>
                  <td>
                    {e.type === "dir"
                      ? <button className="link" onClick={() => open(e.path)}>📁 {e.name}</button>
                      : <span>{e.name}</span>}
                  </td>
                  <td className="small muted">{e.type === "dir" ? "" : bytes(e.size)}</td>
                  <td className="small muted">{when(e.mtime)}</td>
                </tr>
              ))}
              {entries.length === 0 && <tr><td className="muted">Pasta vazia.</td></tr>}
            </tbody>
          </table>
          {truncated && <p className="small muted">Mostrando os primeiros 3000 itens.</p>}
        </div>
      )}
      {selected.size > 0 && (
        <div className="card stack" style={{ background: "var(--bg)" }}>
          <strong>{selected.size} item(ns) selecionado(s)</strong>
          <div className="small mono">{[...selected].slice(0, 8).join("\n")}{selected.size > 8 && " …"}</div>
          <Field label="Restaurar em" hint="Vazio = no lugar original, sobrescrevendo. Uma pasta (ex.: /srv/restaurado) = cópia ao lado, sem mexer no que está rodando.">
            <input value={target} placeholder="lugar original" onChange={(e) => setTarget(e.target.value)} />
          </Field>
          {!target.trim() && (
            <label className="check"><input type="checkbox" checked={stopStacks} onChange={(e) => setStopStacks(e.target.checked)} />
              Parar as stacks que usam essas pastas durante a restauração (recomendado)</label>
          )}
          <div><button className="primary" onClick={() => setConfirming(true)}>Restaurar</button></div>
        </div>
      )}
      {confirming && (
        <Modal onClose={() => setConfirming(false)}>
          <h2>Confirmar restauração</h2>
          <p>Snapshot <code>{snapshot.short_id}</code> de {when(snapshot.time)}, {selected.size} item(ns), para{" "}
            <strong>{target.trim() || "o lugar original (sobrescreve os arquivos atuais)"}</strong>.</p>
          {!target.trim() && repo.dataset_slug === "servidor" && (
            <p className="small">Se você restaurou dumps de banco, rode <strong>Importar dumps</strong> depois.</p>
          )}
          <div className="row">
            <button className="primary" disabled={action.busy} onClick={restore}>Restaurar agora</button>
            <button onClick={() => setConfirming(false)}>Cancelar</button>
          </div>
        </Modal>
      )}
    </div>
  );
}

function ImportDumps({ agentId }: { agentId: string }) {
  const [stacks, setStacks] = useState("");
  const action = useAction();
  return (
    <div className="card stack">
      <h2>Importar dumps nos bancos</h2>
      <p className="muted small">Depois de restaurar a pasta de dumps (<code>/srv/appdata/bergakup/dumps</code>), devolve cada dump ao
        seu banco. O agente para os outros containers da stack, importa e sobe de novo. Funciona também para o próprio Bergakup:
        a página cai por alguns segundos e volta.</p>
      <Field label="Stacks (separadas por vírgula; vazio = todas)">
        <input value={stacks} placeholder="authentik, immich" onChange={(e) => setStacks(e.target.value)} />
      </Field>
      <Feedback error={action.error} message={action.message} />
      <div>
        <button disabled={action.busy} onClick={() => {
          const list = stacks.split(",").map((s) => s.trim()).filter(Boolean);
          if (!confirm(`Importar os dumps de ${list.length ? list.join(", ") : "TODAS as stacks"}? Os dados atuais desses bancos são substituídos.`)) return;
          action.run(async () => {
            await sendCommand(agentId, "import_dumps", { stacks: list });
            return "Importação pedida. Acompanhe em Execuções.";
          });
        }}>Importar dumps</button>
      </div>
    </div>
  );
}

export default function Restore() {
  const { agent, loaded } = useAgent();
  const repos = useData<Repository[]>(agent ? `/api/repositories?agent_id=${agent.id}` : null, [agent?.id]);
  const [repoId, setRepoId] = useState("");
  const snapshots = useData<Snapshot[]>(repoId ? `/api/repositories/${repoId}/snapshots` : null, [repoId]);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const action = useAction();
  if (loaded && !agent) return <><h1>Restaurar</h1><NeedAgent /></>;
  if (!agent) return null;
  const repo = repos.data?.find((r) => r.id === repoId);

  const refresh = () => action.run(async () => {
    const { id } = await sendCommand(agent.id, "snapshots", { repository_id: repoId });
    await waitCommand(id);
    snapshots.reload();
  });

  return (
    <>
      <h1>Restaurar</h1>
      <div className="card stack">
        <div className="fields">
          <Field label="Repositório">
            <select value={repoId} onChange={(e) => { setRepoId(e.target.value); setSnapshot(null); }}>
              <option value="">—</option>
              {(repos.data ?? []).filter((r) => r.initialized_at).map((r) =>
                <option key={r.id} value={r.id}>{r.dataset_name} → {r.storage_name}</option>)}
            </select>
          </Field>
        </div>
        {repo && (
          <>
            <div className="row between">
              <span className="muted small">{snapshots.data?.length ?? 0} snapshot(s) em <code>{repo.url}</code></span>
              <button disabled={action.busy} onClick={refresh}>{action.busy ? "Lendo..." : "Atualizar do repositório"}</button>
            </div>
            <Feedback error={action.error || snapshots.error} />
            <div className="scroll-x">
              <table>
                <thead><tr><th>Quando</th><th>ID</th><th>Arquivos</th><th>Tamanho</th><th></th></tr></thead>
                <tbody>
                  {(snapshots.data ?? []).map((s) => (
                    <tr key={s.id} className={snapshot?.id === s.id ? "" : "clickable"} onClick={() => setSnapshot(s)}>
                      <td>{when(s.time)}</td>
                      <td><code>{s.short_id}</code></td>
                      <td className="small">{Number(s.summary?.total_files_processed ?? 0).toLocaleString("pt-BR")}</td>
                      <td className="small">{bytes(s.summary?.total_bytes_processed)}</td>
                      <td>{snapshot?.id === s.id ? <span className="badge info">aberto</span> : null}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>
      {repo && snapshot && (
        <div className="card">
          <h2>Snapshot {snapshot.short_id} · {when(snapshot.time)}</h2>
          <Browser key={snapshot.id} agentId={agent.id} repo={repo} snapshot={snapshot} />
        </div>
      )}
      <ImportDumps agentId={agent.id} />
      <div className="notice info">
        <p>Perdeu o servidor inteiro? A recuperação de desastre não depende desta página: veja o <Link to="/kit">Kit de recuperação</Link>.</p>
      </div>
    </>
  );
}
