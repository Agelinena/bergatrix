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
    
    let userId = localStorage.getItem('user_id');
    let ws;
    let currentJobId = null;
    let jobHistory = {};

    // --- Funções ---

    function generateUserId() {
        if (!userId) {
            userId = crypto.randomUUID();
            localStorage.setItem('user_id', userId);
        }
        document.cookie = `user_id=${userId}; path=/; max-age=31536000; SameSite=Lax`;
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
        
        const job = jobHistory[data.job_id] || {};

        switch(data.type) {
            case 'new_job':
                jobHistory[data.job_id] = data.job;
                break;
            case 'status_update':
                job.status = data.status;
                if (data.status === 'completed') {
                    job.transcription_simple = data.transcription_simple;
                    job.transcription_timestamp = data.transcription_timestamp;
                    if(data.job_id === currentJobId) {
                        displayTranscription(data.job_id);
                    }
                }
                if (data.status === 'failed' && data.error) {
                    job.error = data.error;
                }
                break;
        }
        renderHistory();
    }
    
    async function fetchHistory() {
        const response = await fetch(`/history/${userId}`);
        if(response.ok) {
            jobHistory = await response.json();
            renderHistory();
        }
    }

    function renderProgressBar(status) {
        const steps = {
            'queued': { label: 'Na Fila', step: 1 },
            'processing': { label: 'Processando', step: 2 },
            'transcribing': { label: 'Transcrevendo', step: 3 },
            'completed': { label: 'Concluído', step: 4 },
        };
        const failedStep = { label: 'Falhou', step: 0 };

        const current = status === 'failed' ? failedStep : (steps[status] || { label: 'Aguardando', step: 0 });
        let html = '<div class="progress-bar">';
        
        Object.values(steps).forEach(s => {
            let stateClass = '';
            if (current.step === 0) { // Falhou
                 stateClass = 'failed';
            } else if (s.step < current.step) {
                stateClass = 'done';
            } else if (s.step === current.step) {
                stateClass = 'active';
            }
            html += `<div class="progress-step ${stateClass}"><span>${s.label}</span></div>`;
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
            if (jobId === currentJobId) {
                item.classList.add('active');
            }
            item.dataset.jobId = jobId;

            item.innerHTML = `
                <div class="history-item-header">
                    <div class="history-item-title">${job.original_filename.substring(0, 40)}...</div>
                    <button class="delete-btn" data-job-id="${jobId}">&times;</button>
                </div>
                <div class="history-item-meta">
                    <span class="model-badge">🤖 ${job.model_name || 'small'}</span>
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
                            if(currentJobId === jobId) {
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
        }
    }
    
    function displayTranscription(jobId) {
        const job = jobHistory[jobId];
        if (!job || job.status !== 'completed') {
            transcriptionOutput.classList.add('hidden');
            return;
        }
        
        transcriptionTitle.textContent = `Transcrição: ${job.original_filename}`;
        simpleTextElem.textContent = job.transcription_simple;
        timestampTextElem.textContent = job.transcription_timestamp;

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

    tabButtons.forEach(button => { button.addEventListener('click', () => switchTab(button.dataset.tab)) });
    copyBtn.addEventListener('click', () => {
        const isSimpleActive = !document.getElementById('simple-content').classList.contains('hidden');
        const text = isSimpleActive ? simpleTextElem.textContent : timestampTextElem.textContent;
        navigator.clipboard.writeText(text).then(() => {
            copyBtn.textContent = 'Copiado!';
            setTimeout(() => { copyBtn.textContent = 'Copiar'; }, 2000);
        });
    });

    // --- Inicialização ---
    generateUserId();
    connectWebSocket();
    fetchHistory();
});
