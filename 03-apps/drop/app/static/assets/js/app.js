// Interface do Drop. O protocolo (chaves, frames, arquivos) fica em protocol.js.
import * as P from './protocol.js';
import { renderQr } from './qr.js';
import { Scanner, cameraAvailable, cameraErrorMessage } from './scanner.js';

const SESSION_KEY = 'drop:v2:session';
const THEME_KEY = 'drop:theme';
const SESSION_MS = 10 * 60 * 1000;
const TEXT_TTL_MS = 2 * 60 * 1000;
const FILE_TTL_MS = 5 * 60 * 1000;
const ACK_TIMEOUT_MS = 30_000;
const KEEPALIVE_MS = 25_000;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const RECONNECT_DELAYS = [500, 1000, 2000, 4000, 8000];
const MAX_NOT_FOUND_RETRIES = 4;
const MAX_BUSY_RETRIES = 3;

const $ = id => document.getElementById(id);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const app = {
    role: null,
    code: null,
    session: null,
    channel: null,
    expiresAt: 0,
    peer: false,
    ticker: null,
    scanner: null,
    files: [],
    sending: false,
    queue: Promise.resolve(),
    inbox: new Map(),
    pendingAcks: new Map(),
};

// ── Conexão ──────────────────────────────────────────────────────────

class Channel {
    constructor(session, role, events) {
        this.session = session;
        this.role = role;
        this.events = events;
        this.ws = null;
        this.ready = false;
        this.closed = false;
        this.attempt = 0;
        this.notFound = 0;
        this.busy = 0;
        this.keepAlive = null;
        this.retryTimer = null;
    }

    open() {
        if (this.closed) return;
        const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
        const ws = new WebSocket(`${scheme}://${location.host}/ws`);
        ws.binaryType = 'arraybuffer';
        this.ws = ws;
        ws.addEventListener('open', () => {
            ws.send(JSON.stringify({ type: 'join', v: P.PROTOCOL_VERSION, room: this.session.roomId, role: this.role }));
            this.keepAlive = setInterval(() => {
                if (ws.readyState === WebSocket.OPEN) ws.send('ping');
            }, KEEPALIVE_MS);
        });
        ws.addEventListener('message', event => {
            if (this.ws !== ws) return;
            if (typeof event.data !== 'string') {
                this.events.frame(new Uint8Array(event.data));
                return;
            }
            let data;
            try {
                data = JSON.parse(event.data);
            } catch {
                return;
            }
            if (data.type === 'ready') {
                this.ready = true;
                this.attempt = this.notFound = this.busy = 0;
            }
            this.events.control(data);
        });
        ws.addEventListener('close', event => {
            clearInterval(this.keepAlive);
            if (this.ws !== ws || this.closed) return;
            this.ws = null;
            this.ready = false;
            if (this.shouldRetry(event.code)) {
                const delay = RECONNECT_DELAYS[Math.min(this.attempt, RECONNECT_DELAYS.length - 1)];
                this.attempt += 1;
                this.events.reconnecting(event.code);
                this.retryTimer = setTimeout(() => this.open(), delay);
            } else {
                this.closed = true;
                this.events.stopped(event.code);
            }
        });
    }

    shouldRetry(code) {
        if (Date.now() >= app.expiresAt) return false;
        // O receptor pode estar recarregando a página: espera um pouco.
        if (code === 4004) return ++this.notFound <= MAX_NOT_FOUND_RETRIES;
        // A aba anterior ainda não saiu da sala (recarregar a página).
        if (code === 4009) return ++this.busy <= MAX_BUSY_RETRIES;
        return code < 4000 && code !== 1000;
    }

    async send(message) {
        const frame = await P.seal(this.session, this.role, message);
        // Não acumula o arquivo inteiro na memória do navegador.
        while (this.ready && this.ws.bufferedAmount > MAX_BUFFERED_BYTES) await sleep(25);
        if (!this.ready) throw new Error('conexão perdida');
        this.ws.send(frame);
    }

    close() {
        this.closed = true;
        clearTimeout(this.retryTimer);
        clearInterval(this.keepAlive);
        const ws = this.ws;
        this.ws = null;
        this.ready = false;
        ws?.close(1000);
    }
}

const CLOSE_MESSAGES = {
    4000: 'O servidor recusou a conexão. Recarregue a página.',
    4003: 'Conexão recusada: abra o Drop pelo endereço oficial.',
    4004: 'Nenhum receptor está usando esse código. Confira o código ou peça um novo.',
    4008: 'A sessão expirou. Comece de novo.',
    4009: 'Este código já está aberto em outra aba ou dispositivo.',
    4013: 'O servidor está cheio agora. Tente de novo em alguns minutos.',
    4029: 'Limite da sessão atingido. Comece uma nova sessão.',
};

function closeMessage(code) {
    return CLOSE_MESSAGES[code] || 'A conexão foi encerrada.';
}

// ── Sessão ───────────────────────────────────────────────────────────

function saveSession() {
    try {
        sessionStorage.setItem(SESSION_KEY, JSON.stringify({ role: app.role, code: app.code, expiresAt: app.expiresAt }));
    } catch { /* sessão só desta aba; sem storage, recarregar encerra */ }
}

function loadSession() {
    try {
        const saved = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null');
        if (saved && (saved.role === 'receiver' || saved.role === 'sender') && P.normalizeCode(saved.code) === saved.code &&
            Number.isFinite(saved.expiresAt) && saved.expiresAt > Date.now() && saved.expiresAt - Date.now() <= SESSION_MS) {
            return saved;
        }
    } catch { /* estado inválido: ignora */ }
    forgetSession();
    return null;
}

function forgetSession() {
    try {
        sessionStorage.removeItem(SESSION_KEY);
    } catch { /* nada a limpar */ }
}

async function startSession(role, code, expiresAt = Date.now() + SESSION_MS) {
    endSession();
    app.role = role;
    app.code = code;
    app.expiresAt = expiresAt;
    app.session = await P.deriveSession(code);
    saveSession();
    app.channel = new Channel(app.session, role, {
        control: onControl,
        frame: frame => enqueue(() => (role === 'receiver' ? onReceiverFrame(frame) : onSenderFrame(frame))),
        reconnecting: onReconnecting,
        stopped: onStopped,
    });
    app.channel.open();
    startTicker();
}

function endSession() {
    app.channel?.close();
    app.channel = null;
    app.session = null;
    app.role = null;
    app.code = null;
    app.peer = false;
    app.queue = Promise.resolve();
    clearInterval(app.ticker);
    app.ticker = null;
    for (const pending of app.pendingAcks.values()) pending.resolve({ ok: false, reason: 'cancelado' });
    app.pendingAcks.clear();
    clearInbox();
    $('session-pill').hidden = true;
    $('view-receiver').dataset.peer = 'false';
    forgetSession();
}

function enqueue(task) {
    // Um frame por vez, na ordem de chegada: o arquivo chega antes dos pedaços.
    app.queue = app.queue.then(task).catch(error => console.error('Falha ao tratar mensagem.', error));
}

function startTicker() {
    clearInterval(app.ticker);
    const pill = $('session-pill');
    pill.hidden = false;
    $('session-label').textContent = app.role === 'receiver' ? 'Recebendo' : 'Enviando';
    const tick = () => {
        const left = Math.max(0, app.expiresAt - Date.now());
        const seconds = Math.ceil(left / 1000);
        $('countdown').textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
        pill.dataset.urgent = String(seconds <= 60);
        if (left <= 0) expireSession();
    };
    tick();
    app.ticker = setInterval(tick, 1000);
}

function expireSession() {
    const role = app.role;
    endSession();
    if (role === 'receiver') {
        setStatus('receiver-status', 'A sessão expirou e tudo foi apagado desta tela. Gere um novo código para continuar.', 'error');
        $('qr').replaceChildren();
        $('receiver-code').textContent = '—';
    } else {
        showConnectStep('A sessão expirou. Peça um novo código para o receptor.');
    }
}

function onControl(data) {
    if (data.type === 'ready') {
        app.expiresAt = Math.min(app.expiresAt, Date.now() + data.expiresIn * 1000);
        saveSession();
        setPeer(Boolean(data.peer));
    } else if (data.type === 'peer') {
        setPeer(Boolean(data.present));
    } else if (data.type === 'error' && data.code === 'peer-missing') {
        setPeer(false);
    }
}

function onReconnecting(code) {
    if (app.role === 'receiver') {
        setStatus('receiver-status', 'Conexão perdida. Tentando de novo…', 'warn');
    } else if (code === 4004) {
        setStatus('sender-status', 'Procurando o receptor…', 'warn');
    } else {
        setStatus('sender-status', 'Conexão perdida. Tentando de novo…', 'warn');
    }
    updateSendButton();
}

function onStopped(code) {
    const message = closeMessage(code);
    const role = app.role;
    if (code === 4008) {
        expireSession();
        return;
    }
    endSession();
    if (role === 'receiver') {
        setStatus('receiver-status', message, 'error');
    } else {
        showConnectStep(message);
    }
}

function setPeer(present) {
    const was = app.peer;
    app.peer = present;
    $('session-pill').dataset.peer = String(present);
    $('view-receiver').dataset.peer = String(present && app.role === 'receiver');
    if (app.role === 'receiver') {
        if (present) {
            setStatus('receiver-status', 'Dispositivo conectado. Pode enviar.', 'ok');
        } else {
            setStatus('receiver-status', was
                ? 'O outro dispositivo saiu. Ele pode voltar com o mesmo código.'
                : 'Esperando o outro dispositivo. Leia o QR ou digite o código lá.', 'wait');
        }
    } else if (app.role === 'sender') {
        setStatus('sender-status', present
            ? `Conectado ao receptor ${P.formatCode(app.code)}.`
            : 'O receptor não está com a tela aberta. Esperando ele voltar…', present ? 'ok' : 'warn');
        if (!present) {
            for (const pending of app.pendingAcks.values()) pending.resolve({ ok: false, reason: 'receptor saiu' });
        }
    }
    updateSendButton();
}

// ── Receber ──────────────────────────────────────────────────────────

async function startReceiver(saved = null) {
    showView('receiver');
    const code = saved?.code ?? P.generateCode();
    await startSession('receiver', code, saved?.expiresAt);
    const link = P.linkFor(location.origin, code);
    $('receiver-code').textContent = P.formatCode(code);
    renderQr($('qr'), link);
    $('share-link').hidden = typeof navigator.share !== 'function';
    setStatus('receiver-status', 'Conectando…', 'wait');
}

async function onReceiverFrame(frame) {
    let message;
    try {
        message = P.decodeMessage(await P.unseal(app.session, 'sender', frame));
    } catch {
        setStatus('receiver-status', 'Chegou um pacote que não confere com o código. Ele foi descartado.', 'error');
        return;
    }
    switch (message.kind) {
        case P.Kind.TEXT:
            addTextItem(message.text);
            await sendAck(message.id, true);
            break;
        case P.Kind.FILE:
            if (app.inbox.has(message.id)) return;
            addFileItem(message);
            if (message.chunks === 0) await completeFile(message.id);
            break;
        case P.Kind.CHUNK: {
            const item = app.inbox.get(message.id);
            if (!item?.assembler) return;
            try {
                item.assembler.add(message.index, message.data);
            } catch {
                failFile(item, 'Chegou com defeito. Peça para enviar de novo.');
                await sendAck(message.id, false, 'pedaço inválido');
                return;
            }
            item.progress.value = item.assembler.progress;
            if (item.assembler.done) await completeFile(message.id);
            break;
        }
        case P.Kind.CANCEL: {
            const item = app.inbox.get(message.id);
            if (item?.assembler) failFile(item, 'Cancelado por quem enviou.');
            break;
        }
        default:
            break;
    }
}

async function sendAck(id, ok, reason = '') {
    try {
        await app.channel?.send(P.encodeAck(id, ok, reason));
    } catch { /* o emissor saiu: ele verá o envio sem confirmação */ }
}

function addInboxItem(template, ttl) {
    const element = $(template).content.firstElementChild.cloneNode(true);
    const item = { element, expiresAt: Date.now() + ttl, timer: null, url: null, assembler: null, label: '' };
    const id = P.newId();
    element.dataset.id = id;
    app.inbox.set(id, item);
    $('inbox').prepend(element);
    $('inbox-head').hidden = false;
    item.timer = setInterval(() => updateItemTimer(id), 1000);
    return { id, item };
}

function updateItemTimer(id) {
    const item = app.inbox.get(id);
    if (!item) return;
    const left = Math.max(0, Math.ceil((item.expiresAt - Date.now()) / 1000));
    const countdown = `apaga em ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
    item.element.querySelector('.item-meta').textContent = item.label ? `${item.label} · ${countdown}` : countdown;
    if (left === 0) removeInboxItem(id);
}

function addTextItem(text) {
    const { item } = addInboxItem('tpl-text-item', TEXT_TTL_MS);
    const area = item.element.querySelector('.item-text');
    area.value = text;
    area.rows = Math.min(8, Math.max(2, text.split('\n').length));
    item.label = P.formatBytes(P.textBytes(text));
    item.element.querySelector('.item-meta').textContent = item.label;
    vibrate();
}

function addFileItem(meta) {
    const element = $('tpl-file-item').content.firstElementChild.cloneNode(true);
    const item = {
        element, expiresAt: Date.now() + FILE_TTL_MS, timer: null, url: null,
        assembler: new P.FileAssembler(meta), progress: element.querySelector('.item-progress'), meta,
    };
    element.dataset.id = meta.id;
    element.querySelector('.item-name').textContent = meta.name;
    element.querySelector('.item-meta').textContent = `${P.formatBytes(meta.size)} · recebendo`;
    app.inbox.set(meta.id, item);
    $('inbox').prepend(element);
    $('inbox-head').hidden = false;
}

async function completeFile(id) {
    const item = app.inbox.get(id);
    if (!item?.assembler) return;
    let bytes;
    try {
        bytes = await item.assembler.finish();
    } catch {
        failFile(item, 'O arquivo chegou diferente do enviado e foi descartado.');
        await sendAck(id, false, 'hash');
        return;
    }
    item.assembler = null;
    // octet-stream: o navegador baixa, não abre o arquivo dentro do Drop.
    item.url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
    const link = item.element.querySelector('.item-download');
    link.href = item.url;
    link.download = item.meta.name;
    link.hidden = false;
    item.progress.hidden = true;
    item.label = `${P.formatBytes(item.meta.size)} · conferido`;
    item.element.querySelector('.item-meta').textContent = item.label;
    startItemTimer(id, FILE_TTL_MS);
    vibrate();
    await sendAck(id, true);
}

function failFile(item, reason) {
    item.assembler = null;
    item.progress.hidden = true;
    item.element.classList.add('item--failed');
    item.label = reason;
    item.element.querySelector('.item-meta').textContent = reason;
    startItemTimer(item.element.dataset.id, TEXT_TTL_MS);
}

function startItemTimer(id, ttl) {
    const item = app.inbox.get(id);
    if (!item) return;
    clearInterval(item.timer);
    item.expiresAt = Date.now() + ttl;
    item.timer = setInterval(() => updateItemTimer(id), 1000);
}

function removeInboxItem(id) {
    const item = app.inbox.get(id);
    if (!item) return;
    clearInterval(item.timer);
    // Apagado no meio do recebimento: avisa o emissor em vez de deixá-lo esperando.
    if (item.assembler) sendAck(id, false, 'recusado');
    if (item.url) URL.revokeObjectURL(item.url);
    const area = item.element.querySelector('.item-text');
    if (area) area.value = '';
    item.element.remove();
    app.inbox.delete(id);
    $('inbox-head').hidden = app.inbox.size === 0;
}

function clearInbox() {
    for (const id of [...app.inbox.keys()]) removeInboxItem(id);
}

function vibrate() {
    if (typeof navigator.vibrate === 'function') navigator.vibrate(120);
}

// ── Enviar ───────────────────────────────────────────────────────────

function startSenderView() {
    showView('sender');
    showConnectStep();
}

function showConnectStep(error = '') {
    stopScanner();
    $('connect-step').hidden = false;
    $('compose-step').hidden = true;
    $('sender-title').textContent = 'Conectar ao receptor';
    $('code-error').textContent = error;
    $('code-input').value = '';
}

async function connectSender(code, saved = null) {
    stopScanner();
    showView('sender');
    $('connect-step').hidden = true;
    $('compose-step').hidden = false;
    $('sender-title').textContent = 'O que enviar';
    $('outbox').replaceChildren();
    setStatus('sender-status', 'Conectando ao receptor…', 'wait');
    await startSession('sender', code, saved?.expiresAt);
    updateTextMeter();
    renderFileList();
}

async function onSenderFrame(frame) {
    let message;
    try {
        message = P.decodeMessage(await P.unseal(app.session, 'receiver', frame));
    } catch {
        return;
    }
    if (message.kind === P.Kind.ACK) app.pendingAcks.get(message.id)?.resolve(message);
}

function waitForAck(id) {
    return new Promise(resolve => {
        const timer = setTimeout(() => resolve({ ok: false, reason: 'sem confirmação' }), ACK_TIMEOUT_MS);
        app.pendingAcks.set(id, {
            resolve: result => {
                clearTimeout(timer);
                app.pendingAcks.delete(id);
                resolve(result);
            },
        });
    });
}

function activeTab() {
    return $('tab-files').getAttribute('aria-selected') === 'true' ? 'files' : 'text';
}

function updateSendButton() {
    const button = $('send-button');
    const tab = activeTab();
    const textSize = P.textBytes($('text-input').value);
    const hasContent = tab === 'text'
        ? textSize > 0 && textSize <= P.MAX_TEXT_BYTES
        : app.files.length > 0 && totalFileBytes() <= P.MAX_TRANSFER_BYTES;
    button.disabled = !(hasContent && app.peer && app.channel?.ready && !app.sending);
}

function updateTextMeter() {
    const size = P.textBytes($('text-input').value);
    const meter = $('text-size');
    meter.textContent = P.formatBytes(size);
    meter.closest('.meter').dataset.over = String(size > P.MAX_TEXT_BYTES);
    updateSendButton();
}

function totalFileBytes() {
    return app.files.reduce((sum, file) => sum + file.size, 0);
}

function addFiles(list) {
    const incoming = [...list].filter(file => !app.files.some(f => f.name === file.name && f.size === file.size));
    app.files.push(...incoming);
    renderFileList();
}

function renderFileList() {
    const rows = app.files.map((file, index) => {
        const row = $('tpl-file-row').content.firstElementChild.cloneNode(true);
        row.querySelector('.file-name').textContent = file.name;
        row.querySelector('.file-size').textContent = P.formatBytes(file.size);
        row.querySelector('[data-file-action="remove"]').dataset.index = String(index);
        return row;
    });
    const list = $('file-list');
    list.replaceChildren(...rows);
    const total = totalFileBytes();
    let note = '';
    if (app.files.length > P.MAX_FILES) note = `No máximo ${P.MAX_FILES} arquivos por vez.`;
    else if (total > P.MAX_TRANSFER_BYTES) note = `Passou do limite: ${P.formatBytes(total)} de 25 MiB.`;
    else if (app.files.length) note = `${app.files.length} arquivo(s) · ${P.formatBytes(total)} de 25 MiB`;
    list.dataset.note = note;
    list.dataset.over = String(app.files.length > P.MAX_FILES || total > P.MAX_TRANSFER_BYTES);
    updateSendButton();
}

function addOutItem(kind, name) {
    const element = $('tpl-out-item').content.firstElementChild.cloneNode(true);
    element.querySelector('.item-kind').textContent = kind;
    element.querySelector('.item-name').textContent = name;
    $('outbox').prepend(element);
    const meta = element.querySelector('.item-meta');
    const progress = element.querySelector('.item-progress');
    return {
        progress: value => { progress.value = value; },
        state(text, tone) {
            meta.textContent = text;
            element.dataset.tone = tone;
            if (tone !== 'wait') progress.hidden = true;
        },
    };
}

async function sendNow() {
    if (app.sending) return;
    app.sending = true;
    updateSendButton();
    try {
        if (activeTab() === 'text') await sendText();
        else await sendFiles();
    } finally {
        app.sending = false;
        updateSendButton();
    }
}

async function deliver(out, id, send) {
    const ack = waitForAck(id);
    try {
        await send();
    } catch {
        app.pendingAcks.get(id)?.resolve({ ok: false, reason: 'conexão perdida' });
    }
    out.state('Conferindo no destino…', 'wait');
    const result = await ack;
    if (result.ok) out.state('Entregue e conferido ✓', 'ok');
    else out.state(`Não entregue: ${result.reason || 'falha'}`, 'error');
    return result.ok;
}

async function sendText() {
    const input = $('text-input');
    const text = input.value;
    const id = P.newId();
    const out = addOutItem('Texto', `${P.formatBytes(P.textBytes(text))}`);
    out.state('Enviando…', 'wait');
    const ok = await deliver(out, id, () => app.channel.send(P.encodeText(id, text)));
    if (ok) {
        input.value = '';
        updateTextMeter();
    }
}

async function sendFiles() {
    const files = [...app.files];
    if (files.length > P.MAX_FILES || totalFileBytes() > P.MAX_TRANSFER_BYTES) return;
    for (const file of files) {
        const id = P.newId();
        const out = addOutItem('Arquivo', file.name);
        out.state(`${P.formatBytes(file.size)} · enviando`, 'wait');
        const ok = await deliver(out, id, async () => {
            const bytes = new Uint8Array(await file.arrayBuffer());
            const total = P.chunkCount(bytes.length) + 1;
            let sent = 0;
            for await (const message of P.fileMessages(id, file, bytes)) {
                if (!app.peer || !app.channel) throw new Error('receptor saiu');
                await app.channel.send(message);
                sent += 1;
                out.progress(sent / total);
            }
        });
        if (ok) {
            app.files = app.files.filter(f => f !== file);
            renderFileList();
        } else {
            try {
                await app.channel?.send(P.encodeCancel(id));
            } catch { /* sem conexão */ }
            break;
        }
    }
}

// ── Câmera ───────────────────────────────────────────────────────────

async function startScanner() {
    const status = $('scanner-status');
    if (!cameraAvailable()) {
        $('code-error').textContent = 'Este navegador não deixa usar a câmera aqui. Digite o código.';
        return;
    }
    $('scanner').hidden = false;
    $('scan-button').hidden = true;
    status.textContent = 'Abrindo a câmera…';
    app.scanner ??= new Scanner($('scanner-video'), onScanned);
    try {
        await app.scanner.start();
        status.textContent = 'Aponte para o QR code do outro dispositivo.';
        $('switch-camera').hidden = !app.scanner.canSwitch;
        $('torch').hidden = !app.scanner.hasTorch;
    } catch (error) {
        status.textContent = cameraErrorMessage(error);
        await app.scanner.stop();
        $('scan-button').hidden = false;
    }
}

function onScanned(text) {
    const code = P.codeFromText(text);
    if (!code) {
        $('scanner-status').textContent = 'Esse QR code não é de um Drop. Aponte para o código mostrado em "Receber".';
        return false;
    }
    vibrate();
    history.replaceState({ view: 'sender' }, '', location.pathname);
    connectSender(code).catch(showFatal);
    return true;
}

function stopScanner() {
    app.scanner?.stop();
    $('scanner').hidden = true;
    $('scan-button').hidden = false;
    $('torch').setAttribute('aria-pressed', 'false');
}

// ── Tela ─────────────────────────────────────────────────────────────

function showView(name) {
    for (const view of ['home', 'receiver', 'sender']) $(`view-${view}`).hidden = view !== name;
    if (name !== 'home' && history.state?.view !== name) history.pushState({ view: name }, '', location.pathname);
    window.scrollTo({ top: 0 });
}

function goHome() {
    stopScanner();
    endSession();
    app.files = [];
    $('text-input').value = '';
    $('outbox').replaceChildren();
    showView('home');
}

function setStatus(id, text, tone) {
    const element = $(id);
    element.textContent = text;
    element.dataset.tone = tone;
}

function selectTab(name) {
    for (const tab of ['text', 'files']) {
        const button = $(`tab-${tab}`);
        const selected = tab === name;
        button.setAttribute('aria-selected', String(selected));
        button.tabIndex = selected ? 0 : -1;
        $(`panel-${tab}`).hidden = !selected;
    }
    updateSendButton();
}

async function copyText(text, button) {
    try {
        await navigator.clipboard.writeText(text);
        flash(button, 'Copiado ✓');
    } catch {
        flash(button, 'Não deu para copiar');
    }
}

function flash(button, text) {
    const original = button.dataset.label ?? button.textContent;
    button.dataset.label = original;
    button.textContent = text;
    clearTimeout(button.flashTimer);
    button.flashTimer = setTimeout(() => {
        button.textContent = original;
    }, 1600);
}

function applyTheme(theme, persist = false) {
    const dark = theme === 'dark';
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    const toggle = $('theme-toggle');
    toggle.setAttribute('aria-pressed', String(dark));
    toggle.setAttribute('aria-label', dark ? 'Ativar tema claro' : 'Ativar tema escuro');
    $('theme-icon').textContent = dark ? '☀' : '☾';
    document.querySelector('meta[name="theme-color"]').content = dark ? '#111a17' : '#eef2ec';
    if (persist) {
        try {
            localStorage.setItem(THEME_KEY, dark ? 'dark' : 'light');
        } catch { /* sem storage: vale só nesta visita */ }
    }
}

function initTheme() {
    let saved = null;
    try {
        saved = localStorage.getItem(THEME_KEY);
    } catch { /* sem storage */ }
    const prefersDark = window.matchMedia?.('(prefers-color-scheme: dark)').matches;
    applyTheme(saved === 'dark' || saved === 'light' ? saved : prefersDark ? 'dark' : 'light');
}

function showFatal(error) {
    console.error(error);
    setStatus(app.role === 'sender' ? 'sender-status' : 'receiver-status',
        'Algo deu errado ao iniciar a sessão. Comece de novo.', 'error');
}

function formatCodeInput(input) {
    const atEnd = input.selectionStart === input.value.length;
    const raw = input.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (!atEnd) return;
    input.value = raw.match(/.{1,4}/g)?.join('-') ?? '';
}

// ── Eventos ──────────────────────────────────────────────────────────

const actions = {
    theme: () => applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true),
    receive: () => startReceiver().catch(showFatal),
    send: () => startSenderView(),
    reset: () => {
        goHome();
        history.replaceState(null, '', location.pathname);
    },
    'copy-code': button => copyText(app.code ?? '', button),
    'copy-link': button => copyText(P.linkFor(location.origin, app.code ?? ''), button),
    'share-link': () => navigator.share?.({ title: 'Drop', url: P.linkFor(location.origin, app.code) }).catch(() => {}),
    'clear-inbox': () => clearInbox(),
    scan: () => startScanner(),
    'stop-scan': () => stopScanner(),
    'switch-camera': async () => {
        try {
            await app.scanner?.switchCamera();
            $('torch').hidden = !app.scanner.hasTorch;
        } catch (error) {
            $('scanner-status').textContent = cameraErrorMessage(error);
        }
    },
    torch: async button => {
        try {
            button.setAttribute('aria-pressed', String(await app.scanner.toggleTorch()));
        } catch {
            button.hidden = true;
        }
    },
    'paste-code': async () => {
        const input = $('code-input');
        try {
            const text = await navigator.clipboard.readText();
            const code = P.codeFromText(text);
            input.value = code ? P.formatCode(code) : text.trim().slice(0, 40);
            submitCode();
        } catch {
            input.focus();
            $('code-error').textContent = 'Cole com o teclado (Ctrl+V ou segurar e colar).';
        }
    },
    tab: button => selectTab(button.dataset.tab),
    'send-now': () => sendNow(),
};

const itemActions = {
    reveal(element, button) {
        const area = element.querySelector('.item-text');
        const masked = area.classList.toggle('is-masked');
        button.setAttribute('aria-pressed', String(!masked));
        button.textContent = masked ? 'Mostrar' : 'Ocultar';
    },
    copy(element, button) {
        copyText(element.querySelector('.item-text').value, button);
    },
    remove(element) {
        removeInboxItem(element.dataset.id);
    },
};

function submitCode() {
    const code = P.codeFromText($('code-input').value);
    if (!code) {
        $('code-error').textContent = 'O código tem 20 letras e números (sem I, O, 0 e 1).';
        return;
    }
    connectSender(code).catch(showFatal);
}

document.addEventListener('click', event => {
    const target = event.target.closest('[data-action], [data-item-action], [data-file-action]');
    if (!target || target.disabled) return;
    if (target.dataset.action) {
        actions[target.dataset.action]?.(target);
    } else if (target.dataset.itemAction) {
        itemActions[target.dataset.itemAction]?.(target.closest('.item'), target);
    } else if (target.dataset.fileAction === 'remove') {
        app.files.splice(Number(target.dataset.index), 1);
        renderFileList();
    }
});

$('code-form').addEventListener('submit', event => {
    event.preventDefault();
    submitCode();
});

$('code-input').addEventListener('input', event => {
    $('code-error').textContent = '';
    const input = event.target;
    const pasted = P.codeFromText(input.value);
    if (pasted && input.value.includes('#code=')) input.value = P.formatCode(pasted);
    else formatCodeInput(input);
    // Código completo: conecta sem precisar tocar em "Conectar".
    if (P.normalizeCode(input.value)) submitCode();
});

$('text-input').addEventListener('input', updateTextMeter);
$('file-input').addEventListener('change', event => {
    addFiles(event.target.files);
    event.target.value = '';
});

const dropzone = $('dropzone');
for (const type of ['dragenter', 'dragover']) {
    dropzone.addEventListener(type, event => {
        event.preventDefault();
        dropzone.dataset.active = 'true';
    });
}
for (const type of ['dragleave', 'drop']) {
    dropzone.addEventListener(type, () => {
        dropzone.dataset.active = 'false';
    });
}
dropzone.addEventListener('drop', event => {
    event.preventDefault();
    if (event.dataTransfer?.files?.length) addFiles(event.dataTransfer.files);
});

document.querySelector('.tabs').addEventListener('keydown', event => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    const next = activeTab() === 'text' ? 'files' : 'text';
    selectTab(next);
    $(`tab-${next}`).focus();
});

window.addEventListener('popstate', () => {
    // Voltar do navegador encerra a sessão e mostra o início.
    if (!history.state?.view) goHome();
});

window.addEventListener('pagehide', () => {
    app.scanner?.stop();
});

// ── Início ───────────────────────────────────────────────────────────

async function init() {
    initTheme();
    if (!globalThis.crypto?.subtle || !window.isSecureContext) {
        $('unsupported').hidden = false;
        document.querySelectorAll('.choice').forEach(button => { button.disabled = true; });
        return;
    }
    const linked = location.hash.length > 1 ? P.codeFromText(location.href) : null;
    if (location.hash) history.replaceState(null, '', location.pathname);
    if (linked) {
        await connectSender(linked);
        return;
    }
    const saved = loadSession();
    if (saved?.role === 'receiver') await startReceiver(saved);
    else if (saved?.role === 'sender') await connectSender(saved.code, saved);
}

init().catch(showFatal);
