// Leitor de QR pela câmera. Usa o BarcodeDetector nativo quando existe
// (Chrome e Android) e o jsQR (carregado pela página) nos outros navegadores.

const SCAN_INTERVAL_MS = 120;
const MAX_SCAN_WIDTH = 720;

const CAMERA_ERRORS = {
    NotAllowedError: 'A permissão da câmera foi negada. Libere a câmera para este site nas configurações do navegador.',
    SecurityError: 'A câmera só funciona com HTTPS.',
    NotFoundError: 'Nenhuma câmera foi encontrada neste dispositivo.',
    OverconstrainedError: 'Nenhuma câmera atende ao pedido.',
    NotReadableError: 'A câmera está em uso por outro app. Feche-o e tente de novo.',
    AbortError: 'A câmera não iniciou. Tente de novo.',
};

export function cameraErrorMessage(error) {
    return CAMERA_ERRORS[error?.name] || 'Não foi possível abrir a câmera.';
}

export function cameraAvailable() {
    return Boolean(navigator.mediaDevices?.getUserMedia) && window.isSecureContext;
}

export class Scanner {
    constructor(video, onText) {
        this.video = video;
        this.onText = onText;
        this.stream = null;
        this.timer = null;
        this.detector = null;
        this.canvas = document.createElement('canvas');
        this.context = this.canvas.getContext('2d', { willReadFrequently: true });
        this.devices = [];
        this.deviceIndex = -1;
        this.torchOn = false;
    }

    get active() {
        return this.stream !== null;
    }

    async start(deviceId = null) {
        await this.stop();
        const video = deviceId
            ? { deviceId: { exact: deviceId } }
            : { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } };
        try {
            this.stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
        } catch (error) {
            if (error?.name !== 'OverconstrainedError' || deviceId) throw error;
            this.stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        }
        this.video.srcObject = this.stream;
        this.video.muted = true;
        this.video.setAttribute('playsinline', '');
        await this.video.play();
        this.detector = await nativeDetector();
        await this.loadDevices();
        this.scheduleScan();
    }

    async stop() {
        clearTimeout(this.timer);
        this.timer = null;
        this.stream?.getTracks().forEach(track => track.stop());
        this.stream = null;
        this.torchOn = false;
        this.video.srcObject = null;
    }

    async loadDevices() {
        // Os nomes e IDs das câmeras só aparecem depois da permissão.
        const devices = await navigator.mediaDevices.enumerateDevices();
        this.devices = devices.filter(device => device.kind === 'videoinput');
        const current = this.stream?.getVideoTracks()[0]?.getSettings().deviceId;
        this.deviceIndex = this.devices.findIndex(device => device.deviceId === current);
    }

    get canSwitch() {
        return this.devices.length > 1;
    }

    async switchCamera() {
        if (!this.canSwitch) return;
        const next = this.devices[(this.deviceIndex + 1) % this.devices.length];
        await this.start(next.deviceId);
    }

    get hasTorch() {
        const track = this.stream?.getVideoTracks()[0];
        return Boolean(track?.getCapabilities?.().torch);
    }

    async toggleTorch() {
        const track = this.stream?.getVideoTracks()[0];
        if (!track || !this.hasTorch) return false;
        this.torchOn = !this.torchOn;
        await track.applyConstraints({ advanced: [{ torch: this.torchOn }] });
        return this.torchOn;
    }

    scheduleScan() {
        this.timer = setTimeout(() => this.scan(), SCAN_INTERVAL_MS);
    }

    async scan() {
        if (!this.active) return;
        try {
            const text = await this.read();
            if (text && this.onText(text) === true) {
                await this.stop();
                return;
            }
        } catch {
            // Quadro ilegível: tenta o próximo.
        }
        if (this.active) this.scheduleScan();
    }

    async read() {
        const { videoWidth: width, videoHeight: height } = this.video;
        if (!width || !height) return null;
        if (this.detector) {
            const codes = await this.detector.detect(this.video);
            return codes[0]?.rawValue ?? null;
        }
        if (typeof globalThis.jsQR !== 'function') return null;
        const scale = Math.min(1, MAX_SCAN_WIDTH / width);
        this.canvas.width = Math.round(width * scale);
        this.canvas.height = Math.round(height * scale);
        this.context.drawImage(this.video, 0, 0, this.canvas.width, this.canvas.height);
        const image = this.context.getImageData(0, 0, this.canvas.width, this.canvas.height);
        // attemptBoth: lê também QR claro sobre fundo escuro (tela em tema escuro).
        const result = globalThis.jsQR(image.data, image.width, image.height, { inversionAttempts: 'attemptBoth' });
        return result?.data ?? null;
    }
}

async function nativeDetector() {
    if (!('BarcodeDetector' in globalThis)) return null;
    try {
        const formats = await globalThis.BarcodeDetector.getSupportedFormats();
        return formats.includes('qr_code') ? new globalThis.BarcodeDetector({ formats: ['qr_code'] }) : null;
    } catch {
        return null;
    }
}
