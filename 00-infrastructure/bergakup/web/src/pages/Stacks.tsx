import { useEffect, useState } from "react";
import { api, ago, sendCommand, waitCommand } from "../api";
import { Feedback, NeedAgent, useAction, useAgent, useData } from "../ui";

type Container = { name: string; service: string; image: string; running: boolean; health?: string; dump?: string };
type Discovery = {
  info: {
    stacks?: { name: string; containers: Container[] }[];
    dumps?: { stack: string; container: string; kind: string; running: boolean; files?: string[]; problem?: string }[];
    warnings?: string[];
    stacks_order?: string[];
    updated_at?: string;
    docker_error?: string;
  };
  policies: Record<string, string>;
};

const MODES: Record<string, string> = {
  hot: "Copiar rodando",
  stop: "Parar durante a cópia",
  pause: "Pausar durante a cópia",
  skip: "Fora do backup",
};

export default function Stacks() {
  const { agent, loaded } = useAgent();
  const { data, reload, error } = useData<Discovery>(agent ? `/api/agents/${agent.id}/discovery` : null, [agent?.id]);
  const [policies, setPolicies] = useState<Record<string, string>>({});
  const action = useAction();
  useEffect(() => { if (data) setPolicies(data.policies); }, [data]);
  if (loaded && !agent) return <><h1>Stacks e bancos</h1><NeedAgent /></>;
  if (!agent) return null;

  const info = data?.info ?? {};
  const order = info.stacks_order ?? [];
  const stacks = [...(info.stacks ?? [])].sort((a, b) => {
    const ia = order.indexOf(a.name), ib = order.indexOf(b.name);
    return (ia < 0 ? 999 : ia) - (ib < 0 ? 999 : ib) || a.name.localeCompare(b.name);
  });
  const dumpsByStack = new Map<string, NonNullable<Discovery["info"]["dumps"]>>();
  for (const d of info.dumps ?? []) dumpsByStack.set(d.stack, [...(dumpsByStack.get(d.stack) ?? []), d]);

  const save = () => action.run(async () => {
    await api(`/api/agents/${agent.id}/policies`, "PUT", { policies });
    reload();
    return "Políticas salvas.";
  });
  const refresh = () => action.run(async () => {
    const { id } = await sendCommand(agent.id, "discover");
    await waitCommand(id);
    reload();
    return "Atualizado.";
  });

  return (
    <>
      <div className="row between">
        <h1>Stacks e bancos</h1>
        <button disabled={action.busy} onClick={refresh}>Atualizar agora</button>
      </div>
      <p className="muted">
        O que o agente encontrou no Docker ({ago(info.updated_at)}). A política vale para os conjuntos com consistência "dumps +
        política" (o do servidor). Bancos entram pelo dump: coloque a label no compose do banco, como
        em <code>bergatrix.backup.dump=postgres</code>, ou <code>sqlite</code> com <code>bergatrix.backup.sqlite=/data/db.sqlite3</code>.
      </p>
      <Feedback error={error || action.error || info.docker_error} message={action.message} />
      {(info.warnings ?? []).length > 0 && (
        <div className="notice warn">
          <p><strong>Atenção</strong></p>
          <ul>{info.warnings!.map((w, i) => <li key={i}>{w}</li>)}</ul>
        </div>
      )}
      <div className="card scroll-x">
        <table>
          <thead><tr><th>Stack</th><th>Containers</th><th>Dumps</th><th>Durante o backup</th></tr></thead>
          <tbody>
            {stacks.map((s) => (
              <tr key={s.name}>
                <td>
                  <strong>{s.name}</strong>
                  {order.includes(s.name) ? <div className="small muted">#{order.indexOf(s.name) + 1} no stacks.txt</div>
                    : <div className="small muted">fora do stacks.txt</div>}
                </td>
                <td className="small">
                  {s.containers.map((c) => (
                    <div key={c.name}>
                      <span className={`dot ${c.running ? "ok" : ""}`} /> {c.name}
                      {c.health && c.health !== "healthy" && <span className="badge warn"> {c.health}</span>}
                    </div>
                  ))}
                </td>
                <td className="small">
                  {(dumpsByStack.get(s.name) ?? []).map((d) => (
                    <div key={d.container}>
                      <span className={`badge ${d.problem ? "err" : "ok"}`}>{d.kind}</span> {d.container}
                      {d.problem && <div style={{ color: "var(--err)" }}>{d.problem}</div>}
                    </div>
                  ))}
                  {!dumpsByStack.get(s.name) && <span className="muted">—</span>}
                </td>
                <td>
                  <select value={policies[s.name] ?? "hot"}
                    onChange={(e) => setPolicies({ ...policies, [s.name]: e.target.value })}>
                    {Object.entries(MODES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                  </select>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="muted small">
        "Parar" dá a cópia mais segura para apps com SQLite em uso (Jellyfin, *arr, Home Assistant), ao custo de alguns minutos fora
        do ar de madrugada. Com o LVM no /srv, essa parada cai para segundos (snapshot do disco).
      </p>
      <button className="primary" disabled={action.busy} onClick={save}>Salvar políticas</button>
    </>
  );
}
