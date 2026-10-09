const STATE_KEY = 'drop_app_state';
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 20;
const CODE_PATTERN = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{20}$/;
const MAX_MESSAGE_BYTES = 16 * 1024;
const MESSAGE_CLEAR_DELAY = 60_000;

let appState = { mode: null, code: null, sessionId: null, timestamp: 0 };
let cryptoKey = null;
let ws = null;
let html5QrCode = null;
let keepAliveTimer = null;
let clearMessageTimer = null;

async function deriveKeyAndId(code) {
    if (!CODE_PATTERN.test(code)) throw new Error('Código inválido');
    const enc = new TextEncoder();
    const keyMaterial = await window.crypto.subtle.importKey(
        'raw', enc.encode(code), { name: 'PBKDF2' }, false, ['deriveKey']
    );
    const key = await window.crypto.subtle.deriveKey(
        {
            name: 'PBKDF2',
            salt: enc.encode('drop-secure-salt'),
            iterations: 100_000,
            hash: 'SHA-256'
        },
        keyMaterial,
        { name: 'AES-GCM', length: 256 },
        false,
        ['encrypt', 'decrypt']
    );
    const hash = await window.crypto.subtle.digest('SHA-256', enc.encode(code));
    const sessionId = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('');
    return { key, sessionId };
}

async function encrypt(message, key) {
    const iv = window.crypto.getRandomValues(new Uint8Array(12));
    const encoded = new TextEncoder().encode(message);
    const encrypted = new Uint8Array(await window.crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, encoded));
    const packed = new Uint8Array(iv.length + encrypted.length);
    packed.set(iv);
    packed.set(encrypted, iv.length);
    return btoa(Array.from(packed, byte => String.fromCharCode(byte)).join(''));
}

async function decrypt(payload, key) {
    const packed = Uint8Array.from(atob(payload), character => character.charCodeAt(0));
    if (packed.length < 28) throw new Error('Mensagem inválida');
    const iv = packed.slice(0, 12);
    const encrypted = packed.slice(12);
    const plaintext = await window.crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, encrypted);
    return new TextDecoder().decode(plaintext);
}

function generateCode() {
    const randomBytes = window.crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
    return Array.from(randomBytes, value => CODE_ALPHABET[value & 31]).join('');
}

function saveState() {
    appState.timestamp = Date.now();
    try {
        sessionStorage.setItem(STATE_KEY, JSON.stringify(appState));
    } catch (error) {
        console.warn('Não foi possível salvar a sessão neste navegador.');
    }
}

function clearState() {
    try {
        sessionStorage.removeItem(STATE_KEY);
    } catch (error) {
        console.warn('Não foi possível limpar a sessão deste navegador.');
    }
    appState = { mode: null, code: null, sessionId: null, timestamp: 0 };
    cryptoKey = null;
}

function loadState() {
    try {
        const saved = sessionStorage.getItem(STATE_KEY);
        if (!saved) return false;
        const parsed = JSON.parse(saved);
        const now = Date.now();
        const validMode = parsed.mode === 'receiver' || parsed.mode === 'sender';
        const validState = validMode && CODE_PATTERN.test(parsed.code) &&
            /^[a-f0-9]{64}$/.test(parsed.sessionId) &&
            Number.isFinite(parsed.timestamp) && parsed.timestamp <= now &&
            now - parsed.timestamp < 10 * 60 * 1000;
        if (validState) {
            appState = parsed;
            return true;
        }
    } catch (error) {
        console.warn('Estado local inválido; iniciando nova sessão.');
    }
    clearState();
    return false;
}

function showScreen(id) {
    ['mode-selection', 'receiver-mode', 'sender-mode'].forEach(screen => {
        document.getElementById(screen).classList.add('hidden');
    });
    document.getElementById(id).classList.remove('hidden');
}

async function init() {
    try {
        if (window.location.hash.length > 1) {
            const code = new URLSearchParams(window.location.hash.slice(1)).get('code')?.toUpperCase();
            window.history.replaceState(null, '', window.location.pathname + window.location.search);
            if (code && CODE_PATTERN.test(code)) {
                await setupSender(code);
                return;
            }
        }

        if (!loadState()) return;
        const derived = await deriveKeyAndId(appState.code);
        if (derived.sessionId !== appState.sessionId) {
            clearState();
            return;
        }
        cryptoKey = derived.key;
        if (appState.mode === 'receiver') await restoreReceiver();
        else await restoreSender();
    } catch (error) {
        console.error('Falha ao iniciar sessão.', error);
        clearState();
        alert('Não foi possível iniciar a sessão. Gere um novo código.');
    }
}

async function initReceiver() {
    const code = generateCode();
    const derived = await deriveKeyAndId(code);
    cryptoKey = derived.key;
    appState = { mode: 'receiver', code, sessionId: derived.sessionId, timestamp: 0 };
    saveState();
    await restoreReceiver();
}

async function restoreReceiver() {
    showScreen('receiver-mode');
    document.getElementById('display-code').textContent = appState.code;
    const qrUrl = `${window.location.origin}/#code=${appState.code}`;
    document.getElementById('qrcode').replaceChildren();
    new QRCode(document.getElementById('qrcode'), { text: qrUrl, width: 180, height: 180 });
    connectWebSocket();
}

function connectWebSocket() {
    if (keepAliveTimer) clearInterval(keepAliveTimer);
    if (ws) ws.close();
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const connection = new WebSocket(`${protocol}//${window.location.host}/ws/${appState.sessionId}`);
    ws = connection;
    const status = document.getElementById('status');

    connection.onopen = () => {
        status.textContent = '🟢 Aguardando conexão segura...';
        status.className = 'text-sm font-mono text-emerald-500 animate-pulse';
        keepAliveTimer = setInterval(() => {
            if (connection.readyState === WebSocket.OPEN) connection.send('ping');
        }, 30_000);
    };

    connection.onmessage = async event => {
        if (event.data === 'ping') return;
        status.textContent = '🔒 Pacote recebido! Descriptografando...';
        try {
            const plaintext = await decrypt(event.data, cryptoKey);
            const received = document.getElementById('decrypted-content');
            received.value = plaintext;
            received.type = 'password';
            document.getElementById('received-area').classList.remove('hidden');
            status.textContent = '✅ Mensagem recebida. Ela será apagada desta tela em 60 segundos.';
            status.className = 'text-sm font-mono text-emerald-500 font-bold';
            if (clearMessageTimer) clearTimeout(clearMessageTimer);
            clearMessageTimer = setTimeout(() => {
                received.value = '';
                document.getElementById('received-area').classList.add('hidden');
            }, MESSAGE_CLEAR_DELAY);
            if (navigator.vibrate) navigator.vibrate(200);
        } catch (error) {
            console.error('Falha ao descriptografar mensagem.');
            status.textContent = '❌ Não foi possível descriptografar a mensagem.';
            status.className = 'text-sm font-mono text-red-500';
        }
    };

    connection.onclose = event => {
        if (keepAliveTimer) clearInterval(keepAliveTimer);
        keepAliveTimer = null;
        status.textContent = event.code === 1008 ? '⚠️ Sessão ocupada ou inválida.' : '🔴 Desconectado.';
        status.className = 'text-sm font-mono text-red-500';
    };
}

function initSender() {
    showScreen('sender-mode');
    document.getElementById('sender-connect-step').classList.remove('hidden');
    document.getElementById('sender-message-step').classList.add('hidden');
}

async function connectSenderManual() {
    const code = document.getElementById('sender-code-input').value.toUpperCase();
    if (!CODE_PATTERN.test(code)) {
        alert('O código deve ter 20 caracteres válidos.');
        return;
    }
    await setupSender(code);
}

async function copyConnectionCode() {
    try {
        await navigator.clipboard.writeText(appState.code);
        const button = document.querySelector('[data-action="copyConnectionCode"]');
        button.innerHTML = '<span aria-hidden="true">✓</span> Código copiado';
        setTimeout(() => {
            button.innerHTML = '<span aria-hidden="true">▣</span> Copiar código';
        }, 1600);
    } catch (error) {
        alert('Não foi possível copiar o código neste navegador.');
    }
}

async function setupSender(code) {
    const derived = await deriveKeyAndId(code);
    cryptoKey = derived.key;
    appState = { mode: 'sender', code, sessionId: derived.sessionId, timestamp: 0 };
    saveState();
    await restoreSender();
}

async function restoreSender() {
    showScreen('sender-mode');
    document.getElementById('sender-connect-step').classList.add('hidden');
    document.getElementById('sender-message-step').classList.remove('hidden');
    document.getElementById('connected-code').textContent = appState.code;
    if (html5QrCode?.isScanning) await html5QrCode.stop();
}

async function encryptAndSend() {
    const button = document.getElementById('send-btn');
    const status = document.getElementById('sender-status');
    const input = document.getElementById('secret-input');
    const secret = input.value;
    if (!secret) return;
    if (new TextEncoder().encode(secret).byteLength > MAX_MESSAGE_BYTES) {
        status.textContent = '❌ A mensagem excede o limite de 16 KiB.';
        status.className = 'text-center text-sm text-red-500 font-bold';
        return;
    }

    button.disabled = true;
    button.textContent = '⏳ Enviando...';
    try {
        const encrypted = await encrypt(secret, cryptoKey);
        const response = await fetch(`/api/send/${appState.sessionId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ encrypted_payload: encrypted })
        });
        const result = await response.json();
        if (!response.ok) throw new Error(result.detail || 'Falha no envio');

        status.textContent = '✅ Enviado com sucesso!';
        status.className = 'text-center text-sm text-emerald-500 font-bold';
        input.value = '';
        setTimeout(() => {
            status.textContent = '';
            button.textContent = '🔒 Enviar Outro';
            button.disabled = false;
        }, 2000);
    } catch (error) {
        status.textContent = `❌ Erro: ${error.message}`;
        status.className = 'text-center text-sm text-red-500 font-bold';
        button.disabled = false;
        button.textContent = '🔒 Tentar Novamente';
    }
}

function startScanner() {
    const button = document.getElementById('start-scan-btn');
    button.classList.add('hidden');
    html5QrCode = new Html5Qrcode('reader');
    html5QrCode.start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 250 } },
        async decodedText => {
            let qrUrl;
            try {
                qrUrl = new URL(decodedText);
            } catch (error) {
                return;
            }
            if (qrUrl.origin !== window.location.origin) return;
            const code = new URLSearchParams(qrUrl.hash.slice(1)).get('code')?.toUpperCase();
            if (!code || !CODE_PATTERN.test(code)) return;
            await html5QrCode.stop();
            await setupSender(code);
        },
        () => {}
    ).catch(error => {
        alert(`Erro ao iniciar câmera: ${error}`);
        button.classList.remove('hidden');
    });
}

function resetApp() {
    document.getElementById('decrypted-content').value = '';
    document.getElementById('secret-input').value = '';
    if (clearMessageTimer) clearTimeout(clearMessageTimer);
    if (keepAliveTimer) clearInterval(keepAliveTimer);
    if (html5QrCode?.isScanning) html5QrCode.stop();
    clearState();
    if (ws) ws.close();
    window.location.hash = '';
    location.reload();
}

function toggleVisibility() {
    const input = document.getElementById('decrypted-content');
    input.type = input.type === 'password' ? 'text' : 'password';
}

async function copyToClipboard() {
    const input = document.getElementById('decrypted-content');
    try {
        await navigator.clipboard.writeText(input.value);
    } catch (error) {
        alert('Não foi possível acessar a área de transferência.');
    }
}

async function clearClipboard() {
    if (!navigator.clipboard || !window.isSecureContext) {
        alert('Limpeza de área de transferência não suportada neste navegador.');
        return;
    }
    try {
        await navigator.clipboard.writeText('');
        alert('Pedido de limpeza enviado. O histórico do sistema ou do gerenciador de clipboard pode manter cópias.');
    } catch (error) {
        alert('Não foi possível limpar a área de transferência.');
    }
}

const actions = {
    initReceiver,
    initSender,
    copyConnectionCode,
    toggleVisibility,
    copyToClipboard,
    clearClipboard,
    resetApp,
    startScanner,
    connectSenderManual,
    encryptAndSend
};

document.addEventListener('click', event => {
    const button = event.target.closest('[data-action]');
    if (button) actions[button.dataset.action]?.();
});

document.getElementById('manual-code-form').addEventListener('submit', event => {
    event.preventDefault();
    connectSenderManual();
});

init();