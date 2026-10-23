// Interface do Transcriptor.
import { api, ApiError, setUnauthorizedHandler, uploadFile } from './api.js';
import { bytes, clock, duration, h, highlighted, svgIcon, when } from './dom.js';

const THEME_KEY = 'transcriptor:theme';
const ACTIVE = ['queued', 'downloading', 'preparing', 'transcribing'];
const STATUS = {
    uploading: 'Enviando',
    queued: 'Na fila',
    downloading: 'Baixando',
    preparing: 'Preparando o áudio',
    transcribing: 'Transcrevendo',
    done: 'Pronto',
    failed: 'Falhou',
    canceled: 'Cancelado',
};

const WORKER_STATES = {
    starting: 'iniciando',
    preparing: 'preparando modelos',
    ready: 'pronto',
    busy: 'transcrevendo',
    error: 'com erro',
};

const state = {
    me: null,
    config: null,
    jobs: new Map(),
    uploads: new Map(),
    query: '',
    route: { view: 'home', id: null },
    detail: null,
    eta: new Map(),
    events: null,
    listTimer: null,
};

const $app = document.getElementById('app');
let refs = {};

// ── Início ───────────────────────────────────────────────────────────

setUnauthorizedHandler(() => {
    if (state.me) location.reload();
});

async function start() {
    initTheme();
    try {
        state.me = await api('/api/me');
    } catch (error) {
        if (error.status === 401) {
            renderLogin();
            return;
        }
        renderFatal(error.message);
        return;
    }
    state.config = await api('/api/config');
    renderShell();
    await loadJobs();
    connectEvents();
    window.addEventListener('hashchange', route);
    window.addEventListener('beforeunload', event => {
        if ([...state.uploads.values()].some(upload => !upload.error)) event.preventDefault();
    });
    setInterval(refreshConfig, 60_000);
    route();
    $app.removeAttribute('aria-busy');
}

async function refreshConfig() {
    try {
        state.config = await api('/api/config');
        renderWorkerBanner();
    } catch { /* tenta no próximo minuto */ }
}

// ── Tema ─────────────────────────────────────────────────────────────

function initTheme() {
    let saved = null;
    try {
        saved = localStorage.getItem(THEME_KEY);
    } catch { /* sem storage */ }
    const dark = saved ? saved === 'dark' : window.matchMedia?.('(prefers-color-scheme: dark)').matches;
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}

function themeIcon() {
    return document.documentElement.dataset.theme === 'dark' ? '☀' : '☾';
}

function toggleTheme() {
    const dark = document.documentElement.dataset.theme !== 'dark';
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    try {
        localStorage.setItem(THEME_KEY, dark ? 'dark' : 'light');
    } catch { /* sem storage */ }
}

// ── Login ────────────────────────────────────────────────────────────

function renderLogin() {
    const params = new URLSearchParams(location.search);
    const error = params.get('erro');
    if (error) history.replaceState(null, '', '/' + location.hash);
    const next = location.pathname + location.hash;
    $app.removeAttribute('aria-busy');
    $app.replaceChildren(h('main', { class: 'login' },
        h('div', { class: 'login-card' },
            brand(),
            h('h1', {}, 'Transcrição de áudio e vídeo, ', h('em', {}, 'no seu servidor.')),
            h('p', { class: 'lede' }, 'Envie um arquivo ou cole um link. O Whisper transcreve na GPU da Bergatrix, e o áudio não sai de casa.'),
            error && h('p', { class: 'notice notice--error', role: 'alert' }, error),
            h('a', { class: 'button button--primary button--large', href: `/auth/login?next=${encodeURIComponent(next)}` },
                'Entrar com o Authentik'),
            h('p', { class: 'hint' }, 'O acesso é liberado pelo grupo transcriptor_users no Authentik.'))));
}

function renderFatal(message) {
    $app.removeAttribute('aria-busy');
    $app.replaceChildren(h('main', { class: 'login' }, h('div', { class: 'login-card' }, brand(),
        h('p', { class: 'notice notice--error' }, message || 'O servidor não respondeu.'),
        h('button', { class: 'button', type: 'button', onclick: () => location.reload() }, 'Tentar de novo'))));
}

function brand() {
    return h('a', { class: 'brand', href: '#/' },
        h('img', { src: '/assets/icon.svg', alt: '', width: 30, height: 30 }),
        h('span', {}, 'transcriptor'));
}

// ── Estrutura ────────────────────────────────────────────────────────

function renderShell() {
    const search = h('input', {
        class: 'search-input', type: 'search', placeholder: 'Buscar nas transcrições', 'aria-label': 'Buscar nas transcrições',
        oninput: event => {
            state.query = event.target.value.trim();
            clearTimeout(state.listTimer);
            state.listTimer = setTimeout(async () => {
                await loadJobs();
                if (state.detail) renderDetail();
            }, 250);
        },
    });
    refs = {
        search,
        list: h('ul', { class: 'job-list', 'aria-label': 'Transcrições' }),
        uploads: h('ul', { class: 'upload-list', 'aria-label': 'Envios em andamento' }),
        main: h('main', { class: 'main', id: 'main', tabindex: '-1' }),
        banner: h('div', { class: 'banner-slot' }),
    };
    $app.replaceChildren(
        h('header', { class: 'topbar' },
            brand(),
            h('label', { class: 'search' }, svgIcon('search'), search),
            h('div', { class: 'topbar-actions' },
                h('button', { class: 'icon-button theme-button', type: 'button', title: 'Alternar tema', 'aria-label': 'Alternar tema',
                    onclick: event => {
                        toggleTheme();
                        event.currentTarget.textContent = themeIcon();
                    } }, themeIcon()),
                h('a', { class: 'account-button', href: '#/conta', title: 'Conta e tokens' },
                    h('span', { class: 'avatar', 'aria-hidden': 'true' }, initials(state.me.name || state.me.username)),
                    h('span', { class: 'account-name' }, state.me.name || state.me.username)))),
        refs.banner,
        h('div', { class: 'layout' },
            h('aside', { class: 'sidebar', 'aria-label': 'Biblioteca' },
                h('div', { class: 'sidebar-head' },
                    h('h2', {}, 'Biblioteca'),
                    h('a', { class: 'button button--primary button--small', href: '#/nova' }, svgIcon('plus'), 'Nova')),
                refs.uploads,
                refs.list),
            refs.main));
    renderWorkerBanner();
}

function initials(name) {
    return name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => part[0].toUpperCase()).join('') || '?';
}

function renderWorkerBanner() {
    const config = state.config;
    const missing = config.models.filter(model => !model.ready);
    let message = null;
    if (!config.worker_alive) {
        message = 'O processador (GPU) está fora do ar. As transcrições ficam na fila até ele voltar.';
    } else if (missing.length === config.models.length) {
        message = 'O processador está preparando os modelos. As primeiras transcrições começam assim que terminar.';
    }
    refs.banner.replaceChildren(message ? h('p', { class: 'banner', role: 'status' }, message) : '');
}

function route() {
    const hash = location.hash.replace(/^#/, '');
    const [, view, id] = hash.split('/');
    if (view === 't' && id) state.route = { view: 'job', id };
    else if (view === 'nova') state.route = { view: 'new', id: null };
    else if (view === 'conta') state.route = { view: 'account', id: null };
    else state.route = { view: 'home', id: null };
    document.body.dataset.view = state.route.view;
    renderList();
    if (state.route.view === 'job') openJob(state.route.id);
    else if (state.route.view === 'account') renderAccount();
    else {
        state.detail = null;
        renderNew();
    }
}

// ── Lista ────────────────────────────────────────────────────────────

async function loadJobs() {
    try {
        const data = await api(`/api/jobs?q=${encodeURIComponent(state.query)}`);
        state.jobs = new Map(data.jobs.map(job => [job.id, job]));
        renderList();
    } catch (error) {
        if (error.status !== 401) toast(error.message);
    }
}

function renderList() {
    if (!refs.list) return;
    const jobs = [...state.jobs.values()].sort((a, b) => b.created_at.localeCompare(a.created_at));
    if (!jobs.length) {
        refs.list.replaceChildren(h('li', { class: 'empty' },
            state.query ? 'Nada encontrado para essa busca.' : 'Nenhuma transcrição ainda. Comece em “Nova”.'));
        return;
    }
    refs.list.replaceChildren(...jobs.map(job => {
        const active = state.route.view === 'job' && state.route.id === job.id;
        return h('li', {},
            h('a', { class: `job-item${active ? ' is-active' : ''}`, href: `#/t/${job.id}`, 'aria-current': active ? 'page' : null },
                h('span', { class: 'job-item-title' }, job.title),
                h('span', { class: 'job-item-meta' },
                    statusChip(job),
                    h('span', {}, [duration(job.duration_seconds), when(job.created_at)].filter(Boolean).join(' · '))),
                ACTIVE.includes(job.status) && progressBar(job)));
    }));
    paintBars();
}

function statusChip(job) {
    const progress = ['downloading', 'transcribing'].includes(job.status) && job.progress > 0
        ? ` ${Math.round(job.progress * 100)}%` : '';
    return h('span', { class: `chip chip--${job.status}` }, STATUS[job.status] + progress);
}

function progressBar(job) {
    const indeterminate = ['queued', 'preparing'].includes(job.status) || !job.progress;
    return h('span', { class: `bar${indeterminate ? ' bar--indeterminate' : ''}`, role: 'progressbar',
        'aria-valuemin': 0, 'aria-valuemax': 100, 'aria-valuenow': indeterminate ? null : Math.round(job.progress * 100) },
        h('span', { class: 'bar-fill', style: null, dataset: {} }));
}

function paintBars() {
    for (const bar of document.querySelectorAll('.bar[aria-valuenow]')) {
        bar.firstChild.style.width = `${bar.getAttribute('aria-valuenow')}%`;
    }
}

// ── Eventos ──────────────────────────────────────────────────────────

function connectEvents() {
    const source = new EventSource('/api/events');
    state.events = source;
    let pending = false;
    source.onmessage = async event => {
        let data;
        try {
            data = JSON.parse(event.data);
        } catch {
            return;
        }
        if (data.type === 'resync') {
            await loadJobs();
            if (state.detail) await refreshDetail(true);
            return;
        }
        if (data.deleted) {
            state.jobs.delete(data.id);
            if (state.route.id === data.id) location.hash = '#/';
            renderList();
            return;
        }
        const known = state.jobs.get(data.id);
        if (!known) {
            if (!pending) {
                pending = true;
                setTimeout(async () => {
                    pending = false;
                    await loadJobs();
                }, 400);
            }
            return;
        }
        const changed = known.status !== data.status;
        known.status = data.status;
        known.progress = data.progress;
        trackEta(known);
        if (changed) {
            const fresh = await api(`/api/jobs/${data.id}?segments=false`).catch(() => null);
            if (fresh) state.jobs.set(data.id, { ...known, ...fresh });
        }
        renderList();
        paintBars();
        if (state.detail?.job.id === data.id) {
            state.detail.job = { ...state.detail.job, ...state.jobs.get(data.id) };
            await refreshDetail(changed);
        }
    };
}

function trackEta(job) {
    if (job.status !== 'transcribing' || !job.progress) {
        state.eta.delete(job.id);
        return;
    }
    const sample = state.eta.get(job.id);
    if (!sample) state.eta.set(job.id, { time: Date.now(), progress: job.progress, rate: null });
    else if (job.progress > sample.progress) {
        sample.rate = (job.progress - sample.progress) / ((Date.now() - sample.time) / 1000);
    }
}

function etaText(job) {
    const sample = state.eta.get(job.id);
    if (!sample?.rate || job.progress < 0.03) return '';
    const seconds = (1 - job.progress) / sample.rate;
    return seconds > 30 ? `faltam ~${duration(seconds)}` : 'quase pronto';
}

// ── Nova transcrição ─────────────────────────────────────────────────

function renderNew() {
    const config = state.config;
    let mode = 'file';
    const files = [];
    const fileList = h('ul', { class: 'picked-files' });
    const fileInput = h('input', { type: 'file', multiple: true, class: 'visually-hidden', accept: 'audio/*,video/*',
        onchange: event => {
            files.push(...event.target.files);
            event.target.value = '';
            renderPicked();
        } });
    const urlInput = h('input', { class: 'input', type: 'url', placeholder: 'https://www.youtube.com/watch?v=…', inputmode: 'url',
        autocomplete: 'off', 'aria-label': 'Link do vídeo ou áudio' });
    const model = h('div', { class: 'model-options', role: 'radiogroup', 'aria-label': 'Modelo' },
        config.models.map(option => h('label', { class: 'model-option' },
            h('input', { type: 'radio', name: 'model', value: option.id, checked: option.id === config.default_model }),
            h('span', { class: 'model-body' },
                h('span', { class: 'model-label' }, option.label,
                    !option.ready && h('span', { class: 'chip chip--queued' }, 'preparando')),
                h('span', { class: 'model-description' }, option.description)))));
    const language = h('select', { class: 'input', 'aria-label': 'Idioma' },
        h('option', { value: '' }, 'Detectar automaticamente'),
        config.languages.map(item => h('option', { value: item.id, selected: item.id === 'pt' }, item.label)));
    const prompt = h('textarea', { class: 'input', rows: 2, maxlength: 600,
        placeholder: 'Ex.: Bergatrix, Authentik, Jellyfin, nomes das pessoas que falam' });
    const error = h('p', { class: 'field-error', role: 'alert' });
    const submit = h('button', { class: 'button button--primary button--large', type: 'submit' }, 'Transcrever');
    const dropzone = h('label', { class: 'dropzone' }, fileInput, svgIcon('upload'),
        h('b', {}, 'Escolher arquivos'),
        h('span', {}, `ou arraste para cá · áudio ou vídeo · até ${bytes(config.max_upload_bytes)} e ${duration(config.max_duration_minutes * 60)}`));
    for (const type of ['dragenter', 'dragover']) {
        dropzone.addEventListener(type, event => {
            event.preventDefault();
            dropzone.classList.add('is-over');
        });
    }
    dropzone.addEventListener('dragleave', () => dropzone.classList.remove('is-over'));
    dropzone.addEventListener('drop', event => {
        event.preventDefault();
        dropzone.classList.remove('is-over');
        files.push(...event.dataTransfer.files);
        renderPicked();
    });

    function renderPicked() {
        fileList.replaceChildren(...files.map((file, index) => h('li', {},
            h('span', { class: 'picked-name' }, file.name),
            h('span', { class: 'picked-size' }, bytes(file.size)),
            h('button', { class: 'icon-button icon-button--small', type: 'button', 'aria-label': `Tirar ${file.name}`,
                onclick: () => {
                    files.splice(index, 1);
                    renderPicked();
                } }, svgIcon('close')))));
    }

    const panels = {
        file: h('div', { class: 'panel' }, dropzone, fileList),
        url: h('div', { class: 'panel', hidden: true },
            h('label', { class: 'label' }, 'Link do YouTube ou de outro site, ou link direto para um arquivo de mídia', urlInput)),
    };
    const tabs = h('div', { class: 'segmented', role: 'tablist' },
        [['file', 'Arquivo', 'upload'], ['url', 'Link', 'link']].map(([id, label, icon]) => h('button', {
            type: 'button', role: 'tab', class: 'segmented-option', 'aria-selected': String(id === mode),
            onclick: event => {
                mode = id;
                for (const button of tabs.children) button.setAttribute('aria-selected', String(button === event.currentTarget));
                panels.file.hidden = mode !== 'file';
                panels.url.hidden = mode !== 'url';
                error.textContent = '';
            } }, svgIcon(icon), label)));

    const form = h('form', { class: 'new-form', novalidate: true, onsubmit: async event => {
        event.preventDefault();
        error.textContent = '';
        const options = {
            model: form.querySelector('input[name=model]:checked')?.value,
            language: language.value || null,
            prompt: prompt.value.trim(),
        };
        if (mode === 'url') {
            if (!urlInput.value.trim()) {
                error.textContent = 'Cole um link.';
                return;
            }
            submit.disabled = true;
            try {
                const job = await api('/api/jobs', { method: 'POST', body: { ...options, url: urlInput.value.trim() } });
                state.jobs.set(job.id, job);
                location.hash = `#/t/${job.id}`;
            } catch (failure) {
                error.textContent = failure.message;
            } finally {
                submit.disabled = false;
            }
            return;
        }
        if (!files.length) {
            error.textContent = 'Escolha pelo menos um arquivo.';
            return;
        }
        const tooBig = files.find(file => file.size > config.max_upload_bytes);
        if (tooBig) {
            error.textContent = `“${tooBig.name}” passa do limite de ${bytes(config.max_upload_bytes)}.`;
            return;
        }
        for (const file of files.splice(0)) startUpload(file, options);
        renderPicked();
        toast('Enviando. Você pode continuar usando o Transcriptor enquanto isso.');
    } },
    tabs, panels.file, panels.url,
    h('fieldset', { class: 'fieldset' }, h('legend', { class: 'label' }, 'Modelo'), model),
    h('div', { class: 'form-row' },
        h('label', { class: 'label' }, 'Idioma do áudio', language)),
    h('details', { class: 'details' },
        h('summary', {}, 'Vocabulário (opcional)'),
        h('p', { class: 'hint' }, 'Nomes e termos que aparecem no áudio. Ajuda o modelo a escrever certo.'),
        prompt),
    error, submit);

    refs.main.replaceChildren(h('section', { class: 'view view-new', 'aria-labelledby': 'new-title' },
        h('div', { class: 'view-head' },
            h('a', { class: 'back-link', href: '#/' }, svgIcon('back'), 'Biblioteca'),
            h('h1', { id: 'new-title' }, 'Nova transcrição')),
        form,
        h('p', { class: 'footnote' }, retentionText())));
}

function retentionText() {
    const { retention_days: days, audio_days: audio } = state.config;
    const keep = days > 0 ? `As transcrições ficam guardadas por ${days} dias.` : 'As transcrições ficam guardadas até você apagar.';
    return `${keep} O áudio fica ${audio} dias para você ouvir junto com o texto; o arquivo original é apagado assim que a transcrição termina.`;
}

function startUpload(file, options) {
    const key = crypto.randomUUID();
    const controller = new AbortController();
    const upload = { name: file.name, progress: 0, error: null, controller };
    state.uploads.set(key, upload);
    renderUploads();
    uploadFile(file, options, value => {
        upload.progress = value;
        renderUploads();
    }, controller.signal).then(job => {
        state.uploads.delete(key);
        state.jobs.set(job.id, job);
        renderUploads();
        renderList();
    }).catch(error => {
        if (error.status === -1) state.uploads.delete(key);
        else upload.error = error.message;
        renderUploads();
    });
}

function renderUploads() {
    refs.uploads.replaceChildren(...[...state.uploads.entries()].map(([key, upload]) => h('li', { class: 'upload-item' },
        h('span', { class: 'upload-name' }, upload.name),
        upload.error
            ? h('span', { class: 'field-error' }, upload.error)
            : h('span', { class: 'bar', role: 'progressbar', 'aria-valuenow': Math.round(upload.progress * 100),
                'aria-valuemin': 0, 'aria-valuemax': 100 }, h('span', { class: 'bar-fill' })),
        h('button', { class: 'icon-button icon-button--small', type: 'button', 'aria-label': 'Cancelar envio',
            onclick: () => {
                if (upload.error) state.uploads.delete(key);
                else upload.controller.abort();
                renderUploads();
            } }, svgIcon('close')))));
    paintBars();
}

// ── Detalhe ──────────────────────────────────────────────────────────

async function openJob(id) {
    refs.main.replaceChildren(h('div', { class: 'loading' }, 'Carregando…'));
    let data;
    try {
        data = await api(`/api/jobs/${id}`);
    } catch (error) {
        refs.main.replaceChildren(h('section', { class: 'view' },
            h('a', { class: 'back-link', href: '#/' }, svgIcon('back'), 'Biblioteca'),
            h('p', { class: 'notice notice--error' }, error.message)));
        return;
    }
    const { segments, ...job } = data;
    state.jobs.set(job.id, { ...state.jobs.get(job.id), ...job });
    state.detail = { job, segments, mode: state.detail?.mode ?? 'segments', loading: false, editing: null };
    renderDetail();
    refs.main.focus({ preventScroll: true });
}

async function refreshDetail(full = false) {
    const detail = state.detail;
    if (!detail || detail.loading) return;
    detail.loading = true;
    try {
        const last = detail.segments.at(-1)?.idx ?? -1;
        if (full || detail.job.status === 'transcribing' || detail.job.status === 'done') {
            const data = await api(`/api/jobs/${detail.job.id}/segments?after=${full ? -1 : last}`);
            detail.segments = full ? data.segments : detail.segments.concat(data.segments);
        }
    } catch { /* tenta no próximo aviso */ } finally {
        detail.loading = false;
    }
    if (state.detail === detail) renderDetail();
}

function renderDetail() {
    const { job, segments } = state.detail;
    const audio = job.has_audio && job.status === 'done'
        ? h('audio', { class: 'player', controls: true, preload: 'metadata', src: `/api/jobs/${job.id}/audio` })
        : null;
    if (audio) {
        audio.addEventListener('timeupdate', () => markPlaying(audio.currentTime * 1000));
    }
    const seek = segment => {
        if (!audio) return;
        audio.currentTime = segment.start_ms / 1000;
        audio.play().catch(() => {});
    };

    const header = h('div', { class: 'detail-head' },
        h('a', { class: 'back-link', href: '#/' }, svgIcon('back'), 'Biblioteca'),
        titleEditor(job),
        h('p', { class: 'detail-meta' }, [
            job.duration_seconds && duration(job.duration_seconds),
            modelLabel(job.model),
            languageLabel(job.detected_language || job.language),
            job.source_kind === 'url' ? 'link' : bytes(job.source_bytes),
            when(job.created_at),
        ].filter(Boolean).join(' · ')),
        job.source_url && h('a', { class: 'source-link', href: job.source_url, target: '_blank', rel: 'noopener noreferrer' }, job.source_url));

    refs.main.replaceChildren(h('section', { class: 'view view-detail', 'aria-labelledby': 'detail-title' },
        header,
        statusPanel(job),
        actions(job),
        audio,
        segments.length ? transcript(job, segments, seek) : emptyTranscript(job)));
    paintBars();
}

function titleEditor(job) {
    const title = h('h1', { id: 'detail-title', class: 'detail-title' }, job.title);
    const button = h('button', { class: 'text-button', type: 'button', onclick: () => {
        const input = h('input', { class: 'input title-input', value: job.title, maxlength: 200, 'aria-label': 'Título' });
        const save = async () => {
            const value = input.value.trim();
            if (value && value !== job.title) {
                try {
                    const updated = await api(`/api/jobs/${job.id}`, { method: 'PATCH', body: { title: value } });
                    job.title = updated.title;
                    state.jobs.set(job.id, { ...state.jobs.get(job.id), title: updated.title });
                    renderList();
                } catch (error) {
                    toast(error.message);
                }
            }
            renderDetail();
        };
        input.addEventListener('keydown', event => {
            if (event.key === 'Enter') save();
            if (event.key === 'Escape') renderDetail();
        });
        input.addEventListener('blur', save);
        wrapper.replaceChildren(input);
        input.focus();
        input.select();
    } }, 'Renomear');
    const wrapper = h('div', { class: 'title-row' }, title, button);
    return wrapper;
}

function modelLabel(id) {
    return state.config.models.find(model => model.id === id)?.label ?? id;
}

function languageLabel(id) {
    if (!id) return 'idioma automático';
    return state.config.languages.find(item => item.id === id)?.label ?? id;
}

function statusPanel(job) {
    if (job.status === 'done') return null;
    if (job.status === 'failed' || job.status === 'canceled') {
        return h('div', { class: `status-panel status-panel--${job.status}`, role: 'status' },
            h('b', {}, STATUS[job.status]), job.error && h('span', {}, job.error));
    }
    const percent = ['downloading', 'transcribing'].includes(job.status) && job.progress
        ? `${Math.round(job.progress * 100)}%` : '';
    const steps = ['queued', job.source_kind === 'url' ? 'downloading' : null, 'preparing', 'transcribing'].filter(Boolean);
    const current = steps.indexOf(job.status);
    return h('div', { class: 'status-panel', role: 'status' },
        h('ol', { class: 'steps' }, steps.map((step, index) => h('li', {
            class: index < current ? 'is-done' : index === current ? 'is-current' : '' }, STATUS[step]))),
        progressBar(job),
        h('p', { class: 'status-line' }, [STATUS[job.status], percent, etaText(job)].filter(Boolean).join(' · '),
            job.status === 'queued' && !state.config.worker_alive ? ' · o processador está fora do ar' : ''));
}

function actions(job) {
    const buttons = [];
    if (job.status === 'done') {
        const exports = h('div', { class: 'export' },
            ['txt', 'srt', 'vtt', 'json'].map(kind => h('a', { class: 'button button--small', href: `/api/jobs/${job.id}/export/${kind}`,
                download: '' }, svgIcon('download'), kind.toUpperCase())));
        buttons.push(
            h('button', { class: 'button button--small', type: 'button', onclick: async event => {
                try {
                    const response = await api(`/api/jobs/${job.id}/export/txt`, { raw: true });
                    await navigator.clipboard.writeText(await response.text());
                    flash(event.currentTarget, 'Copiado ✓');
                } catch {
                    toast('Não foi possível copiar.');
                }
            } }, svgIcon('copy'), 'Copiar texto'),
            exports);
    }
    if (ACTIVE.includes(job.status)) {
        buttons.push(h('button', { class: 'button button--small', type: 'button', onclick: async () => {
            try {
                await api(`/api/jobs/${job.id}/cancel`, { method: 'POST' });
            } catch (error) {
                toast(error.message);
            }
        } }, 'Cancelar'));
    }
    if (job.status === 'failed' || job.status === 'canceled') {
        buttons.push(h('button', { class: 'button button--small button--primary', type: 'button', onclick: async () => {
            try {
                await api(`/api/jobs/${job.id}/retry`, { method: 'POST' });
                await openJob(job.id);
            } catch (error) {
                toast(error.message);
            }
        } }, 'Tentar de novo'));
    }
    buttons.push(h('button', { class: 'button button--small button--danger', type: 'button', onclick: async () => {
        if (!confirm(`Apagar “${job.title}”? O texto e o áudio somem para sempre.`)) return;
        try {
            await api(`/api/jobs/${job.id}`, { method: 'DELETE' });
            state.jobs.delete(job.id);
            location.hash = '#/';
        } catch (error) {
            toast(error.message);
        }
    } }, svgIcon('trash'), 'Apagar'));
    return h('div', { class: 'actions' }, buttons);
}

function emptyTranscript(job) {
    if (ACTIVE.includes(job.status)) {
        return h('p', { class: 'placeholder' }, 'O texto aparece aqui enquanto é transcrito.');
    }
    if (job.status === 'done') return h('p', { class: 'placeholder' }, 'Nenhuma fala encontrada no áudio.');
    return null;
}

function transcript(job, segments, seek) {
    const detail = state.detail;
    const toggle = h('div', { class: 'segmented segmented--small', role: 'tablist', 'aria-label': 'Visualização' },
        [['segments', 'Trechos'], ['text', 'Texto corrido']].map(([mode, label]) => h('button', {
            type: 'button', role: 'tab', class: 'segmented-option', 'aria-selected': String(detail.mode === mode),
            onclick: () => {
                detail.mode = mode;
                renderDetail();
            } }, label)));
    const editable = job.status === 'done';
    const body = detail.mode === 'text'
        ? h('div', { class: 'prose' }, paragraphs(segments).map(text => h('p', {}, highlighted(text, state.query))))
        : h('ol', { class: 'segments' }, segments.map(segment => segmentRow(segment, editable, seek, job)));
    return h('div', { class: 'transcript' },
        h('div', { class: 'transcript-head' }, h('h2', {}, 'Transcrição'), toggle,
            editable && detail.mode === 'segments' && h('span', { class: 'hint' }, 'Toque no texto para corrigir.')),
        body);
}

function paragraphs(segments) {
    const result = [];
    let current = [];
    let lastEnd = null;
    let length = 0;
    for (const segment of segments) {
        if (current.length && ((lastEnd !== null && segment.start_ms - lastEnd >= 2000) || length >= 700)) {
            result.push(current.join(' '));
            current = [];
            length = 0;
        }
        current.push(segment.text);
        length += segment.text.length;
        lastEnd = segment.end_ms;
    }
    if (current.length) result.push(current.join(' '));
    return result;
}

function segmentRow(segment, editable, seek, job) {
    const time = h('button', { class: 'segment-time', type: 'button', title: 'Ouvir deste ponto',
        onclick: () => seek(segment) }, clock(segment.start_ms / 1000));
    const text = h('p', { class: 'segment-text' }, highlighted(segment.text, state.query));
    const row = h('li', { class: 'segment', dataset: { start: segment.start_ms, end: segment.end_ms } }, time, text);
    if (editable) {
        text.tabIndex = 0;
        text.setAttribute('role', 'button');
        text.setAttribute('aria-label', `Corrigir trecho de ${clock(segment.start_ms / 1000)}`);
        const edit = () => {
            const area = h('textarea', { class: 'input segment-input', rows: 2, maxlength: 5000, value: segment.text });
            const save = async () => {
                const value = area.value.trim();
                if (value !== segment.text) {
                    try {
                        await api(`/api/jobs/${job.id}/segments/${segment.idx}`, { method: 'PUT', body: { text: value } });
                        segment.text = value;
                    } catch (error) {
                        toast(error.message);
                    }
                }
                row.replaceWith(segmentRow(segment, editable, seek, job));
            };
            area.addEventListener('keydown', event => {
                if (event.key === 'Enter' && !event.shiftKey) {
                    event.preventDefault();
                    area.blur();
                }
                if (event.key === 'Escape') {
                    area.value = segment.text;
                    area.blur();
                }
            });
            area.addEventListener('blur', save, { once: true });
            text.replaceWith(area);
            area.focus();
        };
        text.addEventListener('click', edit);
        text.addEventListener('keydown', event => {
            if (event.key === 'Enter') edit();
        });
    }
    return row;
}

function markPlaying(ms) {
    let current = null;
    for (const row of document.querySelectorAll('.segment')) {
        const playing = ms >= Number(row.dataset.start) && ms < Number(row.dataset.end);
        row.classList.toggle('is-playing', playing);
        if (playing) current = row;
    }
    if (current && !current.dataset.seen) {
        current.dataset.seen = '1';
        const box = current.getBoundingClientRect();
        if (box.top < 80 || box.bottom > window.innerHeight - 40) current.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
}

// ── Conta ────────────────────────────────────────────────────────────

async function renderAccount() {
    const me = state.me;
    const tokenList = h('ul', { class: 'token-list' });
    const created = h('div', { class: 'token-created', hidden: true });
    const nameInput = h('input', { class: 'input', maxlength: 60, placeholder: 'Ex.: n8n, script do notebook', 'aria-label': 'Nome do token' });
    const admin = h('div');

    async function loadTokens() {
        const data = await api('/api/tokens');
        tokenList.replaceChildren(...(data.tokens.length ? data.tokens.map(token => h('li', { class: 'token' },
            h('span', { class: 'token-name' }, token.name),
            h('code', {}, `${token.prefix}…`),
            h('span', { class: 'hint' }, token.last_used_at ? `usado ${when(token.last_used_at)}` : 'nunca usado'),
            h('button', { class: 'text-button text-button--danger', type: 'button', onclick: async () => {
                if (!confirm(`Revogar o token “${token.name}”? Quem usa ele para de funcionar.`)) return;
                await api(`/api/tokens/${token.id}`, { method: 'DELETE' });
                loadTokens();
            } }, 'Revogar'))) : [h('li', { class: 'empty' }, 'Nenhum token.')]));
    }

    const example = `# Transcrever um link
curl -X POST ${location.origin}/api/jobs \\
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
  -d '{"url": "https://www.youtube.com/watch?v=…", "model": "turbo", "language": "pt"}'

# Acompanhar e baixar
curl -H "Authorization: Bearer $TOKEN" ${location.origin}/api/jobs/<id>
curl -H "Authorization: Bearer $TOKEN" ${location.origin}/api/jobs/<id>/export/txt`;

    refs.main.replaceChildren(h('section', { class: 'view view-account', 'aria-labelledby': 'account-title' },
        h('div', { class: 'view-head' },
            h('a', { class: 'back-link', href: '#/' }, svgIcon('back'), 'Biblioteca'),
            h('h1', { id: 'account-title' }, 'Conta')),
        h('div', { class: 'card' },
            h('p', { class: 'account-line' }, h('b', {}, me.name || me.username), ` · ${me.username}`, me.email && ` · ${me.email}`),
            h('p', { class: 'hint' }, 'Nome, usuário e e-mail vêm do Authentik.'),
            h('button', { class: 'button', type: 'button', onclick: async () => {
                await api('/auth/logout', { method: 'POST' }).catch(() => {});
                location.href = '/';
            } }, 'Sair')),
        h('div', { class: 'card' },
            h('h2', {}, svgIcon('key'), ' Tokens da API'),
            h('p', { class: 'hint' }, 'Para scripts e automações (n8n, por exemplo). O token tem o mesmo acesso que você: só às suas transcrições.'),
            tokenList,
            h('form', { class: 'inline-form', onsubmit: async event => {
                event.preventDefault();
                if (!nameInput.value.trim()) return;
                try {
                    const token = await api('/api/tokens', { method: 'POST', body: { name: nameInput.value.trim() } });
                    nameInput.value = '';
                    const code = h('code', { class: 'token-secret' }, token.token);
                    created.replaceChildren(
                        h('p', {}, h('b', {}, 'Copie agora: '), 'o token não aparece de novo.'),
                        code,
                        h('button', { class: 'button button--small', type: 'button', onclick: async ev => {
                            await navigator.clipboard.writeText(token.token).catch(() => {});
                            flash(ev.currentTarget, 'Copiado ✓');
                        } }, svgIcon('copy'), 'Copiar'));
                    created.hidden = false;
                    loadTokens();
                } catch (error) {
                    toast(error.message);
                }
            } }, nameInput, h('button', { class: 'button button--primary', type: 'submit' }, 'Criar token')),
            created,
            h('details', { class: 'details' }, h('summary', {}, 'Exemplos de uso'),
                h('pre', { class: 'code' }, example),
                h('p', { class: 'hint' }, 'Arquivos: POST /api/uploads, PUT /api/uploads/<id>?offset=… em pedaços de até 8 MB e POST /api/uploads/<id>/complete. Esquema completo em ',
                    h('a', { href: '/api/openapi.json' }, '/api/openapi.json'), '.'))),
        me.is_admin && admin));
    loadTokens().catch(error => toast(error.message));
    if (me.is_admin) renderAdmin(admin);
}

async function renderAdmin(container) {
    let status;
    try {
        status = await api('/api/admin/status');
    } catch (error) {
        container.replaceChildren(h('p', { class: 'notice notice--error' }, error.message));
        return;
    }
    const counts = Object.entries(status.jobs).map(([key, value]) => `${STATUS[key] ?? key}: ${value}`).join(' · ') || 'nenhuma';
    container.replaceChildren(h('div', { class: 'card' },
        h('h2', {}, 'Servidor'),
        status.workers.length ? status.workers.map(worker => h('div', { class: 'worker' },
            h('p', {}, h('span', { class: `chip ${worker.alive ? 'chip--done' : 'chip--failed'}` },
                worker.alive ? (WORKER_STATES[worker.state] ?? worker.state) : 'fora do ar'),
                ' ', h('b', {}, worker.detail.gpu?.name ?? 'GPU desconhecida'),
                worker.detail.gpu?.memory_total && ` · VRAM ${worker.detail.gpu.memory_used} de ${worker.detail.gpu.memory_total}`,
                worker.detail.gpu?.driver && ` · driver ${worker.detail.gpu.driver}`),
            worker.detail.error && h('p', { class: 'notice notice--error' }, worker.detail.error),
            h('p', { class: 'hint' }, `Modelo na VRAM: ${worker.detail.loaded_model ? modelLabel(worker.detail.loaded_model) : 'nenhum'} · último sinal ${when(worker.heartbeat_at)}`),
            h('ul', { class: 'model-status' }, Object.entries(worker.detail.models ?? {}).map(([id, value]) =>
                h('li', {}, h('b', {}, modelLabel(id)), ` ${value}`))))) : h('p', {}, 'Nenhum worker registrado ainda.'),
        h('p', { class: 'hint' }, `Transcrições por estado: ${counts}`),
        h('p', { class: 'hint' }, `Espaço livre para arquivos temporários: ${bytes(status.disk_free_bytes)}`)));
}

// ── Avisos ───────────────────────────────────────────────────────────

function toast(message) {
    const element = h('div', { class: 'toast', role: 'status' }, message);
    document.body.append(element);
    setTimeout(() => element.remove(), 4000);
}

function flash(button, text) {
    const original = [...button.childNodes];
    button.replaceChildren(text);
    setTimeout(() => button.replaceChildren(...original), 1500);
}

start().catch(error => {
    console.error(error);
    renderFatal(error instanceof ApiError ? error.message : 'Não foi possível abrir o Transcriptor.');
});
