// QR code em SVG: nítido em qualquer tamanho e tema (sempre preto no branco,
// com a margem de 4 módulos que os leitores esperam).
import qrcode from '../vendor/qrcode.mjs';

const SVG_NS = 'http://www.w3.org/2000/svg';
const QUIET_ZONE = 4;

export function renderQr(container, text) {
    const qr = qrcode(0, 'M');
    qr.addData(text, 'Byte');
    qr.make();
    const count = qr.getModuleCount();
    const size = count + QUIET_ZONE * 2;

    // Um traço por sequência de módulos escuros na linha: caminho curto.
    let path = '';
    for (let row = 0; row < count; row += 1) {
        for (let col = 0; col < count; col += 1) {
            if (!qr.isDark(row, col)) continue;
            const start = col;
            while (col + 1 < count && qr.isDark(row, col + 1)) col += 1;
            path += `M${start + QUIET_ZONE} ${row + QUIET_ZONE}h${col - start + 1}v1h-${col - start + 1}z`;
        }
    }

    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
    svg.setAttribute('shape-rendering', 'crispEdges');
    svg.setAttribute('aria-hidden', 'true');
    const background = document.createElementNS(SVG_NS, 'rect');
    background.setAttribute('width', String(size));
    background.setAttribute('height', String(size));
    background.setAttribute('fill', '#ffffff');
    const modules = document.createElementNS(SVG_NS, 'path');
    modules.setAttribute('d', path);
    modules.setAttribute('fill', '#000000');
    svg.append(background, modules);
    container.replaceChildren(svg);
}
