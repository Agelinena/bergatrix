"""
SQLite operations shared between worker and API.
Uses WAL mode for safe multi-process concurrent access.
"""
import json
import os
import sqlite3
import threading
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

DATA_DIR = os.environ.get("DATA_DIR", "/data")
DB_PATH = os.path.join(DATA_DIR, "instaloader.db")

# Thread-local connections (safe for multi-threaded APScheduler)
_local = threading.local()


def _conn() -> sqlite3.Connection:
    if not hasattr(_local, "conn") or _local.conn is None:
        _local.conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        _local.conn.row_factory = sqlite3.Row
        _local.conn.execute("PRAGMA journal_mode=WAL")
        _local.conn.execute("PRAGMA foreign_keys=ON")
        _local.conn.execute("PRAGMA busy_timeout=5000")
    return _local.conn


def init_db():
    """Create schema if it doesn't exist. Safe to call on every startup."""
    Path(DATA_DIR).mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS profiles (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            username        TEXT    UNIQUE NOT NULL,
            added_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
            last_fetch_at   DATETIME,
            last_fetch_status TEXT,
            post_count      INTEGER DEFAULT 0,
            storage_bytes   INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS posts (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_username TEXT    NOT NULL,
            post_shortcode   TEXT    NOT NULL UNIQUE,
            post_type        TEXT    NOT NULL,
            caption          TEXT,
            timestamp        DATETIME NOT NULL,
            media_paths      TEXT    DEFAULT '[]',
            fetched_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (profile_username) REFERENCES profiles(username) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS manual_fetch_queue (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            username     TEXT    NOT NULL,
            requested_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            status       TEXT    DEFAULT 'pending'
        );

        CREATE INDEX IF NOT EXISTS idx_posts_profile   ON posts(profile_username);
        CREATE INDEX IF NOT EXISTS idx_posts_timestamp ON posts(timestamp);
        CREATE INDEX IF NOT EXISTS idx_queue_status    ON manual_fetch_queue(status, requested_at);
    """)
    conn.commit()
    conn.close()


# ── Profiles ──────────────────────────────────────────────────────────────────

def add_profile(username: str) -> bool:
    try:
        c = _conn()
        c.execute("INSERT INTO profiles (username) VALUES (?)", (username,))
        c.commit()
        return True
    except sqlite3.IntegrityError:
        return False


def remove_profile(username: str) -> bool:
    c = _conn()
    cur = c.execute("DELETE FROM profiles WHERE username = ?", (username,))
    c.commit()
    return cur.rowcount > 0


def get_profiles() -> list[dict]:
    rows = _conn().execute("SELECT * FROM profiles ORDER BY username").fetchall()
    return [dict(r) for r in rows]


def get_profile(username: str) -> Optional[dict]:
    row = _conn().execute("SELECT * FROM profiles WHERE username = ?", (username,)).fetchone()
    return dict(row) if row else None


def update_profile_status(
    username: str,
    status: str,
    post_count: Optional[int] = None,
    storage_bytes: Optional[int] = None,
):
    c = _conn()
    now = datetime.utcnow().isoformat()
    if post_count is not None and storage_bytes is not None:
        c.execute(
            "UPDATE profiles SET last_fetch_at=?, last_fetch_status=?, post_count=?, storage_bytes=? WHERE username=?",
            (now, status, post_count, storage_bytes, username),
        )
    else:
        c.execute(
            "UPDATE profiles SET last_fetch_at=?, last_fetch_status=? WHERE username=?",
            (now, status, username),
        )
    c.commit()


# ── Posts ─────────────────────────────────────────────────────────────────────

def post_exists(shortcode: str) -> bool:
    row = _conn().execute(
        "SELECT 1 FROM posts WHERE post_shortcode=?", (shortcode,)
    ).fetchone()
    return row is not None


def insert_post(
    profile_username: str,
    shortcode: str,
    post_type: str,
    caption: str,
    timestamp: datetime,
    media_paths: list[str],
):
    c = _conn()
    c.execute(
        "INSERT OR IGNORE INTO posts "
        "(profile_username, post_shortcode, post_type, caption, timestamp, media_paths) "
        "VALUES (?,?,?,?,?,?)",
        (
            profile_username,
            shortcode,
            post_type,
            caption,
            timestamp.isoformat(),
            json.dumps(media_paths),
        ),
    )
    c.commit()


def get_posts_for_profile(username: str, days: int = 30) -> list[dict]:
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
    rows = _conn().execute(
        "SELECT * FROM posts WHERE profile_username=? AND timestamp >= ? ORDER BY timestamp DESC",
        (username, cutoff),
    ).fetchall()
    result = []
    for r in rows:
        d = dict(r)
        d["media_paths"] = json.loads(d["media_paths"])
        result.append(d)
    return result


def get_post_media_paths_older_than(days: int = 30) -> list[str]:
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
    rows = _conn().execute(
        "SELECT media_paths FROM posts WHERE timestamp < ?", (cutoff,)
    ).fetchall()
    paths: list[str] = []
    for r in rows:
        paths.extend(json.loads(r[0]))
    return paths


def delete_old_posts(days: int = 30) -> list[str]:
    """Delete posts older than `days` days; return list of affected usernames."""
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
    c = _conn()
    rows = c.execute(
        "SELECT DISTINCT profile_username FROM posts WHERE timestamp < ?", (cutoff,)
    ).fetchall()
    affected = [r[0] for r in rows]
    c.execute("DELETE FROM posts WHERE timestamp < ?", (cutoff,))
    c.commit()
    return affected


# ── Manual fetch queue ────────────────────────────────────────────────────────

def enqueue_manual_fetch(username: str) -> int:
    c = _conn()
    cur = c.execute(
        "INSERT INTO manual_fetch_queue (username) VALUES (?)", (username,)
    )
    c.commit()
    return cur.lastrowid


def get_pending_manual_fetches() -> list[dict]:
    rows = _conn().execute(
        "SELECT * FROM manual_fetch_queue WHERE status='pending' ORDER BY requested_at"
    ).fetchall()
    return [dict(r) for r in rows]


def update_queue_status(queue_id: int, status: str):
    c = _conn()
    c.execute(
        "UPDATE manual_fetch_queue SET status=? WHERE id=?", (status, queue_id)
    )
    c.commit()


def reset_stale_queue_items():
    """Reset 'running' queue items to 'pending' (called on worker startup)."""
    c = _conn()
    c.execute(
        "UPDATE manual_fetch_queue SET status='pending' WHERE status='running'"
    )
    c.commit()


# ── Stats ─────────────────────────────────────────────────────────────────────

def get_stats() -> dict:
    c = _conn()
    profile_count  = c.execute("SELECT COUNT(*) FROM profiles").fetchone()[0]
    post_count     = c.execute("SELECT COUNT(*) FROM posts").fetchone()[0]
    total_storage  = c.execute("SELECT COALESCE(SUM(storage_bytes),0) FROM profiles").fetchone()[0]
    last_fetch     = c.execute("SELECT MAX(last_fetch_at) FROM profiles").fetchone()[0]
    return {
        "profile_count":    profile_count,
        "post_count":       post_count,
        "total_storage_bytes": total_storage,
        "last_fetch_at":    last_fetch,
    }
