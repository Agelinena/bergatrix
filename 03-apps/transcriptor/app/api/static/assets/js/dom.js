// Montagem de DOM sem innerHTML (a página roda com Trusted Types) e formatação.

export function h(tag, attrs = {}, ...children) {
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs ?? {})) {
        if (value === undefined || value === null || value === false) continue;
        if (key === 'class') element.className = value;
        else if (key === 'dataset') Object.assign(element.dataset, value);
        else if (key.startsWith('on') && typeof value === 'function') element.addEventListener(key.slice(2), value);
        else if (key in element && typeof value !== 'string') element[key] = value;
        else element.setAttribute(key, value === true ? '' : String(value));
    }
    append(element, children);
    return element;
}

function append(element, children) {
    for (const child of children.flat(Infinity)) {
        if (child === undefined || child === null || child === false) continue;
        element.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
}

export function svgIcon(name) {
    const paths = {
        upload: 'M12 16V4m0 0l-5 5m5-5l5 5M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3',
        link: 'M10 14a4 4 0 005.66 0l3-3a4 4 0 10-5.66-5.66l-1 1M14 10a4 4 0 00-5.66 0l-3 3a4 4 0 105.66 5.66l1-1',
        plus: 'M12 5v14M5 12h14',
        back: 'M15 18l-6-6 6-6',
        search: 'M11 18a7 7 0 100-14 7 7 0 000 14zm9 2l-4.35-4.35',
        play: 'M8 5v14l11-7z',
        copy: 'M9 9h10v10H9zM5 15V5h10',
        trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
        download: 'M12 4v12m0 0l-5-5m5 5l5-5M4 20h16',
        key: 'M15 7a3 3 0 11-3 3m3-3l5-5m-3 3l2 2M12 10l-8 8v3h3l8-8',
        user: 'M12 12a4 4 0 100-8 4 4 0 000 8zm-7 9a7 7 0 0114 0',
        close: 'M6 6l12 12M18 6L6 18',
    };
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    svg.classList.add('icon');
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', paths[name] ?? '');
    svg.append(path);
    return svg;
}

export function clock(seconds, withHours = null) {
    const total = Math.max(0, Math.floor(seconds));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const secs = total % 60;
    const mm = String(minutes).padStart(2, '0');
    const ss = String(secs).padStart(2, '0');
    return (withHours ?? hours > 0) ? `${hours}:${mm}:${ss}` : `${minutes}:${ss}`;
}

export function duration(seconds) {
    if (!seconds) return '';
    const minutes = Math.round(seconds / 60);
    if (minutes < 1) return `${Math.round(seconds)} s`;
    if (minutes < 60) return `${minutes} min`;
    return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, '0')} min`;
}

export function bytes(value) {
    if (!value) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    let index = 0;
    let amount = value;
    while (amount >= 1024 && index < units.length - 1) {
        amount /= 1024;
        index += 1;
    }
    return `${amount.toFixed(index && amount < 10 ? 1 : 0).replace('.', ',')} ${units[index]}`;
}

const dateFormat = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });

export function when(iso) {
    if (!iso) return '';
    const date = new Date(iso);
    const days = Math.floor((Date.now() - date.getTime()) / 86400000);
    if (days === 0 && new Date().getDate() === date.getDate()) {
        return `hoje, ${date.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`;
    }
    return dateFormat.format(date);
}

/** Texto com os trechos que batem com a busca destacados (<mark>). */
export function highlighted(text, query) {
    // A busca do servidor usa o radical em português ("orçamentos" acha
    // "orçamento"): aqui, palavras longas valem pelo começo.
    const terms = (query || '').toLowerCase().split(/\s+/).filter(term => term.length > 1)
        .map(term => (term.length > 5 ? term.slice(0, term.length - 2) : term));
    if (!terms.length) return [text];
    const lower = text.toLowerCase();
    const parts = [];
    let index = 0;
    while (index < text.length) {
        let next = -1;
        let length = 0;
        for (const term of terms) {
            const found = lower.indexOf(term, index);
            if (found !== -1 && (next === -1 || found < next)) {
                next = found;
                length = term.length;
            }
        }
        if (next === -1) {
            parts.push(text.slice(index));
            break;
        }
        if (next > index) parts.push(text.slice(index, next));
        parts.push(h('mark', {}, text.slice(next, next + length)));
        index = next + length;
    }
    return parts;
}
