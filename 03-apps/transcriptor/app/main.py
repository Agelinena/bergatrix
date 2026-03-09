import os
import uuid
import asyncio
import subprocess
import logging
from datetime import datetime, timedelta
from contextlib import asynccontextmanager
from typing import Literal
import copy # Importado para o status_updater
import gc # Importado para garbage collection

from fastapi import FastAPI, Request, UploadFile, File, Form, HTTPException, WebSocket, WebSocketDisconnect, Security, Body
from fastapi.security import APIKeyHeader
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from apscheduler.schedulers.asyncio import AsyncIOScheduler # Import re-adicionado
import aiofiles
import json
from pydantic import BaseModel
import torch
import whisper
from whisper.utils import get_writer

# --- Configuração ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
UPLOADS_DIR = os.path.join(DATA_DIR, "uploads")
TRANSCRIPTIONS_DIR = os.path.join(DATA_DIR, "transcriptions")
os.makedirs(UPLOADS_DIR, exist_ok=True); os.makedirs(TRANSCRIPTIONS_DIR, exist_ok=True)
DB_FILE = os.path.join(DATA_DIR, "transcriptions.json")

# --- Estado Global da Aplicação ---
WHISPER_MODEL = None
task_queue = asyncio.Queue()
transcription_lock = asyncio.Lock()

# --- Helpers ---
def read_db():
    try:
        with open(DB_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
            # Log size if it's getting big (e.g. > 1000 items)
            if len(data) > 1000:
                logging.warning(f"DB Warning: {len(data)} items in database.")
            return data
    except (FileNotFoundError, json.JSONDecodeError): return {}
def write_db(data):
    with open(DB_FILE, 'w', encoding='utf-8') as f: json.dump(data, f, indent=4)

async def run_command(command: list):
    process = await asyncio.create_subprocess_exec(*command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = await process.communicate()
    if process.returncode != 0: raise RuntimeError(f"Command failed with error: {stderr.decode()}")

# --- Lógica do Worker Interno ---
async def process_transcription(job_id: str, file_path: str | None, url: str | None, is_local: bool = False):
    db = read_db()
    try:
        logging.info(f"WORKER [{job_id}]: Iniciando processamento.")
        db[job_id]["status"] = "processing"; write_db(db)
        audio_path = None
        if url:
            output_template = f"{os.path.join(UPLOADS_DIR, job_id)}.%(ext)s"
            await run_command(["yt-dlp", "--no-playlist", "-x", "--audio-format", "mp3", "--output", output_template, "--", url])
            found_files = [f for f in os.listdir(UPLOADS_DIR) if f.startswith(job_id)]
            if not found_files: raise FileNotFoundError("yt-dlp não gerou arquivo.")
            audio_path = os.path.join(UPLOADS_DIR, found_files[0])
        elif file_path:
            if is_local:
                # Se for local, usamos o arquivo diretamente (assumindo que o ffmpeg pode ler)
                # Mas o whisper precisa de audio. O ffmpeg converte para mp3 temporario.
                audio_path = os.path.join(UPLOADS_DIR, f"{job_id}.mp3")
                await run_command(["ffmpeg", "-i", file_path, "-vn", "-ar", "16000", "-ac", "1", "-ab", "128k", audio_path])
                # NÃO removemos o arquivo original se for local!
            else:
                audio_path = os.path.join(UPLOADS_DIR, f"{job_id}.mp3")
                await run_command(["ffmpeg", "-i", file_path, "-vn", "-ar", "16000", "-ac", "1", "-ab", "128k", audio_path])
                os.remove(file_path)
        if not audio_path: raise ValueError("Caminho do áudio não definido.")
        db = read_db(); db[job_id]["status"] = "transcribing"; write_db(db)
        async with transcription_lock:
            logging.info(f"WORKER [{job_id}]: GPU lock adquirido.")
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(None, lambda: WHISPER_MODEL.transcribe(audio_path, verbose=False, language='pt'))
        vtt_writer = get_writer("vtt", TRANSCRIPTIONS_DIR)
        vtt_writer(result, audio_path)
        base_filename = os.path.splitext(os.path.basename(audio_path))[0]
        vtt_path = os.path.join(TRANSCRIPTIONS_DIR, f"{base_filename}.vtt")
        with open(vtt_path, 'r', encoding='utf-8') as f: vtt_content = f.read()
        simple_text = "\n".join([seg['text'].strip() for seg in result['segments']])
        db = read_db()
        db[job_id]["timestamp_path"] = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_timestamp.txt")
        db[job_id]["simple_path"] = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_simple.txt")
        with open(db[job_id]["timestamp_path"], 'w', encoding='utf-8') as f: f.write(vtt_content)
        with open(db[job_id]["simple_path"], 'w', encoding='utf-8') as f: f.write(simple_text)
        db[job_id]["status"] = "completed"
        write_db(db)
        logging.info(f"WORKER [{job_id}]: Transcrição concluída.")
        os.remove(audio_path); os.remove(vtt_path)
        gc.collect() # Force garbage collection
    except Exception as e:
        logging.error(f"WORKER [{job_id}]: Falha no processamento: {e}", exc_info=True)
        db = read_db(); db[job_id]["status"] = "failed"; write_db(db)

async def queue_consumer():
    logging.info("Consumidor de fila iniciado. Aguardando tarefas.")
    while True:
        task = await task_queue.get()
        asyncio.create_task(process_transcription(task['job_id'], task.get('file_path'), task.get('url'), task.get('is_local', False)))
        task_queue.task_done()

# --- Gerenciador de WebSocket (com rotina de atualização) ---
class ConnectionManager:
    def __init__(self): self.active_connections: dict[str, WebSocket] = {}
    async def connect(self, user_id: str, websocket: WebSocket):
        await websocket.accept(); self.active_connections[user_id] = websocket
    def disconnect(self, user_id: str):
        if user_id in self.active_connections: del self.active_connections[user_id]
    async def send_personal_message(self, message: dict, user_id: str):
        if user_id in self.active_connections:
            try: await self.active_connections[user_id].send_json(message)
            except Exception: self.disconnect(user_id)
manager = ConnectionManager()

import sys # Added sys

# ... (imports)

# --- Helpers ---
def read_db():
    try:
        with open(DB_FILE, 'r', encoding='utf-8') as f: return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError): return {}

def get_db_mtime():
    try: return os.path.getmtime(DB_FILE)
    except FileNotFoundError: return 0

def write_db(data):
    with open(DB_FILE, 'w', encoding='utf-8') as f: json.dump(data, f, indent=4)

async def run_command(command: list):
    # Pass current environment to subprocess to avoid path issues
    env = os.environ.copy()
    process = await asyncio.create_subprocess_exec(
        *command, 
        stdout=subprocess.PIPE, 
        stderr=subprocess.PIPE,
        env=env
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0: raise RuntimeError(f"Command failed with error: {stderr.decode()}")

# ... (process_transcription and queue_consumer remain same)

# ... (ConnectionManager remains same)

DB_STATE_CACHE = {}
LAST_DB_MTIME = 0

async def status_updater():
    global DB_STATE_CACHE, LAST_DB_MTIME
    logging.info("WEB: Iniciando rotina de atualização de status em tempo real.")
    DB_STATE_CACHE = read_db()
    LAST_DB_MTIME = get_db_mtime()
    
    while True:
        await asyncio.sleep(2)
        try:
            current_mtime = get_db_mtime()
            if current_mtime > LAST_DB_MTIME:
                logging.info("WEB: Detectada mudança no arquivo DB (mtime).")
                current_db = read_db()
                
                # Check for changes
                if current_db != DB_STATE_CACHE:
                    for job_id, new_details in current_db.items():
                        old_details = DB_STATE_CACHE.get(job_id, {})
                        user_id = new_details.get("user_id")
                        if new_details.get("status") != old_details.get("status") and user_id:
                            status = new_details["status"]
                            logging.info(f"WEB: Job {job_id} mudou para '{status}'. Notificando usuário {user_id}.")
                            message = {"type": "status_update", "job_id": job_id, "status": status}
                            if status == "completed":
                                try:
                                    with open(new_details['simple_path'], 'r', encoding='utf-8') as f: message['transcription_simple'] = f.read()
                                    with open(new_details['timestamp_path'], 'r', encoding='utf-8') as f: message['transcription_timestamp'] = f.read()
                                except Exception: message['status'] = 'archived'
                            await manager.send_personal_message(message, user_id)
                    
                    DB_STATE_CACHE = copy.deepcopy(current_db)
                    LAST_DB_MTIME = current_mtime
        except Exception as e: logging.error(f"WEB: Erro na rotina de atualização: {e}")

# --- Limpeza Agendada ---
def cleanup_old_files():
    logging.info("WEB: Rodando tarefa de limpeza de arquivos antigos...")
    cutoff = datetime.now() - timedelta(days=30)
    db = read_db()
    jobs_to_delete = [job_id for job_id, details in db.items() if datetime.fromisoformat(details.get("timestamp", "1970-01-01T00:00:00")) < cutoff]
    if not jobs_to_delete:
        logging.info("WEB: Nenhuma tarefa antiga para limpar.")
        return
    logging.info(f"WEB: Encontradas {len(jobs_to_delete)} tarefas antigas para remover.")
    for job_id in jobs_to_delete:
        details = db.pop(job_id, {})
        logging.info(f"WEB: Removendo job {job_id}")
        for key in ["timestamp_path", "simple_path"]:
            if (path := details.get(key)) and os.path.exists(path):
                try:
                    os.remove(path)
                    logging.info(f"WEB: Arquivo removido: {path}")
                except OSError as e:
                     logging.error(f"WEB: Erro ao remover arquivo {path}: {e}")
    write_db(db)
    logging.info(f"WEB: Limpeza de {len(jobs_to_delete)} tarefas concluída.")

async def update_ytdlp():
    logging.info("SYSTEM: Iniciando atualização diária do yt-dlp...")
    gc.collect() # Clean memory before update
    try:
        # Use --no-cache-dir to reduce memory usage during install
        await run_command([sys.executable, "-m", "pip", "install", "--upgrade", "--no-cache-dir", "yt-dlp"])
        logging.info("SYSTEM: yt-dlp atualizado com sucesso.")
    except Exception as e:
        logging.error(f"SYSTEM: Falha ao atualizar yt-dlp: {e}")

# --- Ciclo de Vida da Aplicação ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    global WHISPER_MODEL
    try:
        device = "cuda" if torch.cuda.is_available() else "cpu"
        logging.info(f"Carregando modelo Whisper no dispositivo: {device}")
        WHISPER_MODEL = whisper.load_model("small", device=device)
        logging.info("Modelo Whisper carregado com sucesso.")
    except Exception as e: logging.critical(f"NÃO FOI POSSÍVEL CARREGAR O MODELO WHISPER: {e}")
    
    # <<< MUDANÇA AQUI: Reativando o scheduler >>>
    scheduler = AsyncIOScheduler()
    scheduler.add_job(cleanup_old_files, 'interval', hours=1, misfire_grace_time=300)
    scheduler.add_job(update_ytdlp, 'cron', hour=3, minute=0, misfire_grace_time=300)
    scheduler.start()
    logging.info("WEB: Agendador de limpeza e atualização iniciado.")

    asyncio.create_task(queue_consumer())
    asyncio.create_task(status_updater())
    yield
    # Poderíamos adicionar scheduler.shutdown() aqui se necessário, mas o yield já cuida disso

app = FastAPI(lifespan=lifespan)
# O resto do arquivo (endpoints) não precisa de nenhuma alteração.
# Código completo abaixo para garantir.
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))
class APIResponse(BaseModel):
    status: str; job_id: str; transcription: str | None = None; error: str | None = None
API_KEY = os.getenv("API_KEY", "chave-secreta-padrao")
api_key_header = APIKeyHeader(name="X-API-Key")
async def get_api_key(api_key_header: str = Security(api_key_header)):
    if api_key_header != API_KEY: raise HTTPException(status_code=401, detail="Chave de API inválida.")

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request): return templates.TemplateResponse("index.html", {"request": request})

@app.post("/transcribe", status_code=202)
async def handle_transcription_request(request: Request, file: UploadFile = File(None), url: str = Form(None)):
    user_id = request.cookies.get("user_id")
    if not user_id: raise HTTPException(status_code=400, detail="User ID não encontrado.")
    job_id, original_filename, file_path = str(uuid.uuid4()), (file.filename if file and file.filename else url) or "Job", None
    if file and file.filename:
        file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")
        async with aiofiles.open(file_path, 'wb') as out_file:
            while chunk := await file.read(1024 * 1024):
                await out_file.write(chunk)
    db = read_db()
    db[job_id] = {"user_id": user_id, "original_filename": original_filename, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": url})
    await manager.send_personal_message({"type": "new_job", "job": db[job_id], "job_id": job_id}, user_id)
    return JSONResponse(content={"message": "Tarefa enfileirada!", "job_id": job_id})

@app.get("/history/{user_id}")
async def get_history(user_id: str):
    db, cutoff, user_jobs = read_db(), datetime.now() - timedelta(hours=24), {}
    for job_id, details in db.items():
        if details.get("user_id") == user_id:
            try:
                # Usa um timestamp padrão caso não exista para evitar erro
                ts_str = details.get("timestamp", "1970-01-01T00:00:00")
                if datetime.fromisoformat(ts_str) >= cutoff:
                    user_jobs[job_id] = details
            except ValueError: continue # Ignora timestamps inválidos
    for details in user_jobs.values():
        if details.get('status') == 'completed':
            try:
                # Verifica se as chaves existem antes de tentar abrir
                if (simple_path := details.get('simple_path')) and os.path.exists(simple_path):
                     with open(simple_path, 'r', encoding='utf-8') as f: details['transcription_simple'] = f.read()
                if (timestamp_path := details.get('timestamp_path')) and os.path.exists(timestamp_path):
                    with open(timestamp_path, 'r', encoding='utf-8') as f: details['transcription_timestamp'] = f.read()
            except Exception as e:
                logging.warning(f"Erro ao ler arquivos de transcrição para job {job_id}: {e}")
                details['status'] = 'archived'
    return JSONResponse(content=user_jobs)

@app.delete("/job/{job_id}", status_code=204)
async def delete_job(job_id: str, request: Request):
    user_id = request.cookies.get("user_id")
    if not user_id: raise HTTPException(status_code=403)
    db = read_db()
    job = db.get(job_id)
    if not job or job.get("user_id") != user_id: raise HTTPException(status_code=404)
    if (path := job.get("simple_path")) and os.path.exists(path):
        try: os.remove(path)
        except OSError: pass
    if (path := job.get("timestamp_path")) and os.path.exists(path):
        try: os.remove(path)
        except OSError: pass
    del db[job_id]
    write_db(db)

@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await manager.connect(user_id, websocket)
    try:
        while True: await websocket.receive_text()
    except WebSocketDisconnect: manager.disconnect(user_id)

# --- Endpoints da API (Assíncrono) ---
@app.post("/api/v1/submit", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_job(url: str = Form(...), api_key: str = Security(get_api_key)):
    job_id = str(uuid.uuid4())
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": url, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": None, "url": url})
    return APIResponse(status="queued", job_id=job_id)

@app.post("/api/v1/submit-file", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_file_job(file: UploadFile = File(...), api_key: str = Security(get_api_key)):
    job_id, original_filename = str(uuid.uuid4()), file.filename or "Job"
    file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")
    async with aiofiles.open(file_path, 'wb') as out_file:
        while chunk := await file.read(1024 * 1024):
            await out_file.write(chunk)
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": None})
    return APIResponse(status="queued", job_id=job_id)

@app.post("/api/v1/submit-local", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_local_job(file_path: str = Form(...), api_key: str = Security(get_api_key)):
    # Validate local path to prevent arbitrary file read (path traversal)
    allowed_dir = os.getenv("ROOT_DIR", "/media")
    normalized_path = os.path.abspath(file_path)
    
    if not normalized_path.startswith(allowed_dir):
        raise HTTPException(status_code=403, detail="Acesso negado: o arquivo deve estar dentro do diretório de mídia permitido.")

    if not os.path.exists(normalized_path):
        raise HTTPException(status_code=404, detail="Arquivo local não encontrado.")
    
    job_id = str(uuid.uuid4())
    original_filename = os.path.basename(normalized_path)
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": None, "is_local": True})
    return APIResponse(status="queued", job_id=job_id)

@app.get("/api/v1/result/{job_id}", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_get_result(job_id: str, timestamp_type: Literal['simple', 'timestamp'] = 'simple', api_key: str = Security(get_api_key)):
    db = read_db()
    job = db.get(job_id)
    if not job: raise HTTPException(status_code=404, detail="Job ID não encontrado.")
    status = job.get("status")
    if status != "completed": return APIResponse(status=status, job_id=job_id)
    file_path = job.get(f"{timestamp_type}_path")
    if not file_path or not os.path.exists(file_path): return APIResponse(status="failed", error="Arquivo de transcrição não encontrado.", job_id=job_id)
    async with aiofiles.open(file_path, 'r', encoding='utf-8') as f: transcription_text = await f.read()
    return APIResponse(status="completed", transcription=transcription_text, job_id=job_id)

# --- Endpoints Síncronos (Deprecated) ---
@app.post("/api/v1/transcribe", response_model=APIResponse, tags=["API V1 (Sync - Deprecated)"])
async def api_transcribe_sync(url: str = Body(..., embed=True), timestamp_type: Literal['simple', 'timestamp'] = 'simple', api_key: str = Security(get_api_key)):
    # Reutiliza a lógica de submissão
    job_id = str(uuid.uuid4())
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": url, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": None, "url": url})
    
    # Polling para esperar o resultado (timeout de 100s para evitar travar demais)
    for _ in range(50):
        await asyncio.sleep(2)
        db = read_db()
        job = db.get(job_id)
        if job and job['status'] == 'completed':
            file_path = job.get(f"{timestamp_type}_path")
            if file_path and os.path.exists(file_path):
                async with aiofiles.open(file_path, 'r', encoding='utf-8') as f: text = await f.read()
                return APIResponse(status="completed", transcription=text, job_id=job_id)
        if job and job['status'] == 'failed':
            return APIResponse(status="failed", error="Falha no processamento.", job_id=job_id)
            
    return APIResponse(status="processing", job_id=job_id, error="Timeout: Use o método assíncrono para vídeos longos.")

@app.post("/api/v1/transcribe-file", response_model=APIResponse, tags=["API V1 (Sync - Deprecated)"])
async def api_transcribe_file_sync(file: UploadFile = File(...), timestamp_type: Literal['simple', 'timestamp'] = Form('simple'), api_key: str = Security(get_api_key)):
    # Reutiliza a lógica de submissão
    job_id, original_filename = str(uuid.uuid4()), file.filename or "Job"
    file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")
    async with aiofiles.open(file_path, 'wb') as out_file:
        while chunk := await file.read(1024 * 1024):
            await out_file.write(chunk)
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": None})

    # Polling para esperar o resultado
    for _ in range(50):
        await asyncio.sleep(2)
        db = read_db()
        job = db.get(job_id)
        if job and job['status'] == 'completed':
            file_path = job.get(f"{timestamp_type}_path")
            if file_path and os.path.exists(file_path):
                async with aiofiles.open(file_path, 'r', encoding='utf-8') as f: text = await f.read()
                return APIResponse(status="completed", transcription=text, job_id=job_id)
        if job and job['status'] == 'failed':
            return APIResponse(status="failed", error="Falha no processamento.", job_id=job_id)

    return APIResponse(status="processing", job_id=job_id, error="Timeout: Use o método assíncrono para arquivos grandes.")

@app.get("/test-worker") # Mantido para testes
async def test_worker():
    job_id = "test-" + str(uuid.uuid4())
    db = read_db()
    db[job_id] = {"user_id": "tester", "original_filename": "Teste de Worker", "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": None, "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"})
    return {"message": "Tarefa de teste enviada para a fila.", "job_id": job_id}
