document.addEventListener('DOMContentLoaded', () => {
    // --- Variáveis Globais ---
    const form = document.getElementById('upload-form');
    const submitBtn = document.getElementById('submit-btn');
    const historyList = document.getElementById('history-list');
    const transcriptionOutput = document.getElementById('transcription-output');
    const transcriptionTitle = document.getElementById('transcription-title');
    const simpleTextElem = document.getElementById('simple-text');
    const timestampTextElem = document.getElementById('timestamp-text');
    const copyBtn = document.querySelector('.copy-btn');
    const tabButtons = document.querySelectorAll('.tab-buttons button');
    const waveformIcon = document.querySelector('.waveform-icon');

    let userId = localStorage.getItem('user_id');
    let ws;
    let currentJobId = null;
    let jobHistory = {};

    // Cronômetros: jobId -> { interval, startEpoch }
    const timers = {};

    // --- Funções ---

    async function initSession() {
        // Se já temos um userId em localStorage e o cookie ainda é válido, reutiliza.
        // Caso contrário, pede ao servidor para criar um novo.
        try {
            const response = await fetch('/init-session', { credentials: 'same-origin' });
            if (!response.ok) throw new Error('Falha ao iniciar sessão.');
            const data = await response.json();
            userId = data.user_id;
            localStorage.setItem('user_id', userId);
        } catch (err) {
            console.error('Session init failed:', err);
            document.body.innerHTML = '<main class="container"><article><p>⚠️ Não foi possível iniciar a sessão. Recarregue a página.</p></article></main>';
            throw err; // Aborta o restante da inicialização
        }
    }

    function connectWebSocket() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        ws = new WebSocket(`${protocol}//${window.location.host}/ws/${userId}`);

        ws.onopen = () => console.log('WebSocket conectado.');
        ws.onclose = () => {
            console.log('WebSocket desconectado. Tentando reconectar em 3s...');
            setTimeout(connectWebSocket, 3000);
        };
        ws.onerror = (error) => console.error('WebSocket Error:', error);
        ws.onmessage = handleWebSocketMessage;
    }

    function handleWebSocketMessage(event) {
        const data = JSON.parse(event.data);
        console.log("WS Message:", data);

        if (!jobHistory[data.job_id]) {
            jobHistory[data.job_id] = {};
        }
        const job = jobHistory[data.job_id];

        switch(data.type) {
            case 'new_job':
                jobHistory[data.job_id] = data.job;
                startTimer(data.job_id, data.job.timestamp);
                break;
            case 'status_update':
                job.status = data.status;
                if (data.status === 'completed') {
                    job.transcription_simple = data.transcription_simple;
                    job.transcription_timestamp = data.transcription_timestamp;
                    job.completed_at = data.completed_at;
                    stopTimer(data.job_id);
                    if (data.job_id === currentJobId) {
                        displayTranscription(data.job_id);
                    }
                }
                if (data.status === 'failed') {
                    if (data.error) job.error = data.error;
                    stopTimer(data.job_id);
                }
                if (data.status.startsWith('processing') || data.status.startsWith('transcribing')) {
                    setWaveformActive(true);
                } else {
                    const hasActiveJob = Object.values(jobHistory).some(j =>
                        j.status.startsWith('queued') || j.status.startsWith('processing') || j.status.startsWith('transcribing')
                    );
                    setWaveformActive(hasActiveJob);
                }
                break;
        }
        renderHistory();
    }

    function setWaveformActive(active) {
        if (waveformIcon) {
            waveformIcon.classList.toggle('active', active);
        }
    }

    // --- Timer ---
    function startTimer(jobId, startIso) {
        if (timers[jobId]) return; // já existe
        const startEpoch = startIso ? new Date(startIso).getTime() : Date.now();
        timers[jobId] = { startEpoch, interval: null };
        timers[jobId].interval = setInterval(() => {
            const elapsed = Math.floor((Date.now() - startEpoch) / 1000);
            const el = document.querySelector(`[data-job-id="${jobId}"] .job-timer`);
            if (el) el.textContent = formatElapsed(elapsed);
        }, 1000);
    }

    function stopTimer(jobId) {
        if (timers[jobId]) {
            clearInterval(timers[jobId].interval);
            delete timers[jobId];
        }
    }

    function formatElapsed(seconds) {
        const m = Math.floor(seconds / 60).toString().padStart(2, '0');
        const s = (seconds % 60).toString().padStart(2, '0');
        return `${m}:${s}`;
    }

    function getElapsedText(job) {
        if (job.status === 'completed' && job.timestamp && job.completed_at) {
            const elapsed = Math.floor((new Date(job.completed_at) - new Date(job.timestamp)) / 1000);
            return `✅ ${formatElapsed(elapsed)}`;
        }
        if (job.status === 'failed') return '❌';
        if (job.status.startsWith('queued') || job.status.startsWith('processing') || job.status.startsWith('transcribing')) {
            const elapsed = Math.floor((Date.now() - new Date(job.timestamp).getTime()) / 1000);
            return formatElapsed(elapsed);
        }
        return '';
    }

    async function fetchHistory() {
        const response = await fetch(`/history/${userId}`);
        if (response.ok) {
            jobHistory = await response.json();
            // Iniciar timers para jobs ativos
            for (const [jobId, job] of Object.entries(jobHistory)) {
                if (job.status.startsWith('queued') || job.status.startsWith('processing') || job.status.startsWith('transcribing')) {
                    startTimer(jobId, job.timestamp);
                }
            }
            const hasActive = Object.values(jobHistory).some(j =>
                j.status.startsWith('queued') || j.status.startsWith('processing') || j.status.startsWith('transcribing')
            );
            setWaveformActive(hasActive);
            renderHistory();
        }
    }

    function renderProgressBar(status) {
        const steps = {
            'queued':      { label: 'Na Fila',      step: 1 },
            'processing':  { label: 'Áudio',         step: 2 },
            'transcribing':{ label: 'Transcrevendo', step: 3 },
            'completed':   { label: 'Concluído',     step: 4 },
        };
        const failedStep = { label: 'Falhou', step: 0 };
        
        let current = { label: 'Aguardando', step: 0 };
        let targetStepLabel = 'Aguardando';

        if (status.startsWith('queued')) { 
            current = steps['queued']; 
            targetStepLabel = steps['queued'].label; 
        } else if (status.startsWith('processing')) { 
            current = steps['processing']; 
            targetStepLabel = steps['processing'].label; 
        } else if (status.startsWith('transcribing')) { 
            current = steps['transcribing'];
            const match = status.match(/transcribing \((.*?)\)/);
            if (match) {
                targetStepLabel = `Transcrevendo (${match[1]})`;
            } else {
                targetStepLabel = steps['transcribing'].label;
            }
        } else if (status === 'completed') { 
            current = steps['completed']; 
            targetStepLabel = steps['completed'].label; 
        } else if (status === 'failed') { 
            current = failedStep; 
            targetStepLabel = failedStep.label; 
        } else {
            current = failedStep;
            targetStepLabel = failedStep.label;
        }

        let html = '<div class="progress-bar">';
        Object.values(steps).forEach(s => {
            let stateClass = '';
            let displayLabel = s.label;
            if (current.step === 0) {
                stateClass = 'failed';
            } else if (s.step < current.step) {
                stateClass = 'done';
            } else if (s.step === current.step) {
                stateClass = 'active';
                displayLabel = current.step === 3 ? targetStepLabel : s.label;
            }
            html += `<div class="progress-step ${stateClass}"><span>${displayLabel}</span></div>`;
        });
        html += '</div>';
        return html;
    }

    function renderHistory() {
        historyList.innerHTML = '';
        const sortedJobs = Object.entries(jobHistory).sort(([,a], [,b]) => new Date(b.timestamp) - new Date(a.timestamp));

        if (sortedJobs.length === 0) {
            historyList.innerHTML = '<p>Nenhuma transcrição recente.</p>';
            return;
        }

        for (const [jobId, job] of sortedJobs) {
            const item = document.createElement('div');
            item.className = 'history-item';
            if (jobId === currentJobId) item.classList.add('active');
            item.dataset.jobId = jobId;

            const filename = (job.original_filename || 'Job');
            const displayName = filename.length > 42 ? filename.substring(0, 42) + '…' : filename;
            const elapsedText = getElapsedText(job);

            item.innerHTML = `
                <div class="history-item-header">
                    <div class="history-item-title" title="${filename}">${displayName}</div>
                    <button class="delete-btn" data-job-id="${jobId}">&times;</button>
                </div>
                <div class="history-item-meta">
                    <span class="model-badge">🤖 ${job.model_name || 'small'}</span>
                    ${elapsedText ? `<span class="job-timer">${elapsedText}</span>` : ''}
                </div>
                ${renderProgressBar(job.status)}
                ${job.status === 'failed' && job.error ? `<p class="error-msg">⚠️ ${job.error.substring(0, 120)}</p>` : ''}
            `;

            item.addEventListener('click', (e) => {
                if (e.target.classList.contains('delete-btn')) return;
                currentJobId = jobId;
                displayTranscription(jobId);
                renderHistory();
            });

            const deleteBtn = item.querySelector('.delete-btn');
            deleteBtn.addEventListener('click', async (e) => {
                e.stopPropagation();
                if (confirm('Tem certeza que deseja remover esta transcrição?')) {
                    try {
                        const response = await fetch(`/job/${jobId}`, { method: 'DELETE' });
                        if (response.ok) {
                            delete jobHistory[jobId];
                            stopTimer(jobId);
                            if (currentJobId === jobId) {
                                transcriptionOutput.classList.add('hidden');
                                currentJobId = null;
                            }
                            renderHistory();
                        } else {
                            alert('Não foi possível remover a transcrição.');
                        }
                    } catch (error) {
                        console.error('Erro ao deletar:', error);
                        alert('Erro de rede ao tentar remover a transcrição.');
                    }
                }
            });
            historyList.appendChild(item);

            // Iniciar timer dinâmico se job ainda ativo
            if ((job.status.startsWith('queued') || job.status.startsWith('processing') || job.status.startsWith('transcribing')) && !timers[jobId]) {
                startTimer(jobId, job.timestamp);
            }
        }
    }

    function displayTranscription(jobId) {
        const job = jobHistory[jobId];
        if (!job || job.status !== 'completed') {
            transcriptionOutput.classList.add('hidden');
            return;
        }

        transcriptionTitle.textContent = `Transcrição: ${job.original_filename || 'Job'}`;
        simpleTextElem.textContent = job.transcription_simple || '';
        timestampTextElem.textContent = job.transcription_timestamp || '';

        document.getElementById('download-simple').href = `/download/${jobId}/simple`;
        document.getElementById('download-timestamp').href = `/download/${jobId}/timestamp`;

        transcriptionOutput.classList.remove('hidden');
        switchTab('simple');
    }

    function switchTab(tabName) {
        document.querySelectorAll('.transcription-content').forEach(el => el.classList.add('hidden'));
        document.querySelectorAll('.tab-buttons button').forEach(el => el.classList.add('outline'));
        document.querySelectorAll('a[download]').forEach(el => el.classList.add('hidden'));

        document.getElementById(`${tabName}-content`).classList.remove('hidden');
        document.querySelector(`button[data-tab="${tabName}"]`).classList.remove('outline');
        document.getElementById(`download-${tabName}`).classList.remove('hidden');
    }

    form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const formData = new FormData(form);
        const file = formData.get('file');
        const url = formData.get('url');
        if (!file.size && !url) {
            alert('Por favor, selecione um arquivo ou insira uma URL.');
            return;
        }

        submitBtn.setAttribute('aria-busy', 'true');
        submitBtn.disabled = true;

        try {
            const response = await fetch('/transcribe', { method: 'POST', body: formData });
            if (response.ok) {
                form.reset();
            } else {
                const result = await response.json();
                alert(`Erro: ${result.detail || 'Ocorreu um problema.'}`);
            }
        } catch (error) {
            console.error('Falha ao enviar:', error);
            alert('Ocorreu um erro ao enviar a tarefa.');
        } finally {
            submitBtn.setAttribute('aria-busy', 'false');
            submitBtn.disabled = false;
        }
    });

    tabButtons.forEach(button => {
        button.addEventListener('click', () => switchTab(button.dataset.tab));
    });

    copyBtn.addEventListener('click', () => {
        const isSimpleActive = !document.getElementById('simple-content').classList.contains('hidden');
        const text = isSimpleActive ? simpleTextElem.textContent : timestampTextElem.textContent;
        navigator.clipboard.writeText(text).then(() => {
            copyBtn.textContent = 'Copiado!';
            setTimeout(() => { copyBtn.textContent = 'Copiar'; }, 2000);
        });
    });

    // --- Inicialização ---
    // initSession é async: aguarda o cookie assinado ser atribuído pelo servidor
    // antes de abrir WebSocket e buscar histórico.
    (async () => {
        await initSession();
        connectWebSocket();
        fetchHistory();
    })();
});
