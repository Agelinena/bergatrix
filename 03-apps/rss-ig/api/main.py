"""
instaloader-api
───────────────
Serves:
  GET  /health                         — liveness probe
  GET  /feeds/{username}.xml           — RSS feed (static file)
  GET  /media/{path}                   — media files (static)
  GET  /ui/                            — web dashboard
  GET  /api/profiles                   — list profiles
  POST /api/profiles                   — add profile
  GET  /api/profiles/{username}        — profile detail + recent posts
  DELETE /api/profiles/{username}      — remove profile
  POST /api/profiles/{username}/fetch  — enqueue manual fetch
  GET  /api/stats                      — global stats
"""
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import db

# ── Directories (create before mounting static routes) ────────────────────────
DATA_DIR  = os.environ.get("DATA_DIR", "/data")
FEEDS_DIR = os.path.join(DATA_DIR, "feeds")
MEDIA_DIR = os.path.join(DATA_DIR, "media")

for _d in [DATA_DIR, FEEDS_DIR, MEDIA_DIR]:
    Path(_d).mkdir(parents=True, exist_ok=True)

db.init_db()

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="instaloader-rss", docs_url=None, redoc_url=None)

# Static mounts
app.mount("/feeds", StaticFiles(directory=FEEDS_DIR), name="feeds")
app.mount("/media", StaticFiles(directory=MEDIA_DIR), name="media")
app.mount("/ui",    StaticFiles(directory="ui", html=True), name="ui")


# ── Helpers ───────────────────────────────────────────────────────────────────

def _profile_or_404(username: str) -> dict:
    p = db.get_profile(username)
    if p is None:
        raise HTTPException(status_code=404, detail=f"Profile '{username}' not found.")
    return p


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return RedirectResponse(url="/ui/")


# ── Profile management ────────────────────────────────────────────────────────

class ProfileIn(BaseModel):
    username: str


@app.get("/api/profiles")
def list_profiles():
    return db.get_profiles()


@app.post("/api/profiles", status_code=201)
def add_profile(body: ProfileIn):
    username = body.username.strip().lstrip("@").lower()
    if not username:
        raise HTTPException(status_code=422, detail="Username cannot be empty.")
    ok = db.add_profile(username)
    if not ok:
        raise HTTPException(status_code=409, detail=f"Profile '{username}' already exists.")
    return db.get_profile(username)


@app.get("/api/profiles/{username}")
def get_profile(username: str):
    profile = _profile_or_404(username)
    posts   = db.get_posts_for_profile(username, days=30)
    return {**profile, "recent_posts": posts}


@app.delete("/api/profiles/{username}", status_code=204)
def remove_profile(username: str):
    _profile_or_404(username)

    # Delete media files for this profile
    user_dir = Path(MEDIA_DIR) / username
    if user_dir.exists():
        import shutil
        shutil.rmtree(user_dir, ignore_errors=True)

    # Delete RSS feed file
    feed_path = Path(FEEDS_DIR) / f"{username}.xml"
    if feed_path.exists():
        feed_path.unlink(missing_ok=True)

    db.remove_profile(username)


# ── Manual fetch ──────────────────────────────────────────────────────────────

@app.post("/api/profiles/{username}/fetch", status_code=202)
def trigger_fetch(username: str):
    _profile_or_404(username)
    queue_id = db.enqueue_manual_fetch(username)
    return {"queued": True, "queue_id": queue_id, "username": username}


# ── Stats ─────────────────────────────────────────────────────────────────────

@app.get("/api/stats")
def stats():
    return db.get_stats()
