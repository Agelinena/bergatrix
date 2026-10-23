// Testes do protocolo do navegador: node --test tests/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import * as P from '../app/static/assets/js/protocol.js';

const CODE = 'ABCDEFGHJKLMNPQRSTUV';

async function roundTrip(message, code = CODE) {
    const session = await P.deriveSession(code);
    const frame = await P.seal(session, 'sender', message);
    return { frame, decoded: P.decodeMessage(await P.unseal(session, 'sender', frame)) };
}

test('código: alfabeto, tamanho e normalização', () => {
    for (let i = 0; i < 200; i += 1) {
        const code = P.generateCode();
        assert.equal(code.length, 20);
        assert.equal(P.normalizeCode(code), code);
        assert.ok([...code].every(c => P.CODE_ALPHABET.includes(c)));
    }
    assert.equal(P.normalizeCode('abcd-efgh jklm-npqr stuv'), CODE);
    assert.equal(P.normalizeCode('ABCD-EFGH-IJKL-MNOP-QRST'), null); // I e O não existem
    assert.equal(P.formatCode(CODE), 'ABCD-EFGH-JKLM-NPQR-STUV');
});

test('código vindo de link de qualquer endereço ou digitado', () => {
    assert.equal(P.codeFromText(`https://drop.example.com/#code=${CODE}`), CODE);
    assert.equal(P.codeFromText(`http://192.168.0.10:8000/#code=${CODE.toLowerCase()}`), CODE);
    assert.equal(P.codeFromText(`  ${P.formatCode(CODE)}  `), CODE);
    assert.equal(P.codeFromText('https://example.com/'), null);
    assert.equal(P.codeFromText('qualquer coisa'), null);
});

test('texto chega byte a byte igual (quebras de linha, emoji, acentos)', async () => {
    const samples = [
        'linha 1\nlinha 2\r\nlinha 3\rfim',
        '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n',
        'senha"com\'aspas`e\\barras',
        'ação, coração, pão — “aspas” ‘curvas’ … ✓',
        '👩🏽‍💻🇧🇷 emoji com ZWJ e bandeira',
        '\tcom\ttabs\u0000e NUL e nbsp ',
        '   espaços nas pontas   ',
        'x'.repeat(P.MAX_TEXT_BYTES),
    ];
    for (const text of samples) {
        const id = P.newId();
        const { decoded } = await roundTrip(P.encodeText(id, text));
        assert.equal(decoded.kind, P.Kind.TEXT);
        assert.equal(decoded.id, id);
        assert.equal(decoded.text, text);
    }
});

test('texto acima de 16 KiB é recusado', () => {
    assert.throws(() => P.encodeText(P.newId(), 'é'.repeat(P.MAX_TEXT_BYTES / 2 + 1)), P.ProtocolError);
});

test('padding: textos de tamanhos parecidos geram frames iguais', async () => {
    const a = (await roundTrip(P.encodeText(P.newId(), 'oi'))).frame.length;
    const b = (await roundTrip(P.encodeText(P.newId(), 'x'.repeat(200)))).frame.length;
    assert.equal(a, b);
});

test('frame não abre com outro código, outro lado ou alterado', async () => {
    const session = await P.deriveSession(CODE);
    const other = await P.deriveSession('VUTSRQPNMLKJHGFEDCBA');
    assert.notEqual(session.roomId, other.roomId);
    assert.match(session.roomId, /^[a-f0-9]{64}$/);
    const frame = await P.seal(session, 'sender', P.encodeText(P.newId(), 'segredo'));
    await assert.rejects(P.unseal(other, 'sender', frame), P.ProtocolError);
    // O servidor devolvendo o frame para quem o mandou não funciona.
    await assert.rejects(P.unseal(session, 'receiver', frame), P.ProtocolError);
    const tampered = frame.slice();
    tampered[tampered.length - 1] ^= 1;
    await assert.rejects(P.unseal(session, 'sender', tampered), P.ProtocolError);
});

test('o ID da sala não é a chave nem o hash simples do código', async () => {
    const session = await P.deriveSession(CODE);
    const digest = P.toHex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(CODE))));
    assert.notEqual(session.roomId, digest);
});

async function sendFile(bytes, name = 'arquivo.bin') {
    const session = await P.deriveSession(CODE);
    const id = P.newId();
    let assembler = null;
    let frames = 0;
    for await (const message of P.fileMessages(id, { name, type: 'application/pdf' }, bytes)) {
        const frame = await P.seal(session, 'sender', message);
        frames += 1;
        assert.ok(frame.length <= 66 * 1024, 'frame cabe no limite do servidor');
        const decoded = P.decodeMessage(await P.unseal(session, 'sender', frame));
        if (decoded.kind === P.Kind.FILE) assembler = new P.FileAssembler(decoded);
        else assembler.add(decoded.index, decoded.data);
    }
    assert.ok(assembler.done);
    return { result: await assembler.finish(), meta: assembler.meta, frames };
}

test('arquivos de vários tamanhos chegam íntegros', async () => {
    for (const size of [0, 1, P.CHUNK_BYTES - 1, P.CHUNK_BYTES, P.CHUNK_BYTES + 1, 3 * 1024 * 1024 + 7]) {
        const bytes = new Uint8Array(size);
        for (let offset = 0; offset < size; offset += 65536) {
            crypto.getRandomValues(bytes.subarray(offset, Math.min(size, offset + 65536)));
        }
        const { result, meta, frames } = await sendFile(bytes);
        assert.deepEqual(result, bytes);
        assert.equal(meta.size, size);
        assert.equal(frames, 1 + P.chunkCount(size));
    }
});

test('nome de arquivo perigoso é limpo', async () => {
    const { meta } = await sendFile(new Uint8Array([1, 2, 3]), '../../etc/passwd\u0000.txt');
    assert.equal(meta.name, '.._.._etc_passwd_.txt');
    assert.equal(P.safeFileName('..'), 'arquivo');
});

test('pedaço repetido, fora do limite ou arquivo alterado é recusado', async () => {
    const meta = { name: 'a', size: P.CHUNK_BYTES + 10, type: '', chunks: 2, sha256: '0'.repeat(64) };
    const assembler = new P.FileAssembler(meta);
    assert.throws(() => assembler.add(2, new Uint8Array(10)), P.ProtocolError);
    assert.throws(() => assembler.add(1, new Uint8Array(11)), P.ProtocolError);
    assembler.add(1, new Uint8Array(10));
    assert.throws(() => assembler.add(1, new Uint8Array(10)), P.ProtocolError);
    assembler.add(0, new Uint8Array(P.CHUNK_BYTES));
    await assert.rejects(assembler.finish(), P.ProtocolError);
});

test('metadados de arquivo inválidos são recusados', () => {
    const fake = (body) => {
        const json = new TextEncoder().encode(JSON.stringify(body));
        const message = new Uint8Array(17 + 4 + json.length);
        message[0] = P.Kind.FILE;
        new DataView(message.buffer).setUint32(17, json.length);
        message.set(json, 21);
        return message;
    };
    const ok = { name: 'a', size: 10, type: '', chunks: 1, sha256: 'a'.repeat(64) };
    assert.equal(P.decodeMessage(fake(ok)).size, 10);
    for (const bad of [{ ...ok, size: P.MAX_TRANSFER_BYTES + 1, chunks: P.chunkCount(P.MAX_TRANSFER_BYTES + 1) },
        { ...ok, chunks: 5 }, { ...ok, size: -1 }, { ...ok, sha256: 'x' }]) {
        assert.throws(() => P.decodeMessage(fake(bad)), P.ProtocolError);
    }
});

test('confirmação e cancelamento', async () => {
    const id = P.newId();
    const session = await P.deriveSession(CODE);
    const frame = await P.seal(session, 'receiver', P.encodeAck(id, false, 'hash'));
    assert.deepEqual(P.decodeMessage(await P.unseal(session, 'receiver', frame)),
        { kind: P.Kind.ACK, id, ok: false, reason: 'hash' });
    assert.deepEqual(P.decodeMessage(P.encodeCancel(id)), { kind: P.Kind.CANCEL, id });
});
