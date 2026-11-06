import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ago, api, when } from "../api";
import { seal } from "../seal";
import { Feedback, Field, SecretInput, useAction, useAgent, useData } from "../ui";

type Settings = {
  timezone: string; repo_root: string; stacks_file: string; dumps_dir: string;
  smtp: { host: string; port: number; username: string; sender: string; to: string[]; security: string };
  has_smtp_password: boolean;
};
type Notification = { id: string; level: string; title: string; body: string; run_id: string | null; created_at: string; read: boolean };
type Audit = { ts: string; action: string; detail: Record<string, unknown>; username: string | null };

function Install({ reinstall }: { reinstall: boolean }) {
  const [code, setCode] = useState<string | null>(null);
  const action = useAction();
  return (
    <div className="card stack">
      <h2>{reinstall ? "Reinstalar o agente" : "Instalar o agente"}</h2>
      <p className="muted small">O agente roda no host da VM Docker, como serviço do systemd. Ele executa tudo: dumps, backup,
        restauração e e-mails. Esta interface só configura.</p>
      <ol className="small">
        <li>No servidor: <code>cd ~/bergatrix/00-infrastructure/bergakup/agent && ./build.sh && sudo ./install.sh</code></li>
        <li>Gere um código (vale 1 hora, uso único) e registre:</li>
      </ol>
      {code
        ? <div className="secret">sudo bergakup-agent enroll {reinstall && "--force "}--code {code} --name servidor --repo-root ~/bergatrix</div>
        : <div><button className="primary" disabled={action.busy} onClick={() => action.run(async () => {
            const r = await api<{ code: string }>("/api/agents/enrollment-code", "POST");
            setCode(r.code);
          })}>Gerar código de instalação</button></div>}
      <ol className="small" start={3}><li><code>sudo systemctl enable --now bergakup-agent</code></li></ol>
      {reinstall && <p className="small" style={{ color: "var(--warn)" }}>Reinstalar com uma chave nova apaga os segredos
        guardados (eles foram cifrados para a chave antiga). Digite-os de novo depois. Na recuperação de desastre, restaure
        o /etc/bergakup em vez de reinstalar.</p>}
      <Feedback error={action.error} />
    </div>
  );
}

function SettingsForm({ agentId, publicKey }: { agentId: string; publicKey: string }) {
  const { data, reload } = useData<Settings>(`/api/agents/${agentId}/settings`, [agentId]);
  const [form, setForm] = useState<Settings | null>(null);
  const [to, setTo] = useState("");
  const [password, setPassword] = useState("");
  const action = useAction();
  useEffect(() => { if (data) { setForm(data); setTo(data.smtp.to.join(", ")); } }, [data]);
  if (!form) return null;
  const smtp = form.smtp;
  const setSmtp = (key: keyof Settings["smtp"], value: string | number) => setForm({ ...form, smtp: { ...smtp, [key]: value } });
  const save = () => action.run(async () => {
    await api(`/api/agents/${agentId}/settings`, "PUT", {
      ...form,
      smtp: { ...smtp, to: to.split(",").map((s) => s.trim()).filter(Boolean) },
      smtp_password: password ? seal(password, publicKey) : null,
    });
    setPassword(""); reload();
    return "Salvo.";
  });
  return (
    <div className="card stack">
      <h2>Caminhos e e-mail</h2>
      <div className="fields">
        <Field label="Repositório bergatrix no host"><input value={form.repo_root} onChange={(e) => setForm({ ...form, repo_root: e.target.value })} /></Field>
        <Field label="stacks.txt (ordem de parar e subir)"><input value={form.stacks_file} onChange={(e) => setForm({ ...form, stacks_file: e.target.value })} /></Field>
        <Field label="Pasta dos dumps"><input value={form.dumps_dir} onChange={(e) => setForm({ ...form, dumps_dir: e.target.value })} /></Field>
        <Field label="Fuso das agendas"><input value={form.timezone} onChange={(e) => setForm({ ...form, timezone: e.target.value })} /></Field>
      </div>
      <h3>E-mail de falha</h3>
      <p className="muted small">Enviado pelo próprio agente: chega mesmo com esta interface fora do ar.</p>
      <div className="fields">
        <Field label="Servidor SMTP"><input value={smtp.host} placeholder="smtp.exemplo.com" onChange={(e) => setSmtp("host", e.target.value)} /></Field>
        <Field label="Porta"><input type="number" value={smtp.port} onChange={(e) => setSmtp("port", Number(e.target.value))} /></Field>
        <Field label="Segurança">
          <select value={smtp.security} onChange={(e) => setSmtp("security", e.target.value)}>
            <option value="starttls">STARTTLS (587)</option><option value="tls">TLS (465)</option><option value="none">Nenhuma</option>
          </select>
        </Field>
        <Field label="Usuário"><input value={smtp.username} onChange={(e) => setSmtp("username", e.target.value)} /></Field>
        <Field label="Senha"><SecretInput value={password} onChange={setPassword} isSet={form.has_smtp_password} /></Field>
        <Field label="Remetente"><input value={smtp.sender} onChange={(e) => setSmtp("sender", e.target.value)} /></Field>
        <Field label="Para (vírgula)"><input value={to} onChange={(e) => setTo(e.target.value)} /></Field>
      </div>
      <Feedback error={action.error} message={action.message} />
      <div><button className="primary" disabled={action.busy} onClick={save}>Salvar</button></div>
    </div>
  );
}

function Notifications() {
  const { data, reload } = useData<Notification[]>("/api/notifications", [], 30_000);
  const unread = (data ?? []).filter((n) => !n.read).length;
  return (
    <div className="card stack">
      <div className="row between">
        <h2 style={{ margin: 0 }}>Alertas</h2>
        {unread > 0 && <button onClick={() => api("/api/notifications/read", "POST").then(reload)}>Marcar {unread} como lidos</button>}
      </div>
      {(data ?? []).length === 0 && <p className="muted">Nenhum alerta.</p>}
      {(data ?? []).slice(0, 50).map((n) => (
        <div key={n.id} className={`notice ${n.level === "error" ? "err" : n.level === "warning" ? "warn" : "info"}`}
          style={{ opacity: n.read ? 0.6 : 1, marginBottom: 0 }}>
          <div className="row between"><strong>{n.title}</strong><span className="small">{when(n.created_at)}</span></div>
          {n.body && <p className="small" style={{ whiteSpace: "pre-wrap" }}>{n.body}</p>}
          {n.run_id && <Link className="small" to={`/execucoes/${n.run_id}`}>ver execução</Link>}
        </div>
      ))}
    </div>
  );
}

function AuditLog() {
  const { data } = useData<Audit[]>("/api/audit");
  return (
    <details className="card">
      <summary><strong>Auditoria</strong> <span className="muted small">quem mudou o quê</span></summary>
      <div className="scroll-x" style={{ marginTop: 12 }}>
        <table>
          <tbody>
            {(data ?? []).map((a, i) => (
              <tr key={i}>
                <td className="small">{when(a.ts)}</td>
                <td className="small">{a.username ?? "—"}</td>
                <td className="small"><code>{a.action}</code></td>
                <td className="small muted mono">{Object.keys(a.detail).length ? JSON.stringify(a.detail).slice(0, 160) : ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </details>
  );
}

export default function AgentPage() {
  const { agent, loaded } = useAgent();
  if (!loaded) return null;
  return (
    <>
      <h1>Agente e alertas</h1>
      {agent && (
        <div className="card fields">
          <div><div className="muted small">Agente</div><span className={`dot ${agent.online ? "ok" : "err"}`} /> {agent.name} ({agent.hostname})</div>
          <div><div className="muted small">Versão</div>{agent.version || "—"}</div>
          <div><div className="muted small">Visto</div>{ago(agent.last_seen_at)}</div>
          <div><div className="muted small">Configuração</div>rev {agent.applied_revision} de {agent.latest_revision}</div>
        </div>
      )}
      {agent?.apply_error && <div className="notice err"><p>{agent.apply_error}</p></div>}
      <Notifications />
      {agent && <SettingsForm agentId={agent.id} publicKey={agent.public_key} />}
      {agent ? <details><summary className="muted">Reinstalar o agente</summary><Install reinstall /></details> : <Install reinstall={false} />}
      <AuditLog />
    </>
  );
}
