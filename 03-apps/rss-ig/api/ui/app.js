"use strict";

// ── Helpers ────────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);

async function api(method, path, body) {
  const opts = { method, headers: { "Content-Type": "application/json" } };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  if (r.status === 204) return null;
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new Error(data?.detail || `HTTP ${r.status}`);
  return data;
}

function fmtBytes(n) {
  if (!n) return "0 B";
  const u = ["B","KB","MB","GB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function fmtDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso + (iso.endsWith("Z") ? "" : "Z"));
  return d.toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
}

function statusBadge(status) {
  if (!status) return '<span class="badge badge-pending">—</span>';
  if (status === "ok")      return '<span class="badge badge-ok">ok</span>';
  if (status === "running") return '<span class="badge badge-running spin-wrap">⟳ running</span>';
  if (status.startsWith("error")) {
    const detail = status.replace("error:", "") || "error";
    return `<span class="badge badge-error" title="${detail}">erro</span>`;
  }
  return `<span class="badge badge-pending">${status}</span>`;
}

// ── Confirm dialog ─────────────────────────────────────────────────────────
const dlg = $("dlg-confirm");
let _dlgResolve = null;

function confirm(msg) {
  $("dlg-msg").textContent = msg;
  dlg.showModal();
  return new Promise(res => { _dlgResolve = res; });
}

$("dlg-cancel").onclick = () => { dlg.close(); _dlgResolve && _dlgResolve(false); };
$("dlg-ok").onclick     = () => { dlg.close(); _dlgResolve && _dlgResolve(true);  };

// ── Stats ──────────────────────────────────────────────────────────────────
async function loadStats() {
  try {
    const s = await api("GET", "/api/stats");
    $("stat-profiles").textContent  = s.profile_count;
    $("stat-posts").textContent     = s.post_count;
    $("stat-storage").textContent   = fmtBytes(s.total_storage_bytes);
    $("stat-last-fetch").textContent = fmtDate(s.last_fetch_at);
  } catch (e) {
    console.error("stats:", e);
  }
}

// ── Profiles table ─────────────────────────────────────────────────────────
async function loadProfiles() {
  const tbody = $("profiles-body");
  let profiles;
  try {
    profiles = await api("GET", "/api/profiles");
  } catch (e) {
    console.error("profiles:", e);
    return;
  }

  // Remove all rows except the #row-empty placeholder
  [...tbody.querySelectorAll("tr:not(#row-empty)")].forEach(r => r.remove());

  if (!profiles.length) {
    $("row-empty").classList.remove("hidden");
    return;
  }
  $("row-empty").classList.add("hidden");

  for (const p of profiles) {
    const tr = document.createElement("tr");
    tr.dataset.username = p.username;
    tr.innerHTML = `
      <td>
        <div class="td-username">
          <a href="https://instagram.com/${p.username}" target="_blank" rel="noopener">
            @${p.username}
          </a>
        </div>
      </td>
      <td>${statusBadge(p.last_fetch_status)}</td>
      <td>${fmtDate(p.last_fetch_at)}</td>
      <td>${p.post_count ?? 0}</td>
      <td>${fmtBytes(p.storage_bytes)}</td>
      <td>
        <div class="actions">
          <a href="/feeds/${p.username}.xml" target="_blank" class="btn btn-ghost btn-sm" title="Ver feed RSS">RSS</a>
          <button class="btn btn-ghost btn-sm btn-fetch" data-u="${p.username}" title="Fetch manual agora">⬇ Fetch</button>
          <button class="btn btn-danger btn-sm btn-remove" data-u="${p.username}" title="Remover perfil">✕</button>
        </div>
      </td>
    `;
    tbody.appendChild(tr);
  }

  // Bind action buttons
  tbody.querySelectorAll(".btn-fetch").forEach(btn => {
    btn.onclick = () => triggerFetch(btn.dataset.u, btn);
  });
  tbody.querySelectorAll(".btn-remove").forEach(btn => {
    btn.onclick = () => removeProfile(btn.dataset.u);
  });
}

// ── Manual fetch ───────────────────────────────────────────────────────────
async function triggerFetch(username, btn) {
  btn.disabled = true;
  btn.textContent = "⟳";
  try {
    await api("POST", `/api/profiles/${username}/fetch`);
    // Poll status until no longer running
    pollStatus(username, btn);
  } catch (e) {
    alert(`Erro ao enfileirar fetch: ${e.message}`);
    btn.disabled = false;
    btn.textContent = "⬇ Fetch";
  }
}

function pollStatus(username, btn) {
  let attempts = 0;
  const MAX = 120; // up to ~2 min polling

  const iv = setInterval(async () => {
    attempts++;
    if (attempts > MAX) { clearInterval(iv); resetBtn(btn); return; }

    try {
      const p = await api("GET", `/api/profiles/${username}`);
      const row = document.querySelector(`tr[data-username="${username}"]`);
      if (row) {
        row.cells[1].innerHTML = statusBadge(p.last_fetch_status);
        row.cells[2].textContent = fmtDate(p.last_fetch_at);
        row.cells[3].textContent = p.post_count ?? 0;
        row.cells[4].textContent = fmtBytes(p.storage_bytes);
      }

      if (p.last_fetch_status !== "running") {
        clearInterval(iv);
        resetBtn(btn);
        loadStats();
      }
    } catch {
      clearInterval(iv);
      resetBtn(btn);
    }
  }, 5000);
}

function resetBtn(btn) {
  btn.disabled = false;
  btn.textContent = "⬇ Fetch";
}

// ── Remove profile ─────────────────────────────────────────────────────────
async function removeProfile(username) {
  const ok = await confirm(
    `Remover @${username}? Todos os posts e arquivos de mídia serão deletados.`
  );
  if (!ok) return;

  try {
    await api("DELETE", `/api/profiles/${username}`);
    loadProfiles();
    loadStats();
  } catch (e) {
    alert(`Erro ao remover: ${e.message}`);
  }
}

// ── Add profile form ───────────────────────────────────────────────────────
$("form-add").onsubmit = async e => {
  e.preventDefault();
  const input = $("input-username");
  const errEl = $("add-error");
  const username = input.value.trim().replace(/^@/, "").toLowerCase();

  errEl.classList.add("hidden");
  if (!username) return;

  const btn = e.target.querySelector("button[type=submit]");
  btn.disabled = true;

  try {
    await api("POST", "/api/profiles", { username });
    input.value = "";
    loadProfiles();
    loadStats();
  } catch (e) {
    errEl.textContent = e.message;
    errEl.classList.remove("hidden");
  } finally {
    btn.disabled = false;
  }
};

// ── Refresh button ─────────────────────────────────────────────────────────
$("btn-refresh").onclick = () => { loadStats(); loadProfiles(); };

// ── Auto-refresh every 30 s ────────────────────────────────────────────────
setInterval(() => { loadStats(); loadProfiles(); }, 30_000);

// ── Init ───────────────────────────────────────────────────────────────────
loadStats();
loadProfiles();
