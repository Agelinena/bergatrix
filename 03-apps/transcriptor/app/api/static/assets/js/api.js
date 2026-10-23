// Conversa com a API. Pedidos que mudam algo levam X-Transcriptor: 1 (CSRF).

export class ApiError extends Error {
    constructor(status, message, data = null) {
        super(message);
        this.status = status;
        this.data = data;
    }
}

let onUnauthorized = () => {};

export function setUnauthorizedHandler(handler) {
    onUnauthorized = handler;
}

export async function api(path, { method = 'GET', body, raw = false } = {}) {
    const headers = { 'X-Transcriptor': '1' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let response;
    try {
        response = await fetch(path, {
            method, headers, credentials: 'same-origin',
            body: body === undefined ? undefined : JSON.stringify(body),
        });
    } catch {
        throw new ApiError(0, 'Sem conexão com o servidor.');
    }
    if (response.status === 401) {
        onUnauthorized();
        throw new ApiError(401, 'Sessão expirada.');
    }
    if (raw) return response;
    if (response.status === 204) return null;
    const data = await response.json().catch(() => null);
    if (!response.ok) {
        const detail = typeof data?.detail === 'string' ? data.detail : 'Algo deu errado. Tente de novo.';
        throw new ApiError(response.status, detail, data);
    }
    return data;
}

function putChunk(path, blob, onProgress) {
    return new Promise((resolve, reject) => {
        const request = new XMLHttpRequest();
        request.open('PUT', path);
        request.setRequestHeader('X-Transcriptor', '1');
        request.setRequestHeader('Content-Type', 'application/octet-stream');
        request.upload.addEventListener('progress', event => onProgress(event.loaded));
        request.addEventListener('load', () => {
            let data = null;
            try {
                data = JSON.parse(request.responseText);
            } catch { /* sem corpo */ }
            if (request.status >= 200 && request.status < 300) resolve(data);
            else reject(new ApiError(request.status, data?.detail || 'Falha no envio.', data));
        });
        request.addEventListener('error', () => reject(new ApiError(0, 'Conexão interrompida.')));
        request.addEventListener('abort', () => reject(new ApiError(-1, 'Envio cancelado.')));
        request.send(blob);
    });
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/** Envia um arquivo em pedaços (retoma do ponto certo se a conexão cair). */
export async function uploadFile(file, options, onProgress, signal) {
    const job = await api('/api/uploads', { method: 'POST', body: { name: file.name, size: file.size, ...options } });
    const chunk = job.chunk_bytes;
    let received = 0;
    let failures = 0;
    while (received < file.size) {
        if (signal?.aborted) {
            await api(`/api/jobs/${job.id}`, { method: 'DELETE' }).catch(() => {});
            throw new ApiError(-1, 'Envio cancelado.');
        }
        const end = Math.min(file.size, received + chunk);
        try {
            const result = await putChunk(`/api/uploads/${job.id}?offset=${received}`, file.slice(received, end),
                loaded => onProgress((received + loaded) / file.size));
            received = result.received;
            failures = 0;
        } catch (error) {
            if (error.status === 409 && Number.isInteger(error.data?.received)) {
                received = error.data.received;
                continue;
            }
            if (error.status === 401) onUnauthorized();
            if ((error.status === 0 || error.status >= 500) && failures < 6) {
                failures += 1;
                await sleep(1000 * 2 ** failures);
                const state = await api(`/api/uploads/${job.id}`).catch(() => null);
                if (state) received = state.received;
                continue;
            }
            throw error;
        }
        onProgress(received / file.size);
    }
    return api(`/api/uploads/${job.id}/complete`, { method: 'POST' });
}
