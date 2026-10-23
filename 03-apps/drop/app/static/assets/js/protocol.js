// Protocolo do Drop (v2). Sem DOM: roda no navegador e no Node (testes).
//
// O código de 20 símbolos (100 bits) passa por HKDF-SHA256 e vira duas coisas
// independentes: o ID da sala, que vai ao servidor, e a chave AES-256-GCM, que
// nunca sai do navegador. Cada frame binário é:
//
//   versão (1 byte) | IV (12) | AES-GCM(mensagem)
//
// com dados associados que amarram o frame à sala e ao lado que o mandou: o
// servidor não consegue devolver um frame a quem o enviou nem trocá-lo de sala.
// A mensagem é: tipo (1) | id (16) | corpo. Os corpos têm padding por faixas,
// para o tamanho do frame não revelar o tamanho do texto.

export const PROTOCOL_VERSION = 2;
export const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const CODE_LENGTH = 20;
export const MAX_TEXT_BYTES = 16 * 1024;
export const MAX_TRANSFER_BYTES = 25 * 1024 * 1024;
export const MAX_FILES = 20;
export const CHUNK_BYTES = 64 * 1024;

export const Kind = Object.freeze({ TEXT: 1, FILE: 2, CHUNK: 3, ACK: 4, CANCEL: 5 });

const ID_BYTES = 16;
const IV_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = 1 + ID_BYTES;
const PAD_BUCKETS = [256, 1024, 4096, MAX_TEXT_BYTES + 4];
const CODE_PATTERN = new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`);
const HEX_64 = /^[a-f0-9]{64}$/;

const encoder = new TextEncoder();
const strictDecoder = new TextDecoder('utf-8', { fatal: true });
const subtle = globalThis.crypto.subtle;

export class ProtocolError extends Error {}

// ── Código ───────────────────────────────────────────────────────────

export function generateCode() {
    // 256 é múltiplo de 32: o "& 31" não cria viés.
    const bytes = globalThis.crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
    return Array.from(bytes, byte => CODE_ALPHABET[byte & 31]).join('');
}

/** Aceita minúsculas, espaços e hífens; devolve o código limpo ou null. */
export function normalizeCode(input) {
    const code = String(input ?? '').toUpperCase().replace(/[\s-]/g, '');
    return CODE_PATTERN.test(code) ? code : null;
}

export function formatCode(code) {
    return code.match(/.{1,4}/g).join('-');
}

/** Código digitado, colado ou lido do QR (link com #code= de qualquer endereço). */
export function codeFromText(text) {
    const trimmed = String(text ?? '').trim();
    const direct = normalizeCode(trimmed);
    if (direct) return direct;
    try {
        const url = new URL(trimmed);
        return normalizeCode(new URLSearchParams(url.hash.slice(1)).get('code'));
    } catch {
        return null;
    }
}

export function linkFor(origin, code) {
    return `${origin}/#code=${code}`;
}

// ── Chaves e frames ──────────────────────────────────────────────────

export async function deriveSession(code) {
    if (!CODE_PATTERN.test(code)) throw new ProtocolError('código inválido');
    const material = await subtle.importKey('raw', encoder.encode(code), 'HKDF', false, ['deriveBits', 'deriveKey']);
    const salt = encoder.encode(`drop/v${PROTOCOL_VERSION}`);
    const roomBits = await subtle.deriveBits(
        { name: 'HKDF', hash: 'SHA-256', salt, info: encoder.encode('room') }, material, 256);
    const key = await subtle.deriveKey(
        { name: 'HKDF', hash: 'SHA-256', salt, info: encoder.encode('aes-256-gcm') }, material,
        { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    return { roomId: toHex(new Uint8Array(roomBits)), key };
}

function associatedData(roomId, role) {
    return encoder.encode(`drop/v${PROTOCOL_VERSION}|${roomId}|${role}`);
}

/** Cifra uma mensagem enviada por `role` ("receiver" ou "sender"). */
export async function seal(session, role, message) {
    const iv = globalThis.crypto.getRandomValues(new Uint8Array(IV_BYTES));
    const ciphertext = new Uint8Array(await subtle.encrypt(
        { name: 'AES-GCM', iv, additionalData: associatedData(session.roomId, role) }, session.key, message));
    const frame = new Uint8Array(1 + IV_BYTES + ciphertext.length);
    frame[0] = PROTOCOL_VERSION;
    frame.set(iv, 1);
    frame.set(ciphertext, 1 + IV_BYTES);
    return frame;
}

/** Decifra um frame que `role` mandou. Lança ProtocolError se não confere. */
export async function unseal(session, role, frame) {
    const bytes = frame instanceof Uint8Array ? frame : new Uint8Array(frame);
    if (bytes.length < 1 + IV_BYTES + TAG_BYTES + HEADER_BYTES || bytes[0] !== PROTOCOL_VERSION) {
        throw new ProtocolError('frame inválido');
    }
    try {
        return new Uint8Array(await subtle.decrypt(
            { name: 'AES-GCM', iv: bytes.subarray(1, 1 + IV_BYTES), additionalData: associatedData(session.roomId, role) },
            session.key, bytes.subarray(1 + IV_BYTES)));
    } catch {
        throw new ProtocolError('não foi possível decifrar');
    }
}

// ── Mensagens ────────────────────────────────────────────────────────

export function newId() {
    return toHex(globalThis.crypto.getRandomValues(new Uint8Array(ID_BYTES)));
}

function message(kind, id, body = new Uint8Array(0)) {
    const out = new Uint8Array(HEADER_BYTES + body.length);
    out[0] = kind;
    out.set(fromHex(id), 1);
    out.set(body, HEADER_BYTES);
    return out;
}

function pad(bytes, size = PAD_BUCKETS.find(bucket => bucket >= bytes.length + 4) ?? bytes.length + 4) {
    const out = new Uint8Array(size);
    new DataView(out.buffer).setUint32(0, bytes.length);
    out.set(bytes, 4);
    return out;
}

function unpad(bytes) {
    if (bytes.length < 4) throw new ProtocolError('corpo curto');
    const length = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0);
    if (length > bytes.length - 4) throw new ProtocolError('tamanho inválido');
    return bytes.subarray(4, 4 + length);
}

function json(value) {
    return pad(encoder.encode(JSON.stringify(value)));
}

export function textBytes(text) {
    return encoder.encode(text).length;
}

export function encodeText(id, text) {
    const bytes = encoder.encode(text);
    if (bytes.length > MAX_TEXT_BYTES) throw new ProtocolError('texto acima de 16 KiB');
    return message(Kind.TEXT, id, pad(bytes));
}

export function chunkCount(size) {
    return Math.ceil(size / CHUNK_BYTES);
}

export function encodeFile(id, { name, size, type, sha256 }) {
    return message(Kind.FILE, id, json({ name, size, type, chunks: chunkCount(size), sha256 }));
}

export function encodeChunk(id, index, data) {
    const body = new Uint8Array(4 + 4 + CHUNK_BYTES);
    new DataView(body.buffer).setUint32(0, index);
    // O último pedaço também vai cheio: o frame não entrega o tamanho exato.
    body.set(pad(data, CHUNK_BYTES + 4), 4);
    return message(Kind.CHUNK, id, body);
}

export function encodeAck(id, ok, reason = '') {
    return message(Kind.ACK, id, json({ ok: Boolean(ok), reason: String(reason).slice(0, 40) }));
}

export function encodeCancel(id) {
    return message(Kind.CANCEL, id);
}

export function safeFileName(name) {
    const clean = String(name ?? '').replace(/[\u0000-\u001f\u007f/\\]/g, '_').trim().slice(0, 200);
    return clean && clean !== '.' && clean !== '..' ? clean : 'arquivo';
}

function readJson(body) {
    try {
        const value = JSON.parse(strictDecoder.decode(unpad(body)));
        if (value && typeof value === 'object' && !Array.isArray(value)) return value;
    } catch { /* cai no erro abaixo */ }
    throw new ProtocolError('JSON inválido');
}

export function decodeMessage(bytes) {
    if (bytes.length < HEADER_BYTES) throw new ProtocolError('mensagem curta');
    const kind = bytes[0];
    const id = toHex(bytes.subarray(1, HEADER_BYTES));
    const body = bytes.subarray(HEADER_BYTES);
    switch (kind) {
        case Kind.TEXT: {
            let text;
            try {
                text = strictDecoder.decode(unpad(body));
            } catch (error) {
                throw error instanceof ProtocolError ? error : new ProtocolError('texto corrompido');
            }
            return { kind, id, text };
        }
        case Kind.FILE: {
            const meta = readJson(body);
            const size = meta.size;
            if (!Number.isSafeInteger(size) || size < 0 || size > MAX_TRANSFER_BYTES ||
                meta.chunks !== chunkCount(size) || typeof meta.sha256 !== 'string' || !HEX_64.test(meta.sha256)) {
                throw new ProtocolError('arquivo inválido');
            }
            const type = typeof meta.type === 'string' && meta.type.length <= 100 ? meta.type : '';
            return { kind, id, name: safeFileName(meta.name), size, type, chunks: meta.chunks, sha256: meta.sha256 };
        }
        case Kind.CHUNK: {
            if (body.length < 8) throw new ProtocolError('pedaço curto');
            const index = new DataView(body.buffer, body.byteOffset, body.byteLength).getUint32(0);
            const data = unpad(body.subarray(4));
            if (data.length > CHUNK_BYTES) throw new ProtocolError('pedaço grande demais');
            return { kind, id, index, data };
        }
        case Kind.ACK: {
            const value = readJson(body);
            return { kind, id, ok: value.ok === true, reason: typeof value.reason === 'string' ? value.reason : '' };
        }
        case Kind.CANCEL:
            return { kind, id };
        default:
            throw new ProtocolError('tipo desconhecido');
    }
}

// ── Arquivos ─────────────────────────────────────────────────────────

export async function sha256Hex(bytes) {
    return toHex(new Uint8Array(await subtle.digest('SHA-256', bytes)));
}

/** Mensagens (sem cifrar) para mandar um arquivo já lido em memória. */
export async function* fileMessages(id, { name, type }, bytes) {
    yield encodeFile(id, { name: safeFileName(name), size: bytes.length, type: type || '', sha256: await sha256Hex(bytes) });
    for (let index = 0, offset = 0; offset < bytes.length; index += 1, offset += CHUNK_BYTES) {
        yield encodeChunk(id, index, bytes.subarray(offset, offset + CHUNK_BYTES));
    }
}

/** Remonta um arquivo recebido e confere o SHA-256 de ponta a ponta. */
export class FileAssembler {
    constructor(meta) {
        this.meta = meta;
        this.parts = new Array(meta.chunks);
        this.received = 0;
    }

    expectedLength(index) {
        return index === this.meta.chunks - 1 ? this.meta.size - CHUNK_BYTES * index : CHUNK_BYTES;
    }

    add(index, data) {
        if (index >= this.meta.chunks || this.parts[index] !== undefined || data.length !== this.expectedLength(index)) {
            throw new ProtocolError('pedaço fora de ordem ou com tamanho errado');
        }
        this.parts[index] = data.slice();
        this.received += 1;
    }

    get done() {
        return this.received === this.meta.chunks;
    }

    get progress() {
        return this.meta.chunks ? this.received / this.meta.chunks : 1;
    }

    async finish() {
        const bytes = new Uint8Array(this.meta.size);
        this.parts.forEach((part, index) => bytes.set(part, index * CHUNK_BYTES));
        this.parts = [];
        if (await sha256Hex(bytes) !== this.meta.sha256) throw new ProtocolError('o arquivo chegou diferente do enviado');
        return bytes;
    }
}

// ── Utilidades ───────────────────────────────────────────────────────

export function toHex(bytes) {
    return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

export function fromHex(hex) {
    if (!/^(?:[a-f0-9]{2})+$/.test(hex)) throw new ProtocolError('hex inválido');
    return Uint8Array.from(hex.match(/../g), pair => parseInt(pair, 16));
}

export function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0).replace('.', ',')} KiB`;
    return `${(bytes / 1024 / 1024).toFixed(1).replace('.', ',')} MiB`;
}
