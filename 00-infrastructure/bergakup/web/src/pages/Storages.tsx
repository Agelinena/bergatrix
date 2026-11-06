import { useState } from "react";
import { api, ago, Agent, Dataset, Repository, sendCommand, Storage, waitCommand, when } from "../api";
import { randomPassword, seal } from "../seal";
import { Feedback, Field, Modal, NeedAgent, SecretInput, useAction, useAgent, useData } from "../ui";

const KIND_LABEL = { b2: "Backblaze B2 (S3)", local: "Pasta local / NAS montado", rest: "rest-server", sftp: "SFTP" };

const blank = (agentId: string): Omit<Storage, "id" | "has_secret"> => ({
  agent_id: agentId, name: "", kind: "b2", endpoint: "s3.us-west-004.backblazeb2.com", region: "us-west-004",
  bucket: "", path: "", username: "", lock_days: 7,
});

function StorageForm({ agent, storage, onDone }: { agent: Agent; storage: Storage | null; onDone: () => void }) {
  const [form, setForm] = useState<Omit<Storage, "id" | "has_secret">>(storage ?? blank(agent.id));
  const [secret, setSecret] = useState("");
  const action = useAction();
  const set = (key: keyof typeof form, value: string | number) => setForm({ ...form, [key]: value });
  const save = () => action.run(async () => {
    const body = { ...form, secret: secret ? seal(secret, agent.public_key) : null };
    await api(storage ? `/api/storages/${storage.id}` : "/api/storages", storage ? "PUT" : "POST", body);
    setSecret("");
    onDone();
    return "Destino salvo.";
  });
  return (
    <div className="stack">
      <div className="fields">
        <Field label="Nome"><input value={form.name} placeholder="b2-sistema" onChange={(e) => set("name", e.target.value)} /></Field>
        <Field label="Tipo">
          <select value={form.kind} onChange={(e) => set("kind", e.target.value)}>
            {Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
      </div>
      {form.kind === "b2" && (
        <div className="fields">
          <Field label="Endpoint S3" hint="No B2: Buckets → Endpoint"><input value={form.endpoint} onChange={(e) => {
            const m = e.target.value.match(/s3\.([a-z0-9-]+)\.backblazeb2\.com/);
            setForm({ ...form, endpoint: e.target.value, region: m ? m[1] : form.region });
          }} /></Field>
          <Field label="Região"><input value={form.region} onChange={(e) => set("region", e.target.value)} /></Field>
          <Field label="Bucket"><input value={form.bucket} onChange={(e) => set("bucket", e.target.value)} /></Field>
          <Field label="Key ID"><input value={form.username} onChange={(e) => set("username", e.target.value)} /></Field>
          <Field label="Application Key" hint="Cifrada aqui no navegador para o agente">
            <SecretInput value={secret} onChange={setSecret} isSet={!!storage?.has_secret} />
          </Field>
          <Field label="Object Lock (dias)" hint="O mesmo valor configurado no bucket">
            <input type="number" min={0} value={form.lock_days} onChange={(e) => set("lock_days", Number(e.target.value))} />
          </Field>
        </div>
      )}
      {form.kind === "local" && (
        <Field label="Pasta no host" hint="Ex.: /mnt/nas/backups (o NAS precisa estar montado no host)">
          <input value={form.path} onChange={(e) => set("path", e.target.value)} />
        </Field>
      )}
      {form.kind === "rest" && (
        <div className="fields">
          <Field label="Endereço" hint="https://nas.local:8000 (rest-server com --append-only é o ideal)">
            <input value={form.endpoint} onChange={(e) => set("endpoint", e.target.value)} />
          </Field>
          <Field label="Usuário"><input value={form.username} onChange={(e) => set("username", e.target.value)} /></Field>
          <Field label="Senha"><SecretInput value={secret} onChange={setSecret} isSet={!!storage?.has_secret} /></Field>
        </div>
      )}
      {form.kind === "sftp" && (
        <div className="fields">
          <Field label="Host"><input value={form.endpoint} onChange={(e) => set("endpoint", e.target.value)} /></Field>
          <Field label="Usuário"><input value={form.username} onChange={(e) => set("username", e.target.value)} /></Field>
          <Field label="Pasta"><input value={form.path} onChange={(e) => set("path", e.target.value)} /></Field>
        </div>
      )}
      <Feedback error={action.error} message={action.message} />
      <div className="row">
        <button className="primary" disabled={action.busy || !form.name} onClick={save}>Salvar destino</button>
        {storage && <button className="danger right" disabled={action.busy} onClick={() => {
          if (confirm("Remover este destino da configuração?")) {
            action.run(async () => { await api(`/api/storages/${storage.id}`, "DELETE"); onDone(); });
          }
        }}>Remover</button>}
      </div>
    </div>
  );
}

// Criação do repositório: a senha de recuperação nasce aqui, aparece uma
// vez, e vai cifrada para o agente acrescentar como segunda chave.
function InitModal({ agent, repo, onClose }: { agent: Agent; repo: Repository; onClose: () => void }) {
  const [recovery] = useState(randomPassword);
  const [saved, setSaved] = useState(false);
  const action = useAction();
  const start = () => action.run(async () => {
    const { id } = await api<{ id: string }>(`/api/repositories/${repo.id}/init`, "POST",
      { recovery: seal(recovery, agent.public_key) });
    await waitCommand(id, 180_000);
    return "Repositório criado, com a chave de recuperação.";
  });
  return (
    <Modal>
      <h2>Criar o repositório</h2>
      <p><code>{repo.url}</code></p>
      <p>Esta é a <strong>senha de recuperação</strong>. Ela abre o repositório sem o Bergakup, numa recuperação de desastre.
        Ela aparece <strong>só agora</strong>: anote no kit de recuperação impresso ou guarde num cofre fora deste servidor.</p>
      <div className="secret">{recovery}</div>
      <label className="check" style={{ margin: "12px 0" }}>
        <input type="checkbox" checked={saved} onChange={(e) => setSaved(e.target.checked)} />
        Anotei a senha de recuperação fora deste servidor
      </label>
      <Feedback error={action.error} message={action.message} />
      <div className="row">
        {!action.message && <button className="primary" disabled={!saved || action.busy} onClick={start}>
          {action.busy ? "Criando..." : "Criar repositório"}</button>}
        <button onClick={onClose}>{action.message ? "Fechar" : "Cancelar"}</button>
      </div>
    </Modal>
  );
}

function PasswordModal({ agent, repo, onClose }: { agent: Agent; repo: Repository; onClose: () => void }) {
  const [password, setPassword] = useState(randomPassword);
  const action = useAction();
  return (
    <Modal>
      <h2>Senha do repositório</h2>
      <p>É a senha que o agente usa no dia a dia. Ela fica cifrada para o agente e não aparece de novo.
        {repo.initialized_at && <> <strong>O repositório já existe:</strong> digite a senha atual dele, porque trocar aqui não muda a senha no restic.</>}</p>
      <Field label="Senha"><input value={password} onChange={(e) => setPassword(e.target.value)} className="mono" /></Field>
      <Feedback error={action.error} message={action.message} />
      <div className="row" style={{ marginTop: 12 }}>
        <button className="primary" disabled={action.busy || password.length < 12} onClick={() => action.run(async () => {
          await api(`/api/repositories/${repo.id}/password`, "PUT", { password: seal(password, agent.public_key) });
          onClose();
        })}>Salvar</button>
        <button onClick={onClose}>Cancelar</button>
      </div>
    </Modal>
  );
}

function Repositories({ agent, storages }: { agent: Agent; storages: Storage[] }) {
  const repos = useData<Repository[]>(`/api/repositories?agent_id=${agent.id}`, [agent.id]);
  const datasets = useData<Dataset[]>(`/api/datasets?agent_id=${agent.id}`, [agent.id]);
  const [datasetId, setDatasetId] = useState("");
  const [storageId, setStorageId] = useState("");
  const [subpath, setSubpath] = useState("");
  const [modal, setModal] = useState<{ kind: "init" | "password"; repo: Repository } | null>(null);
  const action = useAction();
  const create = () => action.run(async () => {
    await api("/api/repositories", "POST", { dataset_id: datasetId, storage_id: storageId, subpath });
    setSubpath(""); repos.reload();
    return "Repositório adicionado. Defina a senha e crie-o.";
  });
  const command = (kind: string, repo: Repository, msg: string) => action.run(async () => {
    const { id } = await sendCommand(agent.id, kind, { repository_id: repo.id });
    if (kind === "test") {
      await waitCommand(id);
      return `Acesso a ${repo.url} confirmado.`;
    }
    return msg;
  });
  const slug = datasets.data?.find((d) => d.id === datasetId)?.slug;
  return (
    <div className="card stack">
      <h2>Repositórios</h2>
      <p className="muted small">Um repositório restic por conjunto em cada destino. Sugestão: <code>docker</code> e{" "}
        <code>servidor</code> no bucket do sistema (lock de 30 dias) e <code>userdata</code> no bucket próprio (lock de 7 dias),
        mais uma cópia de cada no NAS.</p>
      <Feedback error={action.error || repos.error} message={action.message} />
      <div className="scroll-x">
        <table>
          <thead><tr><th>Conjunto</th><th>Destino</th><th>Endereço</th><th>Estado</th><th></th></tr></thead>
          <tbody>
            {(repos.data ?? []).map((repo) => (
              <tr key={repo.id}>
                <td>{repo.dataset_name}</td>
                <td>{repo.storage_name}{repo.lock_days > 0 && <div className="small muted">lock {repo.lock_days} d</div>}</td>
                <td><code className="small">{repo.url}</code></td>
                <td className="stack" style={{ gap: 4 }}>
                  {!repo.has_password ? <span className="badge err">sem senha</span>
                    : !repo.initialized_at ? <span className="badge warn">não criado</span>
                    : <span className="badge ok">{repo.snapshot_count} snapshots</span>}
                  {repo.initialized_at && !repo.recovery_key_at && <span className="badge warn">sem chave de recuperação</span>}
                  {repo.last_snapshot && <span className="small muted">último {ago(repo.last_snapshot)}</span>}
                </td>
                <td>
                  <div className="row">
                    <button onClick={() => setModal({ kind: "password", repo })}>Senha</button>
                    {repo.has_password && !repo.recovery_key_at && (
                      <button className="primary" onClick={() => setModal({ kind: "init", repo })}>
                        {repo.initialized_at ? "Chave de recuperação" : "Criar"}</button>
                    )}
                    {repo.initialized_at && <>
                      <button disabled={action.busy} onClick={() => command("test", repo, "")}>Testar</button>
                      <button disabled={action.busy} onClick={() => command("prune", repo, "Limpeza pedida. Veja em Execuções.")}>Prune</button>
                    </>}
                    <button className="danger" disabled={action.busy} onClick={() => {
                      if (confirm("Tirar este repositório da configuração? Os dados no destino NÃO são apagados.")) {
                        action.run(async () => { await api(`/api/repositories/${repo.id}`, "DELETE"); repos.reload(); });
                      }
                    }}>Remover</button>
                  </div>
                  {repo.recovery_key_at && <div className="small muted">recuperação desde {when(repo.recovery_key_at)}</div>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <h3>Novo repositório</h3>
      <div className="fields">
        <Field label="Conjunto">
          <select value={datasetId} onChange={(e) => setDatasetId(e.target.value)}>
            <option value="">—</option>
            {(datasets.data ?? []).map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select>
        </Field>
        <Field label="Destino">
          <select value={storageId} onChange={(e) => setStorageId(e.target.value)}>
            <option value="">—</option>
            {storages.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </Field>
        <Field label="Subcaminho" hint={`Padrão: ${slug ?? "o identificador do conjunto"}`}>
          <input value={subpath} placeholder={slug} onChange={(e) => setSubpath(e.target.value)} />
        </Field>
      </div>
      <div><button disabled={!datasetId || !storageId || action.busy} onClick={create}>Adicionar repositório</button></div>
      {modal?.kind === "init" && <InitModal agent={agent} repo={modal.repo} onClose={() => { setModal(null); repos.reload(); }} />}
      {modal?.kind === "password" && <PasswordModal agent={agent} repo={modal.repo} onClose={() => { setModal(null); repos.reload(); }} />}
    </div>
  );
}

export default function Storages() {
  const { agent, loaded } = useAgent();
  const storages = useData<Storage[]>(agent ? `/api/storages?agent_id=${agent.id}` : null, [agent?.id]);
  const [editing, setEditing] = useState<string | "new" | null>(null);
  if (loaded && !agent) return <><h1>Destinos e chaves</h1><NeedAgent /></>;
  if (!agent) return null;
  return (
    <>
      <h1>Destinos e chaves</h1>
      <details className="card">
        <summary><strong>Como preparar o Backblaze B2 (Object Lock e chaves)</strong></summary>
        <ol className="small" style={{ marginTop: 12 }}>
          <li>Crie o bucket <strong>privado</strong>, com <strong>Object Lock ativado</strong>. Primeiro teste em modo <em>Governance</em>,
            depois passe para <em>Compliance</em> (em Compliance ninguém encurta o prazo, nem você).</li>
          <li>Retenção padrão do bucket: 30 dias no bucket do sistema e 7 no do userdata. Use o mesmo valor no campo
            "Object Lock" do destino.</li>
          <li>Lifecycle rule: <em>Keep only the last version</em>. Ela apaga as versões ocultas depois que o lock vence:
            é isso que libera espaço depois do prune.</li>
          <li>Application Key <strong>só deste bucket</strong>, com leitura e escrita, <strong>sem</strong>{" "}
            <code>bypassGovernance</code>. Com Object Lock, essa chave não consegue destruir as versões travadas.</li>
          <li>A Master Key do B2 fica só offline. Ela nunca entra aqui.</li>
        </ol>
        <p className="small muted">O agente usa a API S3 do B2. Com o lock ativo, um "apagar" vira um marcador de ocultação, e a
          versão travada continua recuperável até o lock vencer, mesmo se o servidor for invadido.</p>
      </details>
      <Feedback error={storages.error} />
      <div className="grid">
        {(storages.data ?? []).map((s) => (
          <div className="card stack" key={s.id}>
            <div className="row between">
              <h2 style={{ margin: 0 }}>{s.name}</h2>
              <span className="badge">{KIND_LABEL[s.kind]}</span>
            </div>
            <div className="small muted">
              {s.kind === "b2" ? `${s.bucket} · ${s.region}` : s.path || s.endpoint}
              {s.lock_days > 0 && ` · lock ${s.lock_days} d`}
              {(s.kind === "b2" || s.kind === "rest") && (s.has_secret ? " · chave definida" : " · SEM chave")}
            </div>
            {editing === s.id
              ? <StorageForm agent={agent} storage={s} onDone={() => { setEditing(null); storages.reload(); }} />
              : <div><button onClick={() => setEditing(s.id)}>Editar</button></div>}
          </div>
        ))}
        <div className="card stack">
          {editing === "new"
            ? <><h2>Novo destino</h2><StorageForm agent={agent} storage={null} onDone={() => { setEditing(null); storages.reload(); }} /></>
            : <button onClick={() => setEditing("new")}>Novo destino</button>}
        </div>
      </div>
      <Repositories agent={agent} storages={storages.data ?? []} />
    </>
  );
}
