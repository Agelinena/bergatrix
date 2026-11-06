import { Repository, when } from "../api";
import { NeedAgent, useAgent, useData } from "../ui";

type KitData = {
  agent: { name: string; hostname: string };
  repo_root: string;
  dumps_dir: string;
  datasets: { slug: string; name: string; paths: string[] }[];
  repositories: (Repository & { region: string; endpoint: string; bucket: string; username: string })[];
};

const ORDER = ["docker", "servidor", "userdata"];

export default function Kit() {
  const { agent, loaded } = useAgent();
  const { data } = useData<KitData>(agent ? `/api/kit?agent_id=${agent.id}` : null, [agent?.id]);
  if (loaded && !agent) return <><h1>Kit de recuperação</h1><NeedAgent /></>;
  if (!data) return null;
  const repos = [...data.repositories].sort((a, b) =>
    (ORDER.indexOf(a.dataset_slug) + 99) % 99 - (ORDER.indexOf(b.dataset_slug) + 99) % 99);

  return (
    <>
      <div className="row between no-print">
        <h1>Kit de recuperação</h1>
        <button className="primary" onClick={() => print()}>Imprimir</button>
      </div>
      <div className="notice warn no-print">
        <p>Imprima e guarde fora de casa. As senhas de recuperação <strong>não</strong> aparecem aqui: elas foram mostradas uma
          vez, quando cada repositório foi criado. Escreva-as à mão nas linhas do papel. Guarde o papel junto com o acesso à conta
          do Backblaze (a Master Key também fica só offline).</p>
      </div>

      <div className="card kit">
        <h2>Bergakup: recuperação de desastre</h2>
        <p className="small">Agente: {data.agent.name} ({data.agent.hostname}) · impresso em {when(new Date().toISOString())}</p>
        <p className="small">Funciona sem a interface web. Precisa de: uma VM Ubuntu com Docker, este papel, e uma Application Key
          nova do B2 (crie no painel do Backblaze, com leitura e escrita só deste bucket: o restic grava arquivos de lock).</p>
        <ol className="small">
          <li>Na VM nova, clone o repositório público bergatrix e rode <code>00-infrastructure/bergakup/agent/build.sh</code> e{" "}
            <code>sudo ./install.sh</code> (instala o restic e o agente). Monte o NAS e o /srv como antes (docs/02-armazenamento.md).</li>
          <li><code>sudo bergakup-agent recover</code> e restaure, nesta ordem:
            <strong> docker</strong> (repositório, .env, /etc/bergakup), <strong>servidor</strong> (/srv/appdata e dumps). No fim, deixe o
            programa rodar o <code>subir-tudo.sh</code> e importar os dumps.</li>
          <li><code>sudo systemctl enable --now bergakup-agent</code>. O Bergakup volta com o histórico.</li>
          <li>Por último, o <strong>userdata</strong> (centenas de GB): pela interface ou pelo <code>recover</code>.</li>
        </ol>
        <p className="small">Sem o agente, só com o restic: <code>export RESTIC_REPOSITORY=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…</code>,
          depois <code>restic snapshots</code> e <code>restic restore latest --target /</code>.</p>

        {repos.map((r) => (
          <div key={r.id} className="card" style={{ marginTop: 12 }}>
            <h3>{r.dataset_name} → {r.storage_name}</h3>
            <table>
              <tbody>
                <tr><th>Repositório</th><td><code>{r.url}</code></td></tr>
                {r.storage_kind === "b2" && <>
                  <tr><th>Bucket / região</th><td>{r.bucket} · {r.region}</td></tr>
                  <tr><th>Object Lock</th><td>{r.lock_days} dias</td></tr>
                </>}
                <tr><th>Pastas</th><td className="small">{data.datasets.find((d) => d.slug === r.dataset_slug)?.paths.join(", ")}</td></tr>
                <tr><th>Chave de recuperação</th><td>{r.recovery_key_at ? `criada em ${when(r.recovery_key_at)}` : "NÃO CRIADA: crie em Destinos e chaves"}</td></tr>
                <tr><th>Senha de recuperação</th><td><div className="line" /></td></tr>
              </tbody>
            </table>
          </div>
        ))}
        <p className="small" style={{ marginTop: 12 }}>Ransomware ou exclusão: com Object Lock, as versões apagadas continuam no B2 até o
          lock vencer. Para voltar o bucket a uma data, liste as versões no painel do B2 (ou use o rclone com --b2-versions) e
          restaure com o restic a partir delas. Não rode prune enquanto investiga.</p>
      </div>
    </>
  );
}
