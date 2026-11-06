export default function Login() {
  const params = new URLSearchParams(location.search);
  const error = params.get("erro");
  const next = params.get("next") || "/";
  return (
    <div className="modal-back" style={{ background: "var(--bg)" }}>
      <div className="modal stack" style={{ maxWidth: 380, textAlign: "center" }}>
        <div className="brand" style={{ padding: 0 }}>berg<span>a</span>kup</div>
        <p className="muted">Backup da Bergatrix</p>
        {error && <div className="notice err">{error}</div>}
        <a href={`/auth/login?next=${encodeURIComponent(next)}`}>
          <button className="primary" style={{ width: "100%" }}>Entrar com o Authentik</button>
        </a>
      </div>
    </div>
  );
}
