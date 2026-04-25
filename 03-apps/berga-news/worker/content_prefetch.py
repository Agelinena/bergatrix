"""
content_prefetch.py — pre-fetches and caches article content in the background.

Called by the worker after each feed fetch so the reader opens instantly.
"""
import logging
from datetime import datetime, timedelta
from urllib.parse import urljoin

import httpx
import lxml.html
from sqlalchemy.orm import Session

from db import Article, ArticleContent, Feed

log = logging.getLogger("prefetch")

PREFETCH_LIMIT = 30        # max articles to prefetch per run
PREFETCH_AGE_HOURS = 48   # only prefetch articles newer than this

_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "DNT": "1",
}


def _process_html(raw_html: str, base_url: str) -> str:
    try:
        root = lxml.html.document_fromstring(raw_html)
    except Exception:
        return raw_html

    for img in list(root.iter("img")):
        src = (img.get("src") or img.get("data-src") or "").strip()
        if not src or src.startswith("data:"):
            p = img.getparent()
            if p is not None:
                p.remove(img)
            continue
        img.set("src", urljoin(base_url, src))
        img.attrib.pop("data-src", None)
        img.attrib.pop("srcset", None)
        img.set("loading", "lazy")
        img.set("class", "reader-img")

    for a in root.iter("a"):
        href = (a.get("href") or "").strip()
        if href:
            a.set("href", urljoin(base_url, href))
        a.set("target", "_blank")
        a.set("rel", "noopener noreferrer")

    for tag in ("script", "style", "iframe", "form", "button",
                 "input", "select", "textarea", "noscript", "aside", "nav"):
        for el in list(root.iter(tag)):
            p = el.getparent()
            if p is not None:
                p.remove(el)

    body = root.find(".//body")
    target = body if body is not None else root
    return lxml.html.tostring(target, encoding="unicode", method="html")


def _extract(raw_html: str, base_url: str) -> str | None:
    result = None

    try:
        import trafilatura
        result = trafilatura.extract(
            raw_html,
            output_format="html",
            include_images=True,
            include_links=True,
            include_tables=True,
            no_fallback=False,
            favor_recall=True,
        )
        if result and len(result) > 300:
            return _process_html(result, base_url)
    except Exception as exc:
        log.debug("trafilatura: %s", exc)

    try:
        from readability import Document
        doc = Document(raw_html)
        result = doc.summary(html_partial=False)
        if result and len(result) > 300:
            return _process_html(result, base_url)
    except Exception as exc:
        log.debug("readability: %s", exc)

    return None


def prefetch_recent(db: Session) -> None:
    """Fetch content for recent articles that don't have cached content yet."""
    cutoff = datetime.utcnow() - timedelta(hours=PREFETCH_AGE_HOURS)

    cached_ids = {
        row.article_id for row in db.query(ArticleContent.article_id).all()
    }

    articles = (
        db.query(Article)
        .join(Feed, Article.feed_id == Feed.id)
        .filter(
            Feed.active.is_(True),
            Article.published_at >= cutoff,
            Article.id.not_in(cached_ids) if cached_ids else Article.id.isnot(None),
        )
        .order_by(Article.published_at.desc())
        .limit(PREFETCH_LIMIT)
        .all()
    )

    if not articles:
        log.debug("prefetch: nothing to fetch")
        return

    log.info("prefetch: fetching content for %d articles", len(articles))
    ok = 0
    fail = 0

    with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=15) as client:
        for article in articles:
            html_out = None
            error_msg = None
            try:
                resp = client.get(article.url)
                resp.raise_for_status()
                ct = resp.headers.get("content-type", "")
                if "html" not in ct:
                    raise ValueError(f"non-HTML: {ct}")
                html_out = _extract(resp.text, str(resp.url))
                if not html_out:
                    raise ValueError("extração vazia")
                ok += 1
            except Exception as exc:
                error_msg = str(exc)[:300]
                fail += 1
                log.debug("prefetch fail %d: %s", article.id, exc)

            db.add(ArticleContent(
                article_id=article.id,
                html=html_out or "",
                fetch_error=error_msg,
            ))
            # Commit per article so partial progress is saved
            try:
                db.commit()
            except Exception:
                db.rollback()

    log.info("prefetch done: %d ok, %d failed", ok, fail)
