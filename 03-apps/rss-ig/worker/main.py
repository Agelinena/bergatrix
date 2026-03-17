"""
instaloader-worker
──────────────────
• APScheduler: runs all profiles sequentially every SCHEDULE_INTERVAL_HOURS.
  Profiles are shuffled + random 30–180 s gap → zero overlap guaranteed.
• Manual fetch: polls manual_fetch_queue table every 30 s; each profile has
  an individual threading.Lock so scheduled + manual fetches never overlap
  for the same username.
• Cleanup: daily at 03:00 → removes media + DB rows older than 30 days,
  rebuilds affected RSS feeds.
"""
import logging
import os
import random
import signal
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import instaloader
from apscheduler.schedulers.background import BackgroundScheduler

import db
import rss_builder

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("worker")

# ── Config ────────────────────────────────────────────────────────────────────
DATA_DIR                 = os.environ.get("DATA_DIR", "/data")
MEDIA_DIR                = os.path.join(DATA_DIR, "media")
SESSION_DIR              = os.path.join(DATA_DIR, "session")
IG_USERNAME              = os.environ.get("IG_USERNAME", "")
IG_PASSWORD              = os.environ.get("IG_PASSWORD", "")
IG_USER_AGENT            = os.environ.get("IG_USER_AGENT", "")
SCRAPE_DAYS              = int(os.environ.get("SCRAPE_DAYS", "7"))
SCHEDULE_INTERVAL_HOURS  = int(os.environ.get("SCHEDULE_INTERVAL_HOURS", "2"))

# ── Per-profile locks (zero-overlap guarantee) ────────────────────────────────
_profile_locks: dict[str, threading.Lock] = {}
_locks_mutex = threading.Lock()


def _profile_lock(username: str) -> threading.Lock:
    with _locks_mutex:
        if username not in _profile_locks:
            _profile_locks[username] = threading.Lock()
        return _profile_locks[username]


# ── instaloader session ───────────────────────────────────────────────────────

def _make_loader() -> instaloader.Instaloader:
    kwargs: dict = dict(
        download_pictures=False,         # we download manually via httpx
        download_videos=False,
        download_video_thumbnails=False,
        download_geotags=False,
        download_comments=False,
        save_metadata=False,
        post_metadata_txt_pattern="",
        quiet=True,
    )
    if IG_USER_AGENT:
        kwargs["user_agent"] = IG_USER_AGENT
    return instaloader.Instaloader(**kwargs)


def _ensure_session(L: instaloader.Instaloader):
    """Load session from file; login + save if absent / expired."""
    Path(SESSION_DIR).mkdir(parents=True, exist_ok=True)
    session_file = os.path.join(SESSION_DIR, f"session-{IG_USERNAME}")
    try:
        L.load_session_from_file(IG_USERNAME, session_file)
        log.info("Session loaded from disk.")
    except (FileNotFoundError, instaloader.exceptions.ConnectionException):
        log.info("No session on disk — logging in…")
        L.login(IG_USERNAME, IG_PASSWORD)
        L.save_session_to_file(session_file)
        log.info("Login OK, session saved.")


# ── Media download ────────────────────────────────────────────────────────────

_DOWNLOAD_HEADERS = {
    "Referer":    "https://www.instagram.com/",
    "User-Agent": IG_USER_AGENT or (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
}


def _download(url: str, dest: str) -> bool:
    try:
        with httpx.stream(
            "GET", url, headers=_DOWNLOAD_HEADERS, follow_redirects=True, timeout=60
        ) as r:
            r.raise_for_status()
            with open(dest, "wb") as fh:
                for chunk in r.iter_bytes(65536):
                    fh.write(chunk)
        return True
    except Exception as exc:
        log.warning("Download failed (%s): %s", url, exc)
        if os.path.exists(dest):
            os.remove(dest)
        return False


def _download_post_media(
    post: instaloader.Post, username: str
) -> list[str]:
    user_dir = os.path.join(MEDIA_DIR, username)
    Path(user_dir).mkdir(parents=True, exist_ok=True)

    paths: list[str] = []

    if post.typename == "GraphSidecar":
        for idx, node in enumerate(post.get_sidecar_nodes()):
            if node.is_video:
                dest = os.path.join(user_dir, f"{post.shortcode}_{idx}.mp4")
                if not os.path.exists(dest):
                    _download(node.video_url, dest)
            else:
                dest = os.path.join(user_dir, f"{post.shortcode}_{idx}.jpg")
                if not os.path.exists(dest):
                    _download(node.display_url, dest)
            if os.path.exists(dest):
                paths.append(dest)

    elif post.is_video:
        dest = os.path.join(user_dir, f"{post.shortcode}.mp4")
        if not os.path.exists(dest):
            _download(post.video_url, dest)
        if os.path.exists(dest):
            paths.append(dest)

    else:
        dest = os.path.join(user_dir, f"{post.shortcode}.jpg")
        if not os.path.exists(dest):
            _download(post.url, dest)
        if os.path.exists(dest):
            paths.append(dest)

    return paths


def _post_type(post: instaloader.Post) -> str:
    if post.typename == "GraphSidecar":
        return "carousel"
    if post.is_video:
        return "reel"
    return "post"


# ── Core fetch ────────────────────────────────────────────────────────────────

def fetch_profile(username: str) -> bool:
    """Fetch new posts for one profile. Returns True on success.

    Uses a per-profile lock: if a fetch is already running (scheduled or
    manual), the call returns False immediately — zero overlap guaranteed.
    """
    lock = _profile_lock(username)
    if not lock.acquire(blocking=False):
        log.info("[%s] Already fetching — skipped.", username)
        return False

    log.info("[%s] Fetch started.", username)
    db.update_profile_status(username, "running")

    try:
        L = _make_loader()
        _ensure_session(L)

        profile = instaloader.Profile.from_username(L.context, username)
        cutoff  = datetime.utcnow() - timedelta(days=SCRAPE_DAYS)
        new_cnt = 0

        for post in profile.get_posts():
            if post.date_utc.replace(tzinfo=None) < cutoff:
                break
            if db.post_exists(post.shortcode):
                continue

            media_paths = _download_post_media(post, username)
            db.insert_post(
                profile_username=username,
                shortcode=post.shortcode,
                post_type=_post_type(post),
                caption=post.caption or "",
                timestamp=post.date_utc.replace(tzinfo=None),
                media_paths=media_paths,
            )
            new_cnt += 1
            log.info("[%s] +%s (%s)", username, post.shortcode, _post_type(post))

        # Rebuild RSS (covers last 30 days)
        recent = db.get_posts_for_profile(username, days=30)
        rss_builder.build_feed(username, recent)

        # Update storage stat
        user_dir = os.path.join(MEDIA_DIR, username)
        storage = (
            sum(f.stat().st_size for f in Path(user_dir).rglob("*") if f.is_file())
            if Path(user_dir).exists()
            else 0
        )
        db.update_profile_status(
            username, "ok", post_count=len(recent), storage_bytes=storage
        )
        log.info("[%s] Done — %d new post(s).", username, new_cnt)
        return True

    except instaloader.exceptions.ProfileNotExistsException:
        log.error("[%s] Profile not found.", username)
        db.update_profile_status(username, "error:not_found")
    except instaloader.exceptions.LoginRequiredException:
        log.error("[%s] Login required — session may have expired.", username)
        db.update_profile_status(username, "error:login_required")
        # Delete stale session so next run re-authenticates
        session_file = os.path.join(SESSION_DIR, f"session-{IG_USERNAME}")
        if os.path.exists(session_file):
            os.remove(session_file)
    except instaloader.exceptions.ConnectionException as exc:
        log.error("[%s] Connection error: %s", username, exc)
        db.update_profile_status(username, "error:connection")
    except Exception as exc:
        log.error("[%s] Unexpected error: %s", username, exc, exc_info=True)
        db.update_profile_status(username, f"error:{type(exc).__name__}")
    finally:
        lock.release()

    return False


# ── Scheduled jobs ────────────────────────────────────────────────────────────

def job_scrape_all():
    """Scheduled: fetch all profiles sequentially with random gaps."""
    profiles = db.get_profiles()
    if not profiles:
        log.info("No profiles configured.")
        return

    random.shuffle(profiles)
    log.info("Scheduled run: %d profile(s).", len(profiles))

    for i, row in enumerate(profiles):
        fetch_profile(row["username"])
        if i < len(profiles) - 1:
            delay = random.randint(30, 180)
            log.info("Sleeping %ds before next profile…", delay)
            time.sleep(delay)


def job_process_manual_queue():
    """Poll manual_fetch_queue every 30 s; dispatch pending items."""
    pending = db.get_pending_manual_fetches()
    for item in pending:
        qid      = item["id"]
        username = item["username"]
        db.update_queue_status(qid, "running")
        log.info("[%s] Manual fetch dispatched (queue=%d).", username, qid)

        def _run(u=username, q=qid):
            ok = fetch_profile(u)
            db.update_queue_status(q, "done" if ok else "error")

        threading.Thread(target=_run, daemon=True).start()


def job_cleanup():
    """Daily at 03:00: purge media + DB rows older than 30 days."""
    log.info("Cleanup started.")
    old_paths = db.get_post_media_paths_older_than(days=30)
    deleted = 0
    for p in old_paths:
        try:
            if os.path.exists(p):
                os.remove(p)
                deleted += 1
        except OSError as exc:
            log.warning("Could not delete %s: %s", p, exc)

    affected = db.delete_old_posts(days=30)
    for username in affected:
        posts = db.get_posts_for_profile(username, days=30)
        rss_builder.build_feed(username, posts)

    log.info("Cleanup done: %d file(s) deleted, %d feed(s) rebuilt.", deleted, len(affected))


def job_alive_marker():
    Path(os.path.join(DATA_DIR, ".worker_alive")).touch()


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    log.info("Starting instaloader-worker…")

    for d in [DATA_DIR, MEDIA_DIR, SESSION_DIR, os.path.join(DATA_DIR, "feeds")]:
        Path(d).mkdir(parents=True, exist_ok=True)

    db.init_db()
    db.reset_stale_queue_items()

    if not IG_USERNAME or not IG_PASSWORD:
        log.error("IG_USERNAME and IG_PASSWORD must be set.")
        sys.exit(1)

    # Validate session on startup (non-fatal if it fails)
    try:
        L = _make_loader()
        _ensure_session(L)
        log.info("Instagram session OK.")
    except Exception as exc:
        log.warning("Startup session check failed (%s) — will retry on first fetch.", exc)

    scheduler = BackgroundScheduler(timezone="America/Sao_Paulo")

    scheduler.add_job(
        job_scrape_all, "interval",
        hours=SCHEDULE_INTERVAL_HOURS,
        id="scrape_all",
        misfire_grace_time=600,
        max_instances=1,
    )
    scheduler.add_job(
        job_process_manual_queue, "interval",
        seconds=30,
        id="manual_queue",
        max_instances=1,
    )
    scheduler.add_job(
        job_cleanup, "cron",
        hour=3, minute=0,
        id="cleanup",
    )
    scheduler.add_job(
        job_alive_marker, "interval",
        minutes=1,
        id="alive",
    )

    scheduler.start()
    job_alive_marker()
    log.info("Scheduler running. First scrape in %dh.", SCHEDULE_INTERVAL_HOURS)

    def _shutdown(signum, frame):
        log.info("Shutdown signal received.")
        scheduler.shutdown(wait=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
