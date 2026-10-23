// O QR gerado precisa voltar idêntico pelo leitor que o app usa (jsQR).
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';

import qrcode from '../app/static/assets/vendor/qrcode.mjs';
import * as P from '../app/static/assets/js/protocol.js';

const jsQR = createRequire(import.meta.url)('../app/static/assets/vendor/jsQR.js');

function image(text, scale = 4, quiet = 4) {
    const qr = qrcode(0, 'M');
    qr.addData(text, 'Byte');
    qr.make();
    const size = (qr.getModuleCount() + quiet * 2) * scale;
    const data = new Uint8ClampedArray(size * size * 4).fill(255);
    for (let y = 0; y < size; y += 1) {
        for (let x = 0; x < size; x += 1) {
            const row = Math.floor(y / scale) - quiet;
            const col = Math.floor(x / scale) - quiet;
            if (row >= 0 && col >= 0 && row < qr.getModuleCount() && col < qr.getModuleCount() && qr.isDark(row, col)) {
                data.fill(0, (y * size + x) * 4, (y * size + x) * 4 + 3);
            }
        }
    }
    return { data, size };
}

test('link do QR volta igual pelo jsQR, com domínios de vários tamanhos', () => {
    for (const origin of ['https://drop.example.com', 'https://drop.um-dominio-bem-mais-comprido.example.com.br',
        'http://192.168.0.20:8000']) {
        for (let i = 0; i < 20; i += 1) {
            const link = P.linkFor(origin, P.generateCode());
            const { data, size } = image(link);
            const result = jsQR(data, size, size);
            assert.equal(result?.data, link);
            assert.equal(P.codeFromText(result.data), P.codeFromText(link));
        }
    }
});
