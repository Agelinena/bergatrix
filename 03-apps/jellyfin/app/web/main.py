from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import os
import json
import time
import uuid
from pathlib import Path
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Mount static files
static_dir = Path("static")
static_dir.mkdir(exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")

# Templates
templates = Jinja2Templates(directory="templates")

MEDIA_ROOT = "/media"
JOBS_DIR = "/app/jobs"
STATS_FILE = "/app/stats/stats.json"

# Ensure jobs directory exists
os.makedirs(JOBS_DIR, exist_ok=True)

def load_stats():
    try:
        if os.path.exists(STATS_FILE):
            with open(STATS_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {}

def find_poster(directory: Path):
    """
    Looks for poster.jpg, folder.jpg, or seasonXX.jpg in the directory.
    """
    for name in ['poster.jpg', 'folder.jpg', 'cover.jpg']:
        if (directory / name).exists():
            return str(directory / name)
    return None


# Global Cache
_media_cache = {
    "data": None,
    "timestamp": 0
}
CACHE_DURATION = 300  # 5 minutes

def scan_media(force: bool = False):
    """
    Scans media directories and returns a structured dictionary.
    Uses a simple time-based cache.
    """
    global _media_cache
    
    # Return cache if valid
    if not force and _media_cache['data'] and (time.time() - _media_cache['timestamp'] < CACHE_DURATION):
        logger.info("Returning cached media data")
        return _media_cache['data']

    logger.info("Scanning media directories...")
    
    stats_db = load_stats()
    total_saved_bytes = 0
    total_optimized = 0
    
    data = {
        'movies': [],
        'series': {},
        'stats': {
            'total_saved_bytes': 0,
            'formatted_saved': "0 GB"
        }
    }

    # Helper to get calc stats
    def get_optimization_info(filepath):
        nonlocal total_saved_bytes, total_optimized
        info = stats_db.get(str(filepath))
        if info:
            saved = info.get('saved_bytes', 0)
            total_saved_bytes += saved
            total_optimized += 1
            return {
                "is_optimized": True,
                "saved_bytes": saved,
                "formatted_saved": f"{saved / (1024**3):.2f} GB"
            }
        return None

    # Scan Movies
    movies_path = Path(MEDIA_ROOT) / 'filmes'
    if movies_path.exists():
        for file in movies_path.rglob('*'):
            if file.is_file() and file.suffix.lower() in ['.mkv', '.mp4', '.avi', '.mov']:
                status = "🔴"
                por_sub = file.with_suffix('.por.srt')
                ptbr_sub = file.with_suffix('.pt-br.srt')
                
                if por_sub.exists() or ptbr_sub.exists():
                    status = "🟢"
                
                poster = find_poster(file.parent)
                opt_info = get_optimization_info(file)
                
                data['movies'].append({
                    "name": file.stem,
                    "filename": file.name,
                    "path": str(file),
                    "status": status,
                    "poster": poster,
                    "optimization": opt_info,
                    "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, str(file)))
                })

    # Scan Series
    series_path = Path(MEDIA_ROOT) / 'series'
    if series_path.exists():
        # Iterate over Series directories
        for series_dir in series_path.iterdir():
            if series_dir.is_dir():
                series_name = series_dir.name
                series_poster = find_poster(series_dir)
                
                if series_name not in data['series']:
                    data['series'][series_name] = {
                        'poster': series_poster,
                        'seasons': {}
                    }
                
                # Iterate over Season directories or files
                for item in series_dir.rglob('*'):
                    if item.is_file() and item.suffix.lower() in ['.mkv', '.mp4', '.avi', '.mov']:
                        # Try to guess season from parent folder name
                        season_name = item.parent.name
                        if not season_name.lower().startswith('season') and not season_name.lower().startswith('temporada'):
                             season_name = "Unknown Season"

                        if season_name not in data['series'][series_name]['seasons']:
                             data['series'][series_name]['seasons'][season_name] = []

                        status = "🔴"
                        por_sub = item.with_suffix('.por.srt')
                        ptbr_sub = item.with_suffix('.pt-br.srt')
                        
                        if por_sub.exists() or ptbr_sub.exists():
                            status = "🟢"

                        opt_info = get_optimization_info(item)

                        data['series'][series_name]['seasons'][season_name].append({
                            "name": item.stem,
                            "filename": item.name,
                            "path": str(item),
                            "status": status,
                            "optimization": opt_info,
                            "id": str(uuid.uuid5(uuid.NAMESPACE_DNS, str(item)))
                        })

    # Finalize stats
    data['stats']['total_saved_bytes'] = total_saved_bytes
    data['stats']['formatted_saved'] = f"{total_saved_bytes / (1024**3):.2f} GB"

    # Update cache
    _media_cache['data'] = data
    _media_cache['timestamp'] = time.time()
    return data

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    data = scan_media()
    return templates.TemplateResponse("index.html", {"request": request, "data": data})

@app.get("/api/image")
async def get_image(path: str):
    if not path:
        raise HTTPException(status_code=404, detail="Image not found")
    
    # Security check: ensure path is within MEDIA_ROOT
    # This is a basic check, might need more robust validation
    if not path.startswith(MEDIA_ROOT):
         raise HTTPException(status_code=403, detail="Access denied")

    if os.path.exists(path):
        return FileResponse(path)
    raise HTTPException(status_code=404, detail="Image not found")

@app.post("/api/translate")
async def trigger_translate(filepath: str = Form(...)):
    job_id = str(uuid.uuid4())
    job = {
        "id": job_id,
        "type": "translate",
        "filepath": filepath,
        "force": True, # Force translation as requested
        "status": "pending"
    }
    try:
        with open(os.path.join(JOBS_DIR, f"{job_id}.json"), "w") as f:
            json.dump(job, f)
        # Return HTMX-friendly response for Toast
        return HTMLResponse(content=f"""
            <div id="toast-container" hx-swap-oob="beforeend">
                <div class="toast bg-green-600 text-white p-4 rounded shadow-lg mb-4 transition transform duration-500 ease-in-out translate-x-0"
                     x-data="{{ show: true }}" x-show="show" x-init="setTimeout(() => show = false, 3000)">
                    Job started for {Path(filepath).name}
                </div>
            </div>
        """)
    except Exception as e:
        logger.error(f"Error creating job: {e}")
        return HTMLResponse(content=f"""
            <div id="toast-container" hx-swap-oob="beforeend">
                <div class="toast bg-red-600 text-white p-4 rounded shadow-lg mb-4 transition transform duration-500 ease-in-out translate-x-0"
                     x-data="{{ show: true }}" x-show="show" x-init="setTimeout(() => show = false, 3000)">
                    Error starting job: {str(e)}
                </div>
            </div>
        """)

@app.post("/api/transcribe")
async def trigger_transcribe(filepath: str = Form(...)):
    # Legacy endpoint, maybe remove or keep as placeholder?
    # User asked to remove transcription, but maybe keep button as "Force Transcribe" if needed later?
    # For now, let's just return an error or disable it.
    return HTMLResponse(content="Transcription is disabled.")
