import { NavLink, Route, Routes, useLocation } from "react-router-dom";
import { api } from "./api";
import { AgentProvider, useData } from "./ui";
import Overview from "./pages/Overview";
import Datasets from "./pages/Datasets";
import Storages from "./pages/Storages";
import Stacks from "./pages/Stacks";
import Restore from "./pages/Restore";
import Runs, { RunDetail } from "./pages/Runs";
import AgentPage from "./pages/Agent";
import Kit from "./pages/Kit";
import Login from "./pages/Login";

function Nav() {
  const { data } = useData<{ unread_notifications: number }>("/api/overview", [], 60_000);
  const unread = data?.unread_notifications ?? 0;
  const logout = async () => {
    await api("/auth/logout", "POST").catch(() => {});
    location.assign("/login");
  };
  return (
    <nav className="nav">
      <div className="brand">berg<span>a</span>kup</div>
      <NavLink to="/" end>Painel {unread > 0 && <span className="badge err">{unread}</span>}</NavLink>
      <NavLink to="/conjuntos">Conjuntos e tarefas</NavLink>
      <NavLink to="/destinos">Destinos e chaves</NavLink>
      <NavLink to="/stacks">Stacks e bancos</NavLink>
      <NavLink to="/restaurar">Restaurar</NavLink>
      <NavLink to="/execucoes">Execuções</NavLink>
      <NavLink to="/agente">Agente e alertas</NavLink>
      <NavLink to="/kit">Kit de recuperação</NavLink>
      <div className="spacer" />
      <button className="link" onClick={logout}>Sair</button>
    </nav>
  );
}

export default function App() {
  const location = useLocation();
  if (location.pathname === "/login") return <Login />;
  return (
    <AgentProvider>
      <div className="shell">
        <Nav />
        <main className="main">
          <Routes>
            <Route path="/" element={<Overview />} />
            <Route path="/conjuntos" element={<Datasets />} />
            <Route path="/destinos" element={<Storages />} />
            <Route path="/stacks" element={<Stacks />} />
            <Route path="/restaurar" element={<Restore />} />
            <Route path="/execucoes" element={<Runs />} />
            <Route path="/execucoes/:id" element={<RunDetail />} />
            <Route path="/agente" element={<AgentPage />} />
            <Route path="/kit" element={<Kit />} />
            <Route path="*" element={<p>Página não encontrada.</p>} />
          </Routes>
        </main>
      </div>
    </AgentProvider>
  );
}
