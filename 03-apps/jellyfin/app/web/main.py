import os
import json
import time
import uuid
import subprocess
import logging
from pathlib import Path

from fastapi import FastAPI, Request, Form, HTTPException, Query
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import bazarr as bazarr_client

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Static files
static_dir = Path("static")
static_dir.mkdir(exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")

templates = Jinja2Templates(directory="templates")

MEDIA_ROOT = "/media"
JOBS_DIR = "/app/jobs"
STATS_FILE = "/app/stats/stats.json"
TRANSLATION_STATS_FILE = "/app/stats/translation_stats.json"

os.makedirs(JOBS_DIR, exist_ok=True)


# ------------------------------------------------------------------ #
# Helpers — carregamento de dados                                      #
# ------------------------------------------------------------------ #

def load_stats() -> dict:
    try:
        if os.path.exists(STATS_FILE):
            with open(STATS_FILE, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def load_translation_stats() -> list:
    try:
        if os.path.exists(TRANSLATION_STATS_FILE):
            with open(TRANSLATION_STATS_FILE, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return []


def find_poster(directory: Path) -> str | None:
    for name in ["poster.jpg", "folder.jpg", "cover.jpg"]:
        p = directory / name
        if p.exists():
            return str(p)
    return None


# ------------------------------------------------------------------ #
# Cache de mídia                                                       #
# ------------------------------------------------------------------ #

_media_cache = {"data": None, "timestamp": 0}
CACHE_DURATION = 300  # 5 minutos


def scan_media(force: bool = False) -> dict:
    global _media_cache

    if not force and _media_cache["data"] and (time.time() - _media_cache["timestamp"] < CACHE_DURATION):
        return _media_cache["data"]

    logger.info("Escaneando diretórios de mídia...")
    stats_db = load_stats()
    translation_db = load_translation_stats()

    # Index de traduções por filepath para lookup rápido
    translated_paths = {
        e["filepath"]: e
        for e in translation_db
        if e.get("status") == "success"
    }

    total_saved_bytes = 0
    total_translated = sum(1 for e in translation_db if e.get("status") == "success")

    data: dict = {
        "movies": [],
        "series": {},
        "stats": {
            "total_saved_bytes": 0,
            "formatted_saved": "0 GB",
            "total_translated": total_translated,
        },
    }

    def get_optimization_info(filepath):
        nonlocal total_saved_bytes
        info = stats_db.get(str(filepath))
        if info:
            saved = info.get("saved_bytes", 0)
            total_saved_bytes += saved
            return {
                "is_optimized": True,
                "saved_bytes": saved,
                "formatted_saved": f"{saved / (1024**3):.2f} GB",
            }
        return None

    def get_subtitle_status(filepath):
        """Verifica legenda PT-BR (arquivo e interna via legenda externa)."""
        base = os.path.splitext(filepath)[0]
        suffixes = [".por.srt", ".pt-br.srt", ".pt.srt", ".portuguese.srt", ".ptbr.srt"]
        for s in suffixes:
            if os.path.exists(base + s):
                return "🟢"
        if str(filepath) in translated_paths:
            return "🟢"
        return "🔴"

    # --- Filmes ---
    movies_path = Path(MEDIA_ROOT) / "filmes"
    if movies_path.exists():
        for file in movies_path.rglob("*"):
            if file.is_file() and file.suffix.lower() in [".mkv", ".mp4", ".avi", ".mov"]:
                status = get_subtitle_status(str(file))
                poster = find_poster(file.parent)
                opt_info = get_optimization_info(file)
                trans_info = translated_paths.get(str(file))

                data["movies"].append({
                    "name": file.stem,
                    "filename": file.name,
                    "path": str(file),
                    "status": status,
                    "poster": poster,
                    "optimization": opt_info,
                    "translation": trans_info,
                    "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, str(file))),
                })

    # --- Séries ---
    series_path = Path(MEDIA_ROOT) / "series"
    if series_path.exists():
        for series_dir in series_path.iterdir():
            if not series_dir.is_dir():
                continue
            series_name = series_dir.name
            series_poster = find_poster(series_dir)

            if series_name not in data["series"]:
                data["series"][series_name] = {"poster": series_poster, "seasons": {}}

            for item in series_dir.rglob("*"):
                if not (item.is_file() and item.suffix.lower() in [".mkv", ".mp4", ".avi", ".mov"]):
                    continue

                season_name = item.parent.name
                if not (
                    season_name.lower().startswith("season")
                    or season_name.lower().startswith("temporada")
                ):
                    season_name = "Unknown Season"

                if season_name not in data["series"][series_name]["seasons"]:
                    data["series"][series_name]["seasons"][season_name] = []

                status = get_subtitle_status(str(item))
                opt_info = get_optimization_info(item)
                trans_info = translated_paths.get(str(item))

                data["series"][series_name]["seasons"][season_name].append({
                    "name": item.stem,
                    "filename": item.name,
                    "path": str(item),
                    "status": status,
                    "optimization": opt_info,
                    "translation": trans_info,
                    "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, str(item))),
                })

    data["stats"]["total_saved_bytes"] = total_saved_bytes
    data["stats"]["formatted_saved"] = f"{total_saved_bytes / (1024**3):.2f} GB"

    _media_cache["data"] = data
    _media_cache["timestamp"] = time.time()
    return data


# ------------------------------------------------------------------ #
# Rotas                                                                #
# ------------------------------------------------------------------ #

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    data = scan_media()
    return templates.TemplateResponse("index.html", {"request": request, "data": data})


@app.get("/api/image")
async def get_image(path: str):
    if not path or not path.startswith(MEDIA_ROOT):
        raise HTTPException(status_code=403, detail="Acesso negado")
    if os.path.exists(path):
        return FileResponse(path)
    raise HTTPException(status_code=404, detail="Imagem não encontrada")


@app.get("/api/subtitles")
async def get_subtitles(filepath: str = Query(...)):
    """Retorna lista de streams de legenda disponíveis no arquivo."""
    if not filepath.startswith(MEDIA_ROOT):
        raise HTTPException(status_code=403, detail="Acesso negado")
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="Arquivo não encontrado")

    try:
        cmd = [
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            filepath
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        media_data = json.loads(result.stdout)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro ao ler arquivo: {e}")

    BITMAP_CODECS = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "pgssub"]
    TEXT_CODECS = ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"]

    subtitles = []
    for s in media_data.get("streams", []):
        if s.get("codec_type") != "subtitle":
            continue
        tags = s.get("tags", {})
        codec = s.get("codec_name", "unknown")
        lang = tags.get("language", "unknown")
        title = tags.get("title", "")
        is_bitmap = codec in BITMAP_CODECS

        label_parts = []
        if lang and lang != "unknown":
            label_parts.append(lang.upper())
        if title:
            label_parts.append(title)
        label_parts.append(f"[{codec}]")
        if is_bitmap:
            label_parts.append("🖼️ OCR")
        label = " — ".join(label_parts)

        subtitles.append({
            "index": s["index"],
            "codec": codec,
            "language": lang,
            "title": title,
            "is_bitmap": is_bitmap,
            "is_text": codec in TEXT_CODECS,
            "label": label,
        })

    return JSONResponse(content={"subtitles": subtitles})


@app.get("/api/translation-stats")
async def translation_stats():
    """Retorna histórico e resumo de traduções."""
    entries = load_translation_stats()
    total = len(entries)
    success = sum(1 for e in entries if e.get("status") == "success")
    failed = sum(1 for e in entries if e.get("status") == "failed")
    last = entries[-1] if entries else None
    return JSONResponse(content={
        "summary": {"total": total, "success": success, "failed": failed, "last": last},
        "entries": entries[-50:],  # Últimas 50 entradas
    })


@app.post("/api/translate")
async def trigger_translate(
    filepath: str = Form(...),
    stream_index: str = Form(None),
    force: str = Form("true"),
):
    job_id = str(uuid.uuid4())
    job: dict = {
        "id": job_id,
        "type": "translate",
        "filepath": filepath,
        "force": force.lower() == "true",
        "stream_index": int(stream_index) if stream_index is not None else None,
        "status": "pending",
    }
    try:
        with open(os.path.join(JOBS_DIR, f"{job_id}.json"), "w") as f:
            json.dump(job, f)

        filename = Path(filepath).name
        stream_info = f" (stream {stream_index})" if stream_index is not None else " (auto)"
        return HTMLResponse(content=f"""
            <div id="toast-container" hx-swap-oob="beforeend">
                <div class="toast bg-green-600 text-white p-4 rounded shadow-lg mb-4 transition"
                     x-data="{{ show: true }}" x-show="show" x-init="setTimeout(() => show = false, 4000)">
                    ✅ Job iniciado: {filename}{stream_info}
                </div>
            </div>
        """)
    except Exception as e:
        logger.error(f"Erro ao criar job: {e}")
        return HTMLResponse(content=f"""
            <div id="toast-container" hx-swap-oob="beforeend">
                <div class="toast bg-red-600 text-white p-4 rounded shadow-lg mb-4"
                     x-data="{{ show: true }}" x-show="show" x-init="setTimeout(() => show = false, 4000)">
                    ❌ Erro: {str(e)}
                </div>
            </div>
        """)


@app.post("/api/bazarr-search")
async def bazarr_search(filepath: str = Form(...)):
    """Aciona busca de legenda PT-BR no Bazarr para o arquivo especificado."""
    if not filepath.startswith(MEDIA_ROOT):
        raise HTTPException(status_code=403, detail="Acesso negado")
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="Arquivo não encontrado")

    result = bazarr_client.search_subtitle(filepath)
    return JSONResponse(content=result)


@app.post("/api/scan")
async def trigger_scan():
    """Força uma varredura imediata de toda a biblioteca de mídia."""
    job_id = str(uuid.uuid4())
    job = {"id": job_id, "type": "scan", "status": "pending"}
    try:
        with open(os.path.join(JOBS_DIR, f"{job_id}.json"), "w") as f:
            json.dump(job, f)
        return JSONResponse(content={"status": "ok", "message": "Varredura agendada."})
    except Exception as e:
        logger.error(f"Erro ao criar job de scan: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/webhook/arr")
async def arr_webhook(request: Request):
    """
    Recebe webhooks do Radarr/Sonarr (On Download / On Import).
    Cria um job de validação de áudio e processamento de legenda.
    """
    try:
        payload = await request.json()
        logger.info(f"Webhook recebido: {payload.get('eventType', 'unknown')}")
        
        # Sonarr envia 'episodeFile' -> 'path' e 'series' -> 'path'
        # Radarr envia 'movieFile' -> 'path' e 'movie' -> 'folderPath'
        
        filepath = None
        media_type = None
        
        if "movieFile" in payload:
            filepath = payload["movieFile"].get("path")
            media_type = "movie"
        elif "episodeFile" in payload:
            filepath = payload["episodeFile"].get("path")
            media_type = "episode"
            
        if not filepath:
            logger.warning("Webhook ignorado: filepath não encontrado no payload.")
            return JSONResponse(content={"status": "ignored", "reason": "no filepath"})

        # Ajusta o caminho se o Radarr/Sonarr enviar caminhos que não batem exatamente 
        # (mas se ambos usam /media/..., deve bater perfeitamente)
        
        job_id = str(uuid.uuid4())
        job = {
            "id": job_id,
            "type": "validate_and_translate",
            "filepath": filepath,
            "media_type": media_type,
            "arr_event": payload,
            "status": "pending"
        }
        
        with open(os.path.join(JOBS_DIR, f"{job_id}.json"), "w") as f:
            json.dump(job, f)
            
        logger.info(f"Job {job_id} de validação agendado para {filepath}")
        return JSONResponse(content={"status": "ok", "job_id": job_id})
        
    except Exception as e:
        logger.error(f"Erro ao processar webhook: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/refresh-cache")
async def refresh_cache():
    scan_media(force=True)
    return JSONResponse(content={"status": "cache refreshed"})
