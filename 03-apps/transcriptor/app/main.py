import os
import re
import uuid
import asyncio
import subprocess
import logging
import sys
import copy
import gc
from datetime import datetime, timedelta
from contextlib import asynccontextmanager
from typing import Literal

import aiofiles
import json
from fastapi import FastAPI, Request, UploadFile, File, Form, HTTPException, WebSocket, WebSocketDisconnect, Security, Response
from fastapi.security import APIKeyHeader
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from pydantic import BaseModel
from itsdangerous import URLSafeSerializer, BadSignature
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

from model_manager import model_manager, VALID_MODELS

# --- Configuração ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
UPLOADS_DIR = os.path.join(DATA_DIR, "uploads")
TRANSCRIPTIONS_DIR = os.path.join(DATA_DIR, "transcriptions")
os.makedirs(UPLOADS_DIR, exist_ok=True)
os.makedirs(TRANSCRIPTIONS_DIR, exist_ok=True)
DB_FILE = os.path.join(DATA_DIR, "transcriptions.json")

DEFAULT_MODEL = "small"

# Limite de upload: 500 MB
MAX_UPLOAD_BYTES = 500 * 1024 * 1024

# --- Validação de secrets obrigatórios no startup ---
API_KEY = os.getenv("API_KEY", "")
SECRET_KEY = os.getenv("SECRET_KEY", "")

# --- Cookie Signer ---
_signer: URLSafeSerializer | None = None

def get_signer() -> URLSafeSerializer:
    if _signer is None:
        raise RuntimeError("Signer não inicializado.")
    return _signer

def sign_user_id(user_id: str) -> str:
    return get_signer().dumps(user_id)

def verify_user_id(signed: str) -> str | None:
    """Verifica a assinatura e retorna o user_id limpo, ou None se inválido."""
    try:
        value = get_signer().loads(signed)
        # Garante que é um UUID válido
        uuid.UUID(str(value))
        return str(value)
    except (BadSignature, ValueError, AttributeError):
        return None

def get_signed_user_id(request: Request) -> str | None:
    """Extrai e valida o user_id assinado do cookie."""
    signed = request.cookies.get("user_id")
    if not signed:
        return None
    return verify_user_id(signed)

# --- Sanitização de mensagens de erro ---
_INTERNAL_PATH_RE = re.compile(r'/[a-zA-Z0-9_./-]{3,}')

def sanitize_error(msg: str) -> str:
    """Remove paths internos de mensagens de erro antes de expor ao cliente."""
    sanitized = _INTERNAL_PATH_RE.sub('[path]', str(msg))
    return sanitized[:400]  # trunca para não vazar stacks longas

# --- Validação de URL (anti-SSRF) ---
_ALLOWED_URL_SCHEMES = ('http://', 'https://')

def validate_url(url: str) -> str:
    """Garante que a URL usa apenas http/https e não é uma URL local."""
    u = url.strip()
    if not any(u.lower().startswith(s) for s in _ALLOWED_URL_SCHEMES):
        raise HTTPException(status_code=400, detail="URL inválida. Apenas http:// e https:// são permitidos.")
    # Bloqueia IPs locais / loopback / metadados de cloud
    blocked = ('localhost', '127.', '0.0.0.0', '169.254.', '::1', 'metadata.google', 'metadata.aws')
    lower = u.lower()
    if any(b in lower for b in blocked):
        raise HTTPException(status_code=400, detail="URL aponta para endereço não permitido.")
    return u

# --- Fila, Lock GPU e Lock do DB ---
task_queue = asyncio.Queue()
transcription_lock = asyncio.Lock()
db_lock = asyncio.Lock()

# --- Rate Limiter ---
limiter = Limiter(key_func=get_remote_address)

# --- Helpers DB ---
def _read_db_sync() -> dict:
    try:
        with open(DB_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
            if len(data) > 1000:
                logging.warning(f"DB Warning: {len(data)} items in database.")
            return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def _write_db_sync(data: dict):
    with open(DB_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4)

def read_db() -> dict:
    return _read_db_sync()

def write_db(data: dict):
    _write_db_sync(data)

async def read_db_safe() -> dict:
    async with db_lock:
        return _read_db_sync()

async def write_db_safe(data: dict):
    async with db_lock:
        _write_db_sync(data)

def get_db_mtime() -> float:
    try:
        return os.path.getmtime(DB_FILE)
    except FileNotFoundError:
        return 0

async def run_command(command: list):
    env = os.environ.copy()
    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(f"Command failed: {stderr.decode()[:200]}")


# --- Lógica do Worker ---
async def process_transcription(
    job_id: str,
    file_path: str | None,
    url: str | None,
    is_local: bool = False,
    model_name: str = DEFAULT_MODEL
):
    db = await read_db_safe()
    try:
        logging.info(f"WORKER [{job_id}]: Iniciando com modelo '{model_name}'.")
        db[job_id]["status"] = "processing"
        await write_db_safe(db)

        audio_path = None
        if url:
            output_template = f"{os.path.join(UPLOADS_DIR, job_id)}.%(ext)s"
            await run_command(["yt-dlp", "--force-ipv4", "--no-playlist", "-x", "--audio-format", "mp3", "--output", output_template, "--", url])
            found_files = [f for f in os.listdir(UPLOADS_DIR) if f.startswith(job_id)]
            if not found_files:
                raise FileNotFoundError("yt-dlp não gerou arquivo.")
            audio_path = os.path.join(UPLOADS_DIR, found_files[0])
        elif file_path:
            audio_path = os.path.join(UPLOADS_DIR, f"{job_id}.mp3")
            await run_command(["ffmpeg", "-i", file_path, "-vn", "-ar", "16000", "-ac", "1", "-ab", "128k", audio_path])
            if not is_local:
                os.remove(file_path)

        if not audio_path:
            raise ValueError("Caminho do áudio não definido.")

        db = await read_db_safe()
        db[job_id]["status"] = "transcribing"
        await write_db_safe(db)

        async with transcription_lock:
            logging.info(f"WORKER [{job_id}]: GPU lock adquirido. Carregando '{model_name}'...")
            loop = asyncio.get_event_loop()

            try:
                def transcribe():
                    model = model_manager.load(model_name)
                    segments_gen, info = model.transcribe(
                        audio_path,
                        language="pt",
                        task="transcribe",
                        beam_size=1 if model_name == "large-v3" else 2,
                        best_of=1 if model_name == "large-v3" else 2,
                        vad_filter=True,
                        vad_parameters=dict(min_silence_duration_ms=400, speech_pad_ms=100),
                        initial_prompt="Transcrição fiel em português do Brasil. Sem tradução. Mantendo a pontuação natural.",
                        condition_on_previous_text=False,
                        without_timestamps=False, # Requer timestamps lineares pelo VTT
                        no_speech_threshold=0.6,
                        temperature=0
                    )
                    
                    # Preparar os arquivos de saída AQUI mesmo, para escrever imediatamente
                    timestamp_path = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_timestamp.vtt")
                    simple_path = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_simple.txt")

                    with open(timestamp_path, 'w', encoding='utf-8') as f_vtt, \
                         open(simple_path, 'w', encoding='utf-8') as f_txt:
                        
                        f_vtt.write("WEBVTT\n\n")
                        current_paragraph = ""

                        # For loop consume o generator 1 a 1, sem encher a RAM inteira.
                        for seg in segments_gen:
                            start_str = _format_vtt_time(seg.start)
                            end_str = _format_vtt_time(seg.end)
                            
                            # Escreve logo pro VTT
                            f_vtt.write(f"{start_str} --> {end_str}\n")
                            f_vtt.write(f"{seg.text.strip()}\n\n")
                            f_vtt.flush()
                            
                            text_chunk = seg.text.strip()
                            if len(current_paragraph) + len(text_chunk) < 300:
                                current_paragraph += " " + text_chunk
                            else:
                                f_txt.write(current_paragraph.strip() + "\n\n")
                                f_txt.flush()
                                current_paragraph = text_chunk
                                
                        if current_paragraph:
                            f_txt.write(current_paragraph.strip() + "\n\n")
                            
                    return timestamp_path, simple_path
                            

                # Executa toda a transcrição E A ESCRITA NO DISCO de forma assíncrona longe do event loop principal
                timestamp_path, simple_path = await loop.run_in_executor(None, transcribe)

            except RuntimeError as e:
                error_message = sanitize_error(str(e))
                logging.error(f"WORKER [{job_id}]: Falha de GPU: {e}")
                db = await read_db_safe()
                db[job_id]["status"] = "failed"
                db[job_id]["error"] = error_message
                await write_db_safe(db)
                raise
                
        # Fora do Lock (após liberação de disco)
        db = await read_db_safe()
        db[job_id].update({
            "timestamp_path": timestamp_path,
            "simple_path": simple_path,
            "status": "completed",
            "completed_at": datetime.now().isoformat()
        })
        await write_db_safe(db)
        logging.info(f"WORKER [{job_id}]: Concluído.")
        os.remove(audio_path)
        gc.collect()

    except Exception as e:
        logging.error(f"WORKER [{job_id}]: Falha: {e}", exc_info=True)
        db = await read_db_safe()
        if job_id in db:
            db[job_id]["status"] = "failed"
            db[job_id]["error"] = sanitize_error(str(e))
            await write_db_safe(db)


def _format_vtt_time(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"


async def queue_consumer():
    logging.info("Queue consumer iniciado.")
    while True:
        task = await task_queue.get()
        asyncio.create_task(process_transcription(
            task['job_id'],
            task.get('file_path'),
            task.get('url'),
            task.get('is_local', False),
            task.get('model_name', DEFAULT_MODEL)
        ))
        task_queue.task_done()


# --- WebSocket Manager ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, WebSocket] = {}

    async def connect(self, user_id: str, websocket: WebSocket):
        await websocket.accept()
        self.active_connections[user_id] = websocket

    def disconnect(self, user_id: str):
        self.active_connections.pop(user_id, None)

    async def send_personal_message(self, message: dict, user_id: str):
        ws = self.active_connections.get(user_id)
        if ws:
            try:
                await ws.send_json(message)
            except Exception:
                self.disconnect(user_id)


manager = ConnectionManager()
DB_STATE_CACHE: dict = {}
LAST_DB_MTIME: float = 0


async def status_updater():
    global DB_STATE_CACHE, LAST_DB_MTIME
    logging.info("Status updater iniciado.")
    DB_STATE_CACHE = await read_db_safe()   # ← usa lock
    LAST_DB_MTIME = get_db_mtime()

    while True:
        await asyncio.sleep(2)
        try:
            current_mtime = get_db_mtime()
            if current_mtime > LAST_DB_MTIME:
                current_db = await read_db_safe()   # ← usa lock
                if current_db != DB_STATE_CACHE:
                    for job_id, new_details in current_db.items():
                        old_details = DB_STATE_CACHE.get(job_id, {})
                        user_id = new_details.get("user_id")
                        if new_details.get("status") != old_details.get("status") and user_id:
                            status = new_details["status"]
                            message = {
                                "type": "status_update",
                                "job_id": job_id,
                                "status": status,
                                "completed_at": new_details.get("completed_at")
                            }
                            if status == "completed":
                                try:
                                    with open(new_details['simple_path'], 'r', encoding='utf-8') as f:
                                        message['transcription_simple'] = f.read()
                                    with open(new_details['timestamp_path'], 'r', encoding='utf-8') as f:
                                        message['transcription_timestamp'] = f.read()
                                except Exception:
                                    message['status'] = 'archived'
                            if status == "failed":
                                message['error'] = new_details.get('error', 'Erro desconhecido.')
                            await manager.send_personal_message(message, user_id)
                    DB_STATE_CACHE = copy.deepcopy(current_db)
                    LAST_DB_MTIME = current_mtime
        except Exception as e:
            logging.error(f"Status updater erro: {e}")


# --- Limpeza Agendada ---
def cleanup_old_files():
    cutoff = datetime.now() - timedelta(days=30)
    db = read_db()
    jobs_to_delete = [
        jid for jid, d in db.items()
        if datetime.fromisoformat(d.get("timestamp", "1970-01-01T00:00:00")) < cutoff
    ]
    for jid in jobs_to_delete:
        d = db.pop(jid, {})
        for key in ["timestamp_path", "simple_path"]:
            if (path := d.get(key)) and os.path.exists(path):
                try:
                    os.remove(path)
                except OSError as e:
                    logging.error(f"Cleanup erro {path}: {e}")
    if jobs_to_delete:
        write_db(db)
        logging.info(f"Cleanup: {len(jobs_to_delete)} tarefas removidas.")


async def update_ytdlp():
    logging.info("SYSTEM: Atualizando yt-dlp...")
    try:
        await run_command([sys.executable, "-m", "pip", "install", "--upgrade", "--no-cache-dir", "yt-dlp"])
        logging.info("SYSTEM: yt-dlp atualizado.")
    except Exception as e:
        logging.error(f"SYSTEM: Falha ao atualizar yt-dlp: {e}")


# --- Ciclo de Vida ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    global _signer

    # Validação de secrets obrigatórios
    if not API_KEY:
        raise RuntimeError("FATAL: variável de ambiente 'API_KEY' não definida. Aborting.")
    if not SECRET_KEY:
        raise RuntimeError("FATAL: variável de ambiente 'SECRET_KEY' não definida. Aborting.")

    _signer = URLSafeSerializer(SECRET_KEY, salt="transcriptor-user-id")
    logging.info("STARTUP: Signer inicializado.")

    logging.info(f"STARTUP: Pré-carregando modelo '{DEFAULT_MODEL}'...")
    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, lambda: model_manager.load(DEFAULT_MODEL))
        logging.info("STARTUP: Modelo padrão carregado.")
    except Exception as e:
        logging.critical(f"STARTUP: Falha ao carregar modelo: {e}", exc_info=True)

    scheduler = AsyncIOScheduler()
    scheduler.add_job(cleanup_old_files, 'interval', hours=1, misfire_grace_time=300)
    scheduler.add_job(update_ytdlp, 'cron', hour=3, minute=0, misfire_grace_time=300)
    scheduler.start()

    asyncio.create_task(queue_consumer())
    asyncio.create_task(status_updater())
    yield


# --- App ---
app = FastAPI(lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

api_key_header = APIKeyHeader(name="X-API-Key")


class APIResponse(BaseModel):
    status: str
    job_id: str
    transcription: str | None = None
    error: str | None = None


async def get_api_key(api_key_header: str = Security(api_key_header)):
    if api_key_header != API_KEY:
        raise HTTPException(status_code=401, detail="Chave de API inválida.")


# --- Session ---
@app.get("/init-session")
async def init_session(request: Request, response: Response):
    """Gera um user_id autenticado via cookie assinado (server-side)."""
    # Reutiliza sessão existente e válida
    existing = get_signed_user_id(request)
    if existing:
        return JSONResponse({"user_id": existing})

    new_user_id = str(uuid.uuid4())
    signed = sign_user_id(new_user_id)
    resp = JSONResponse({"user_id": new_user_id})
    resp.set_cookie(
        key="user_id",
        value=signed,
        max_age=31536000,
        httponly=True,       # não acessível via JS — previne XSS
        samesite="lax",
        secure=True,         # apenas HTTPS
        path="/"
    )
    return resp


# --- Endpoints Web ---
@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "valid_models": VALID_MODELS})


@app.post("/transcribe", status_code=202)
@limiter.limit("5/minute")
async def handle_transcription_request(
    request: Request,
    file: UploadFile = File(None),
    url: str = Form(None),
    model_name: str = Form(DEFAULT_MODEL)
):
    user_id = get_signed_user_id(request)
    if not user_id:
        raise HTTPException(status_code=401, detail="Sessão inválida ou expirada. Recarregue a página.")

    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")

    # Validação de URL (anti-SSRF)
    if url:
        url = validate_url(url)

    job_id = str(uuid.uuid4())
    file_path = None

    if file and file.filename:
        # [FIX] Path traversal: usar apenas o basename, nunca o path completo
        safe_filename = os.path.basename(file.filename)
        if not safe_filename:
            raise HTTPException(status_code=400, detail="Nome de arquivo inválido.")

        original_filename: str = safe_filename[:200]
        file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")

        # [FIX] Limite de tamanho: lê em chunks e rejeita se exceder
        bytes_written = 0
        async with aiofiles.open(file_path, 'wb') as out_file:
            while chunk := await file.read(1024 * 1024):
                bytes_written += len(chunk)
                if bytes_written > MAX_UPLOAD_BYTES:
                    await out_file.close()
                    os.remove(file_path)
                    raise HTTPException(status_code=413, detail=f"Arquivo excede o limite de {MAX_UPLOAD_BYTES // 1024 // 1024}MB.")
                await out_file.write(chunk)
    else:
        original_filename = (url or "Job")[:200]

    db = await read_db_safe()
    db[job_id] = {
        "user_id": user_id,
        "original_filename": original_filename,
        "model_name": model_name,
        "status": "queued",
        "timestamp": datetime.now().isoformat()
    }
    await write_db_safe(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": url, "model_name": model_name})
    await manager.send_personal_message({"type": "new_job", "job": db[job_id], "job_id": job_id}, user_id)
    return JSONResponse(content={"message": "Tarefa enfileirada!", "job_id": job_id})


@app.get("/history/{user_id}")
async def get_history(user_id: str, request: Request):
    # [FIX] IDOR: só retorna histórico do user_id autenticado pelo cookie
    authed_user_id = get_signed_user_id(request)
    if not authed_user_id or authed_user_id != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado.")

    db = await read_db_safe()
    cutoff = datetime.now() - timedelta(hours=24)
    user_jobs = {}
    for job_id, details in db.items():
        if details.get("user_id") == user_id:
            try:
                if datetime.fromisoformat(details.get("timestamp", "1970-01-01T00:00:00")) >= cutoff:
                    user_jobs[job_id] = details
            except ValueError:
                continue
    for details in user_jobs.values():
        if details.get('status') == 'completed':
            try:
                if (p := details.get('simple_path')) and os.path.exists(p):
                    with open(p, 'r', encoding='utf-8') as f:
                        details['transcription_simple'] = f.read()
                if (p := details.get('timestamp_path')) and os.path.exists(p):
                    with open(p, 'r', encoding='utf-8') as f:
                        details['transcription_timestamp'] = f.read()
            except Exception:
                details['status'] = 'archived'
    return JSONResponse(content=user_jobs)


@app.delete("/job/{job_id}", status_code=204)
async def delete_job(job_id: str, request: Request):
    user_id = get_signed_user_id(request)
    if not user_id:
        raise HTTPException(status_code=401)
    db = await read_db_safe()
    job = db.get(job_id)
    if not job or job.get("user_id") != user_id:
        raise HTTPException(status_code=404)
    for key in ["simple_path", "timestamp_path"]:
        if (path := job.get(key)) and os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass
    del db[job_id]
    await write_db_safe(db)


@app.get("/download/{job_id}/simple")
async def download_simple(job_id: str, request: Request):
    """Download da transcrição em texto simples (.txt)."""
    # [FIX] IDOR: verifica autoria do job via cookie assinado
    user_id = get_signed_user_id(request)
    if not user_id:
        raise HTTPException(status_code=401, detail="Sessão inválida.")
    db = await read_db_safe()
    job = db.get(job_id)
    if not job:
        raise HTTPException(status_code=404)
    if job.get("user_id") != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado.")
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Transcrição ainda não concluída.")
    path = job.get("simple_path")
    if not path or not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Arquivo não encontrado.")
    original = job.get("original_filename", "transcricao")
    safe_name = "".join(c for c in os.path.splitext(original)[0] if c.isalnum() or c in " _-")[:60].strip()
    return FileResponse(path, media_type="text/plain; charset=utf-8", filename=f"{safe_name or 'transcricao'}_simples.txt")


@app.get("/download/{job_id}/timestamp")
async def download_timestamp(job_id: str, request: Request):
    """Download da transcrição com timestamps no formato WebVTT (.vtt)."""
    user_id = get_signed_user_id(request)
    if not user_id:
        raise HTTPException(status_code=401, detail="Sessão inválida.")
    db = await read_db_safe()
    job = db.get(job_id)
    if not job:
        raise HTTPException(status_code=404)
    if job.get("user_id") != user_id:
        raise HTTPException(status_code=403, detail="Acesso negado.")
    if job.get("status") != "completed":
        raise HTTPException(status_code=409, detail="Transcrição ainda não concluída.")
    path = job.get("timestamp_path")
    if not path or not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Arquivo não encontrado.")
    original = job.get("original_filename", "transcricao")
    safe_name = "".join(c for c in os.path.splitext(original)[0] if c.isalnum() or c in " _-")[:60].strip()
    return FileResponse(path, media_type="text/vtt; charset=utf-8", filename=f"{safe_name or 'transcricao'}_timestamps.vtt")


@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    # [FIX] IDOR: valida que o user_id do path corresponde ao cookie assinado
    signed = websocket.cookies.get("user_id")
    verified = verify_user_id(signed) if signed else None
    if not verified or verified != user_id:
        await websocket.close(code=4001)
        logging.warning(f"WS: Tentativa de conexão não autorizada para user_id={user_id}")
        return

    await manager.connect(user_id, websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(user_id)


# --- Endpoints API v1 (Async) ---
@app.post("/api/v1/submit", response_model=APIResponse, tags=["API V1 (Async)"])
@limiter.limit("10/minute")
async def api_submit_job(
    request: Request,
    url: str = Form(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")
    url = validate_url(url)
    job_id = str(uuid.uuid4())
    db = await read_db_safe()
    db[job_id] = {"user_id": "api_user", "original_filename": url[:200], "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    await write_db_safe(db)
    await task_queue.put({"job_id": job_id, "file_path": None, "url": url, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.post("/api/v1/submit-file", response_model=APIResponse, tags=["API V1 (Async)"])
@limiter.limit("10/minute")
async def api_submit_file_job(
    request: Request,
    file: UploadFile = File(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")

    safe_filename = os.path.basename(file.filename or "upload")[:200]
    file_path = os.path.join(UPLOADS_DIR, f"{str(uuid.uuid4())}_{safe_filename}")

    bytes_written = 0
    job_id = str(uuid.uuid4())
    async with aiofiles.open(file_path, 'wb') as out_file:
        while chunk := await file.read(1024 * 1024):
            bytes_written += len(chunk)
            if bytes_written > MAX_UPLOAD_BYTES:
                await out_file.close()
                os.remove(file_path)
                raise HTTPException(status_code=413, detail="Arquivo muito grande.")
            await out_file.write(chunk)

    db = await read_db_safe()
    db[job_id] = {"user_id": "api_user", "original_filename": safe_filename, "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    await write_db_safe(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": None, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.post("/api/v1/submit-local", response_model=APIResponse, tags=["API V1 (Async)"])
@limiter.limit("10/minute")
async def api_submit_local_job(
    request: Request,
    file_path: str = Form(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")

    allowed_dir = os.getenv("ROOT_DIR", "/media")
    normalized_path = os.path.abspath(file_path)

    # [FIX] Usar os.sep para evitar bypass com "/mediaevil/..."
    if not normalized_path.startswith(allowed_dir.rstrip(os.sep) + os.sep):
        raise HTTPException(status_code=403, detail="Acesso negado.")
    if not os.path.isfile(normalized_path):
        raise HTTPException(status_code=404, detail="Arquivo local não encontrado.")

    job_id = str(uuid.uuid4())
    original_filename = os.path.basename(normalized_path)
    db = await read_db_safe()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    await write_db_safe(db)
    await task_queue.put({"job_id": job_id, "file_path": normalized_path, "url": None, "is_local": True, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.get("/api/v1/result/{job_id}", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_get_result(
    job_id: str,
    timestamp_type: Literal['simple', 'timestamp'] = 'simple',
    api_key: str = Security(get_api_key)
):
    db = await read_db_safe()
    job = db.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job ID não encontrado.")
    status = job.get("status")
    if status != "completed":
        return APIResponse(status=status, job_id=job_id, error=job.get("error"))
    file_path = job.get(f"{timestamp_type}_path")
    if not file_path or not os.path.exists(file_path):
        return APIResponse(status="failed", error="Arquivo não encontrado.", job_id=job_id)
    async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
        transcription_text = await f.read()
    return APIResponse(status="completed", transcription=transcription_text, job_id=job_id)
