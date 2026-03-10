import os
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

import torch
import aiofiles
import json
from fastapi import FastAPI, Request, UploadFile, File, Form, HTTPException, WebSocket, WebSocketDisconnect, Security, Body
from fastapi.security import APIKeyHeader
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from pydantic import BaseModel

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

# --- Fila e Lock ---
task_queue = asyncio.Queue()
transcription_lock = asyncio.Lock()

# --- Helpers ---
def read_db():
    try:
        with open(DB_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
            if len(data) > 1000:
                logging.warning(f"DB Warning: {len(data)} items in database.")
            return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def write_db(data):
    with open(DB_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4)

def get_db_mtime():
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
        raise RuntimeError(f"Command failed with error: {stderr.decode()}")


# --- Lógica do Worker Interno ---
async def process_transcription(job_id: str, file_path: str | None, url: str | None, is_local: bool = False, model_name: str = DEFAULT_MODEL):
    db = read_db()
    try:
        logging.info(f"WORKER [{job_id}]: Iniciando processamento com modelo '{model_name}'.")
        db[job_id]["status"] = "processing"
        write_db(db)

        audio_path = None
        if url:
            output_template = f"{os.path.join(UPLOADS_DIR, job_id)}.%(ext)s"
            await run_command(["yt-dlp", "--no-playlist", "-x", "--audio-format", "mp3", "--output", output_template, "--", url])
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

        db = read_db()
        db[job_id]["status"] = "transcribing"
        write_db(db)

        async with transcription_lock:
            logging.info(f"WORKER [{job_id}]: GPU lock adquirido. Carregando modelo '{model_name}'...")
            loop = asyncio.get_event_loop()

            try:
                # Load model (unloads previous if different) and transcribe in thread executor
                def transcribe():
                    model = model_manager.load(model_name)
                    segments, info = model.transcribe(
                        audio_path,
                        language="pt",
                        vad_filter=True,
                        beam_size=5
                    )
                    # Consume the generator synchronously
                    seg_list = list(segments)
                    return seg_list, info

                segments, info = await loop.run_in_executor(None, transcribe)

            except RuntimeError as e:
                # OOM or model load failure
                error_message = str(e)
                logging.error(f"WORKER [{job_id}]: Falha ao carregar modelo: {error_message}")
                db = read_db()
                db[job_id]["status"] = "failed"
                db[job_id]["error"] = error_message
                write_db(db)
                # Propagate to outer except to hit the WebSocket notification
                raise

        # Build transcript strings from segments
        vtt_lines = ["WEBVTT\n"]
        simple_lines = []
        for seg in segments:
            start = _format_vtt_time(seg.start)
            end = _format_vtt_time(seg.end)
            vtt_lines.append(f"{start} --> {end}")
            vtt_lines.append(seg.text.strip())
            vtt_lines.append("")
            simple_lines.append(seg.text.strip())

        vtt_content = "\n".join(vtt_lines)
        simple_text = "\n".join(simple_lines)

        timestamp_path = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_timestamp.txt")
        simple_path = os.path.join(TRANSCRIPTIONS_DIR, f"{job_id}_simple.txt")

        with open(timestamp_path, 'w', encoding='utf-8') as f:
            f.write(vtt_content)
        with open(simple_path, 'w', encoding='utf-8') as f:
            f.write(simple_text)

        db = read_db()
        db[job_id]["timestamp_path"] = timestamp_path
        db[job_id]["simple_path"] = simple_path
        db[job_id]["status"] = "completed"
        write_db(db)

        logging.info(f"WORKER [{job_id}]: Transcrição concluída.")
        os.remove(audio_path)
        gc.collect()

    except Exception as e:
        logging.error(f"WORKER [{job_id}]: Falha no processamento: {e}", exc_info=True)
        db = read_db()
        db[job_id]["status"] = "failed"
        db[job_id]["error"] = str(e)
        write_db(db)


def _format_vtt_time(seconds: float) -> str:
    """Convert float seconds to VTT timestamp HH:MM:SS.mmm"""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"


async def queue_consumer():
    logging.info("Consumidor de fila iniciado. Aguardando tarefas.")
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


# --- Gerenciador de WebSocket ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, WebSocket] = {}

    async def connect(self, user_id: str, websocket: WebSocket):
        await websocket.accept()
        self.active_connections[user_id] = websocket

    def disconnect(self, user_id: str):
        if user_id in self.active_connections:
            del self.active_connections[user_id]

    async def send_personal_message(self, message: dict, user_id: str):
        if user_id in self.active_connections:
            try:
                await self.active_connections[user_id].send_json(message)
            except Exception:
                self.disconnect(user_id)


manager = ConnectionManager()

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
                current_db = read_db()
                if current_db != DB_STATE_CACHE:
                    for job_id, new_details in current_db.items():
                        old_details = DB_STATE_CACHE.get(job_id, {})
                        user_id = new_details.get("user_id")
                        if new_details.get("status") != old_details.get("status") and user_id:
                            status = new_details["status"]
                            logging.info(f"WEB: Job {job_id} mudou para '{status}'.")
                            message = {"type": "status_update", "job_id": job_id, "status": status}
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
            logging.error(f"WEB: Erro na rotina de atualização: {e}")


# --- Limpeza Agendada ---
def cleanup_old_files():
    logging.info("WEB: Rodando tarefa de limpeza de arquivos antigos...")
    cutoff = datetime.now() - timedelta(days=30)
    db = read_db()
    jobs_to_delete = [
        job_id for job_id, details in db.items()
        if datetime.fromisoformat(details.get("timestamp", "1970-01-01T00:00:00")) < cutoff
    ]
    if not jobs_to_delete:
        return
    for job_id in jobs_to_delete:
        details = db.pop(job_id, {})
        for key in ["timestamp_path", "simple_path"]:
            if (path := details.get(key)) and os.path.exists(path):
                try:
                    os.remove(path)
                except OSError as e:
                    logging.error(f"WEB: Erro ao remover arquivo {path}: {e}")
    write_db(db)
    logging.info(f"WEB: Limpeza de {len(jobs_to_delete)} tarefas concluída.")


async def update_ytdlp():
    logging.info("SYSTEM: Iniciando atualização diária do yt-dlp...")
    try:
        await run_command([sys.executable, "-m", "pip", "install", "--upgrade", "--no-cache-dir", "yt-dlp"])
        logging.info("SYSTEM: yt-dlp atualizado com sucesso.")
    except Exception as e:
        logging.error(f"SYSTEM: Falha ao atualizar yt-dlp: {e}")


# --- Ciclo de Vida da Aplicação ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Warm-up: pre-load the default model
    logging.info(f"STARTUP: Pré-carregando modelo padrão '{DEFAULT_MODEL}'...")
    try:
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, lambda: model_manager.load(DEFAULT_MODEL))
        logging.info("STARTUP: Modelo padrão carregado com sucesso.")
    except Exception as e:
        logging.critical(f"STARTUP: Falha ao carregar modelo padrão: {e}", exc_info=True)

    scheduler = AsyncIOScheduler()
    scheduler.add_job(cleanup_old_files, 'interval', hours=1, misfire_grace_time=300)
    scheduler.add_job(update_ytdlp, 'cron', hour=3, minute=0, misfire_grace_time=300)
    scheduler.start()

    asyncio.create_task(queue_consumer())
    asyncio.create_task(status_updater())
    yield


# --- App ---
app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

API_KEY = os.getenv("API_KEY", "chave-secreta-padrao")
api_key_header = APIKeyHeader(name="X-API-Key")


class APIResponse(BaseModel):
    status: str
    job_id: str
    transcription: str | None = None
    error: str | None = None


async def get_api_key(api_key_header: str = Security(api_key_header)):
    if api_key_header != API_KEY:
        raise HTTPException(status_code=401, detail="Chave de API inválida.")


# --- Endpoints Web ---
@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "valid_models": VALID_MODELS})


@app.post("/transcribe", status_code=202)
async def handle_transcription_request(
    request: Request,
    file: UploadFile = File(None),
    url: str = Form(None),
    model_name: str = Form(DEFAULT_MODEL)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")

    user_id = request.cookies.get("user_id")
    if not user_id:
        raise HTTPException(status_code=400, detail="User ID não encontrado.")

    job_id = str(uuid.uuid4())
    original_filename = (file.filename if file and file.filename else url) or "Job"
    file_path = None

    if file and file.filename:
        file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")
        async with aiofiles.open(file_path, 'wb') as out_file:
            while chunk := await file.read(1024 * 1024):
                await out_file.write(chunk)

    db = read_db()
    db[job_id] = {
        "user_id": user_id,
        "original_filename": original_filename,
        "model_name": model_name,
        "status": "queued",
        "timestamp": datetime.now().isoformat()
    }
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": url, "model_name": model_name})
    await manager.send_personal_message({"type": "new_job", "job": db[job_id], "job_id": job_id}, user_id)
    return JSONResponse(content={"message": "Tarefa enfileirada!", "job_id": job_id})


@app.get("/history/{user_id}")
async def get_history(user_id: str):
    db, cutoff, user_jobs = read_db(), datetime.now() - timedelta(hours=24), {}
    for job_id, details in db.items():
        if details.get("user_id") == user_id:
            try:
                ts_str = details.get("timestamp", "1970-01-01T00:00:00")
                if datetime.fromisoformat(ts_str) >= cutoff:
                    user_jobs[job_id] = details
            except ValueError:
                continue
    for details in user_jobs.values():
        if details.get('status') == 'completed':
            try:
                if (simple_path := details.get('simple_path')) and os.path.exists(simple_path):
                    with open(simple_path, 'r', encoding='utf-8') as f:
                        details['transcription_simple'] = f.read()
                if (timestamp_path := details.get('timestamp_path')) and os.path.exists(timestamp_path):
                    with open(timestamp_path, 'r', encoding='utf-8') as f:
                        details['transcription_timestamp'] = f.read()
            except Exception:
                details['status'] = 'archived'
    return JSONResponse(content=user_jobs)


@app.delete("/job/{job_id}", status_code=204)
async def delete_job(job_id: str, request: Request):
    user_id = request.cookies.get("user_id")
    if not user_id:
        raise HTTPException(status_code=403)
    db = read_db()
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
    write_db(db)


@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await manager.connect(user_id, websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(user_id)


# --- Endpoints API v1 (Async) ---
@app.post("/api/v1/submit", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_job(
    url: str = Form(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")
    job_id = str(uuid.uuid4())
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": url, "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": None, "url": url, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.post("/api/v1/submit-file", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_file_job(
    file: UploadFile = File(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")
    job_id, original_filename = str(uuid.uuid4()), file.filename or "Job"
    file_path = os.path.join(UPLOADS_DIR, f"{job_id}_{original_filename}")
    async with aiofiles.open(file_path, 'wb') as out_file:
        while chunk := await file.read(1024 * 1024):
            await out_file.write(chunk)
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": file_path, "url": None, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.post("/api/v1/submit-local", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_submit_local_job(
    file_path: str = Form(...),
    model_name: str = Form(DEFAULT_MODEL),
    api_key: str = Security(get_api_key)
):
    if model_name not in VALID_MODELS:
        raise HTTPException(status_code=400, detail=f"Modelo inválido. Opções: {VALID_MODELS}")

    allowed_dir = os.getenv("ROOT_DIR", "/media")
    normalized_path = os.path.abspath(file_path)
    if not normalized_path.startswith(allowed_dir):
        raise HTTPException(status_code=403, detail="Acesso negado: o arquivo deve estar dentro do diretório de mídia permitido.")
    if not os.path.exists(normalized_path):
        raise HTTPException(status_code=404, detail="Arquivo local não encontrado.")

    job_id = str(uuid.uuid4())
    original_filename = os.path.basename(normalized_path)
    db = read_db()
    db[job_id] = {"user_id": "api_user", "original_filename": original_filename, "model_name": model_name, "status": "queued", "timestamp": datetime.now().isoformat()}
    write_db(db)
    await task_queue.put({"job_id": job_id, "file_path": normalized_path, "url": None, "is_local": True, "model_name": model_name})
    return APIResponse(status="queued", job_id=job_id)


@app.get("/api/v1/result/{job_id}", response_model=APIResponse, tags=["API V1 (Async)"])
async def api_get_result(
    job_id: str,
    timestamp_type: Literal['simple', 'timestamp'] = 'simple',
    api_key: str = Security(get_api_key)
):
    db = read_db()
    job = db.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job ID não encontrado.")
    status = job.get("status")
    if status != "completed":
        return APIResponse(status=status, job_id=job_id, error=job.get("error"))
    file_path = job.get(f"{timestamp_type}_path")
    if not file_path or not os.path.exists(file_path):
        return APIResponse(status="failed", error="Arquivo de transcrição não encontrado.", job_id=job_id)
    async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
        transcription_text = await f.read()
    return APIResponse(status="completed", transcription=transcription_text, job_id=job_id)
