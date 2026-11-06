// Interface do claude-sync. Fala só com o app local (/api), sempre com o
// cabeçalho X-Claude-Sync (exigido pelo app em toda ação).

const $ = id => document.getElementById(id);
let status = null;
let editing = false; // não sobrescreve campos enquanto alguém digita
let errorTimer = null;

async function api(path, body) {
    const options = body === undefined
        ? {}
        : { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Claude-Sync': '1' }, body: JSON.stringify(body) };
    const response = await fetch(`/api/${path}`, options);
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || `Falhou (HTTP ${response.status})`);
    return data;
}

function showError(message) {
    const box = $('error');
    box.textContent = message;
    box.hidden = !message;
    clearTimeout(errorTimer);
    if (message) errorTimer = setTimeout(() => { box.hidden = true; }, 8000);
}

async function run(path, body) {
    try {
        const data = await api(path, body ?? {});
        if (data.engine) render(data);
        showError('');
        return data;
    } catch (error) {
        showError(error.message);
        return null;
    }
}

// ── Desenho ──────────────────────────────────────────────────────────

function render(s) {
    status = s;
    $('offline').hidden = true;
    $('version').textContent = `claude-sync ${s.version}`;

    const pill = $('pill');
    let tone = 'idle';
    let text = 'Pausado';
    if (!s.connected) text = 'Falta entrar no Nextcloud';
    else if (!s.active) text = 'Falta ativar a pasta';
    else if (s.engine.lastError) { tone = 'error'; text = 'Sem conexão'; }
    else if (s.engine.syncing) { tone = 'busy'; text = 'Sincronizando…'; }
    else if (s.engine.running) { tone = 'ok'; text = 'Sincronizado'; }
    pill.dataset.tone = tone;
    pill.textContent = text;

    // 1. Nextcloud
    $('login-form').hidden = s.connected || s.login.pending;
    $('login-pending').hidden = !s.login.pending;
    $('login-done').hidden = !s.connected;
    if (s.login.pending) $('login-link').href = s.login.url;
    if (s.login.error) showError(s.login.error);
    if (!editing && !$('server').value) $('server').value = s.server || '';
    $('who-server').textContent = s.server;
    $('who-user').textContent = s.user;
    $('remote-dir').textContent = s.remoteDir;

    // 2. Pasta
    if (!editing) $('sync-dir').value = s.syncDir;
    $('sync-dir').disabled = s.active;
    $('activate').hidden = s.active;
    $('activate').disabled = !s.connected;
    $('folder-active').hidden = !s.active;
    $('restart').hidden = !s.justActivated;
    const other = s.envValue && !s.active;
    $('env-other').hidden = !other;
    if (other) $('env-other').textContent = `Hoje o Claude Code usa outra pasta: ${s.envValue}. Ativar troca para a pasta acima (e copia o que estiver lá).`;

    // 3. Sincronização
    const e = s.engine;
    $('last-sync').textContent = e.lastSync || '—';
    $('count-down').textContent = e.counts.down;
    $('count-up').textContent = e.counts.up;
    $('count-conflicts').textContent = e.counts.conflicts;
    $('sync-error').hidden = !e.lastError;
    $('sync-error').textContent = e.lastError;
    renderProjects(e.projects || [], s);

    // 4. Opções
    if (!editing) {
        renderGlobalItems(s);
        $('interval').value = s.intervalSeconds;
        $('autostart').checked = s.autostart;
        $('pc-name').value = s.pcName;
        $('pc-name').placeholder = s.hostname;
        $('tag').checked = s.tag;
    }
    $('tag-preview').textContent = s.tagLine;

    // Atividade
    const items = (e.activity || []).map(a => {
        const li = document.createElement('li');
        li.dataset.tone = a.tone;
        const time = document.createElement('time');
        time.textContent = a.time;
        const span = document.createElement('span');
        span.textContent = a.text;
        li.append(time, span);
        return li;
    });
    $('activity').replaceChildren(...items);
    $('activity-empty').hidden = items.length > 0;
}

function renderProjects(projects, s) {
    const focused = document.activeElement?.closest?.('.project')?.dataset.key;
    if (focused) return; // alguém está digitando um caminho
    const rows = projects.map(p => {
        const li = $('tpl-project').content.firstElementChild.cloneNode(true);
        li.dataset.key = p.key;
        li.querySelector('.project-key').textContent = p.key;
        const tag = li.querySelector('.tag');
        const local = (p.paths || []).length > 0;
        tag.textContent = local && p.remote ? 'aqui e no Nextcloud' : local ? 'só aqui (sobe na próxima volta)' : 'só no Nextcloud';
        tag.dataset.tone = local && p.remote ? 'ok' : 'wait';
        li.querySelector('.project-paths').textContent = local ? p.paths.join(' · ') : '';
        const linked = s.links?.[p.key];
        const form = li.querySelector('.project-link');
        form.hidden = local && !linked;
        const input = form.querySelector('input');
        input.value = linked || '';
        form.querySelector('button').textContent = linked ? 'Trocar' : 'Vincular';
        form.addEventListener('submit', event => {
            event.preventDefault();
            input.blur();
            run('link', { key: p.key, path: input.value });
        });
        return li;
    });
    $('projects').replaceChildren(...rows);
    $('projects-empty').hidden = rows.length > 0;
}

function renderGlobalItems(s) {
    const labels = {
        'CLAUDE.md': 'CLAUDE.md (instruções globais)',
        agents: 'agents/ (subagentes)',
        commands: 'commands/ (comandos)',
        skills: 'skills/',
        'settings.json': 'settings.json (pode ter caminhos deste PC)',
    };
    const boxes = s.allGlobalItems.map(item => {
        const label = document.createElement('label');
        label.className = 'check';
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.value = item;
        input.checked = s.globalItems.includes(item);
        const span = document.createElement('span');
        span.textContent = labels[item] || item;
        label.append(input, span);
        return label;
    });
    $('global-items').replaceChildren(...boxes);
}

// ── Ações ────────────────────────────────────────────────────────────

$('login-form').addEventListener('submit', async event => {
    event.preventDefault();
    // Abre a aba já no clique (senão o navegador bloqueia) e manda para o login depois.
    const tab = window.open('about:blank', '_blank');
    if (tab) tab.opener = null; // a página do Nextcloud não alcança esta
    try {
        const { url } = await api('login', { server: $('server').value });
        if (tab) tab.location.href = url;
        else window.open(url, '_blank', 'noopener');
        refresh();
    } catch (error) {
        tab?.close();
        showError(error.message);
    }
});

$('folder-form').addEventListener('submit', event => {
    event.preventDefault();
    editing = false;
    run('activate', { syncDir: $('sync-dir').value });
});

$('settings-form').addEventListener('submit', event => {
    event.preventDefault();
    editing = false;
    const globalItems = [...$('global-items').querySelectorAll('input:checked')].map(input => input.value);
    run('settings', {
        globalItems,
        intervalSeconds: Number($('interval').value),
        autostart: $('autostart').checked,
        pcName: $('pc-name').value,
        tag: $('tag').checked,
    });
});

for (const form of ['folder-form', 'settings-form', 'login-form', 'remote-form']) {
    $(form).addEventListener('input', () => { editing = true; });
}

// ── Pasta no Nextcloud ───────────────────────────────────────────────

async function browse(path) {
    const clean = path.replace(/^\/+|\/+$/g, '');
    $('browse-path').textContent = `/${clean}`;
    try {
        const data = await api(`remote-folders?path=${encodeURIComponent(clean)}`);
        const items = [];
        if (clean) {
            const up = clean.includes('/') ? clean.slice(0, clean.lastIndexOf('/')) : '';
            items.push(folderButton('↑ voltar', up, false));
        }
        for (const name of data.folders) {
            const full = clean ? `${clean}/${name}` : name;
            items.push(folderButton(`📁 ${name}`, full, true));
        }
        $('browse-list').replaceChildren(...items);
        $('browse-empty').hidden = data.folders.length > 0;
    } catch (error) {
        showError(error.message);
    }
}

function folderButton(label, path, choose) {
    const li = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.addEventListener('click', () => {
        if (choose) $('remote-input').value = path;
        browse(path);
    });
    li.append(button);
    return li;
}

$('remote-form').addEventListener('submit', async event => {
    event.preventDefault();
    const path = $('remote-input').value.trim();
    const move = $('remote-move').checked;
    const question = move
        ? `Mover tudo de "${status.remoteDir}" para "${path}" no Nextcloud?`
        : `Passar a usar "${path}"? A pasta "${status.remoteDir}" fica como está, e os outros PCs continuam nela até você trocar lá também.`;
    if (!confirm(question)) return;
    editing = false;
    if (await run('remote-dir', { path, move })) $('remote-form').hidden = true;
});

const actions = {
    'remote-edit': () => {
        $('remote-form').hidden = false;
        $('remote-input').value = status.remoteDir;
        const parent = status.remoteDir.includes('/') ? status.remoteDir.slice(0, status.remoteDir.lastIndexOf('/')) : '';
        browse(parent);
    },
    'remote-cancel': () => { $('remote-form').hidden = true; editing = false; },
    'login-cancel': () => run('login/cancel'),
    logout: () => confirm('Desconectar? A senha de app é revogada no Nextcloud e apagada deste PC. A pasta local fica.') && run('logout'),
    deactivate: () => confirm('Desativar? O Claude Code volta a usar a pasta padrão (~/.claude) depois de reabrir. A pasta sincronizada fica onde está.') && run('deactivate'),
    'open-folder': () => run('open-folder'),
    sync: () => run('sync'),
    quit: async () => {
        if (!confirm('Fechar o app? A sincronização para até você abrir de novo.')) return;
        await run('quit');
        $('pill').textContent = 'Fechado';
        $('pill').dataset.tone = 'idle';
    },
};

document.addEventListener('click', event => {
    const button = event.target.closest('[data-action]');
    if (button) actions[button.dataset.action]?.();
});

// ── Atualização ──────────────────────────────────────────────────────

async function refresh() {
    try {
        render(await api('status'));
    } catch {
        $('offline').hidden = false;
        $('pill').textContent = 'Fechado';
        $('pill').dataset.tone = 'error';
    }
}

refresh();
setInterval(refresh, 2000);
