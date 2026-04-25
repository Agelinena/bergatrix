"""
RSS feed fetcher. Uses feedparser with ETag/Last-Modified for conditional fetches.
"""
import logging
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Optional

import feedparser
from sqlalchemy.orm import Session

from db import Article, Feed

log = logging.getLogger("fetcher")

_STRIP_TAGS_TABLE = str.maketrans("", "", "<>")


def _strip_html(text: str) -> str:
    import re
    text = re.sub(r"<[^>]+>", " ", text or "")
    return " ".join(text.split())[:500]


def _parse_date(entry) -> Optional[datetime]:
    for field in ("published_parsed", "updated_parsed"):
        val = getattr(entry, field, None)
        if val:
            try:
                import time
                return datetime(*val[:6])
            except Exception:
                pass
    return None


def fetch_feed(db: Session, feed: Feed) -> int:
    """Fetch a single feed. Returns number of new articles inserted."""
    headers = {}
    if feed.last_etag:
        headers["If-None-Match"] = feed.last_etag
    if feed.last_modified:
        headers["If-Modified-Since"] = feed.last_modified

    try:
        parsed = feedparser.parse(feed.url, request_headers=headers)
    except Exception as exc:
        log.warning("[feed:%d] Parse error: %s", feed.id, exc)
        feed.last_fetch_status = f"error:{exc}"
        db.commit()
        return 0

    status = getattr(parsed, "status", None)

    if status == 304:
        log.info("[feed:%d] Not modified (304)", feed.id)
        feed.last_fetched_at = datetime.utcnow()
        feed.last_fetch_status = "ok:304"
        db.commit()
        return 0

    if status is not None and status not in (200, 301, 302):
        log.warning("[feed:%d] HTTP %s", feed.id, status)
        feed.last_fetch_status = f"error:http{status}"
        db.commit()
        return 0

    if not parsed.entries:
        log.warning("[feed:%d] Nenhum entry encontrado (boilerplate ou feed vazio)", feed.id)
        feed.last_fetched_at = datetime.utcnow()
        feed.last_fetch_status = "ok:empty"
        db.commit()
        return 0

    # Update ETag / Last-Modified for next request
    feed.last_etag = parsed.get("etag") or None
    feed.last_modified = parsed.get("modified") or None

    # Update feed metadata if available
    if not feed.title and parsed.feed.get("title"):
        feed.title = parsed.feed.title[:200]
    if not feed.site_url and parsed.feed.get("link"):
        feed.site_url = parsed.feed.link[:500]

    new_count = 0
    for entry in parsed.entries:
        guid = entry.get("id") or entry.get("link") or entry.get("title", "")
        if not guid:
            continue

        exists = (
            db.query(Article)
            .filter(Article.feed_id == feed.id, Article.guid == guid)
            .first()
        )
        if exists:
            continue

        title = (entry.get("title") or "").strip()[:500]
        if not title:
            continue

        raw_desc = entry.get("summary") or entry.get("description") or ""
        description = _strip_html(raw_desc)
        url = entry.get("link") or ""
        author = (entry.get("author") or "").strip()[:200] or None
        published_at = _parse_date(entry)

        article = Article(
            feed_id=feed.id,
            guid=guid,
            title=title,
            description=description,
            url=url,
            author=author,
            published_at=published_at,
        )
        db.add(article)
        new_count += 1

    feed.last_fetched_at = datetime.utcnow()
    feed.last_fetch_status = "ok"
    db.commit()

    if new_count:
        log.info("[feed:%d] %s — %d new article(s)", feed.id, feed.title or feed.url, new_count)
    return new_count


def fetch_all_feeds(db: Session) -> int:
    feeds = db.query(Feed).filter(Feed.active == True).all()
    total = 0
    for feed in feeds:
        try:
            total += fetch_feed(db, feed)
        except Exception as exc:
            log.error("[feed:%d] Unexpected error: %s", feed.id, exc, exc_info=True)
    log.info("fetch_all_feeds done: %d new article(s) across %d feed(s)", total, len(feeds))
    return total
