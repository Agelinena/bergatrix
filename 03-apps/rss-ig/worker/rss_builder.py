"""
Builds per-profile RSS 2.0 XML files using feedgen.
All media URLs point to the self-hosted FastAPI /media/ endpoint.
"""
import html
import os
from datetime import datetime, timezone
from pathlib import Path

from feedgen.feed import FeedGenerator

DATA_DIR    = os.environ.get("DATA_DIR", "/data")
RSS_BASE_URL = os.environ.get("RSS_BASE_URL", "http://localhost:8000")
FEEDS_DIR   = os.path.join(DATA_DIR, "feeds")

_MIME = {
    ".jpg":  "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png":  "image/png",
    ".webp": "image/webp",
    ".mp4":  "video/mp4",
    ".mov":  "video/quicktime",
}


def _media_url(container_path: str) -> str:
    """Convert an absolute container path to a public URL.

    /data/media/username/abc.jpg  →  {RSS_BASE_URL}/media/username/abc.jpg
    """
    relative = container_path[len(DATA_DIR):].lstrip("/")
    return f"{RSS_BASE_URL}/{relative}"


def _mime(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return _MIME.get(ext, "application/octet-stream")


def _entry_html(post_type: str, caption: str, media_paths: list[str]) -> str:
    """Build the HTML blob that goes into <description>."""
    parts: list[str] = []

    for mp in media_paths:
        url = _media_url(mp)
        ext = os.path.splitext(mp)[1].lower()
        style = "max-width:100%;display:block;margin-bottom:8px;"
        if ext in (".mp4", ".mov"):
            parts.append(
                f'<video src="{url}" controls style="{style}" preload="metadata"></video>'
            )
        else:
            parts.append(f'<img src="{url}" style="{style}" loading="lazy" />')

    if caption:
        safe = html.escape(caption).replace("\n", "<br/>")
        parts.append(f"<p>{safe}</p>")

    return "".join(parts)


def build_feed(username: str, posts: list[dict]) -> str:
    """Build and save RSS XML. Returns path to saved file."""
    Path(FEEDS_DIR).mkdir(parents=True, exist_ok=True)

    fg = FeedGenerator()
    fg.id(f"{RSS_BASE_URL}/feeds/{username}.xml")
    fg.title(f"Instagram @{username}")
    fg.link(href=f"https://www.instagram.com/{username}/", rel="alternate")
    fg.link(href=f"{RSS_BASE_URL}/feeds/{username}.xml", rel="self")
    fg.description(f"Instagram posts from @{username} — via instaloader-rss")
    fg.language("pt-BR")
    fg.lastBuildDate(datetime.now(timezone.utc))

    for post in posts:
        fe = fg.add_entry()
        shortcode   = post["post_shortcode"]
        post_type   = post.get("post_type", "post")
        caption     = post.get("caption") or ""
        media_paths = post.get("media_paths") or []

        fe.id(f"https://www.instagram.com/p/{shortcode}/")
        fe.link(href=f"https://www.instagram.com/p/{shortcode}/")

        # Timestamp
        ts = post["timestamp"]
        if isinstance(ts, str):
            dt = datetime.fromisoformat(ts)
        else:
            dt = ts
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        fe.published(dt)
        fe.updated(dt)

        # Title: first non-empty line of caption, truncated to 120 chars
        first_line = next(
            (ln.strip() for ln in caption.splitlines() if ln.strip()), ""
        )
        title = (first_line[:120] + "…") if len(first_line) > 120 else first_line
        fe.title(title or f"{post_type.capitalize()} by @{username}")

        # Description HTML
        fe.description(_entry_html(post_type, caption, media_paths))

        # Enclosure: first media file
        if media_paths:
            first = media_paths[0]
            fe.enclosure(_media_url(first), 0, _mime(first))

    output = os.path.join(FEEDS_DIR, f"{username}.xml")
    fg.rss_file(output, pretty=True)
    return output
