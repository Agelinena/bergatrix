"""
Reader router — /reader/{article_id}

Page renders immediately. If content is not cached, the template triggers a JS
fetch to /reader/{id}/fetch which does the extraction asynchronously.
"""
import logging
from urllib.parse import urljoin

import httpx
import lxml.html
from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import require_login
from db import Article, ArticleContent, ArticleRead, User, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")
log = logging.getLogger("reader")

_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
    "Cache-Control": "no-cache",
    "DNT": "1",
    "Upgrade-Insecure-Requests": "1",
}


def _process_html(raw_html: str, base_url: str) -> str:
    """Fix relative URLs, strip scripts, return clean body HTML."""
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
                 "input", "select", "textarea", "noscript", "aside",
                 "nav", "footer", "header", "figure > figcaption ~ *"):
        for el in list(root.iter(tag)):
            p = el.getparent()
            if p is not None:
                p.remove(el)

    body = root.find(".//body")
    target = body if body is not None else root
    return lxml.html.tostring(target, encoding="unicode", method="html")


def extract_content(raw_html: str, base_url: str) -> str | None:
    """
    Try trafilatura first (best for news), then readability as fallback.
    Returns processed HTML string, or None if both fail.
    """
    html_out = None

    # — trafilatura —
    try:
        import trafilatura
        result = trafilatura.extract(
            raw_html,
            output_format="html",
            include_images=True,
            include_links=True,
            include_tables=True,
            no_fallback=False,
            favor_recall=True,       # prioritise completeness over precision
        )
        if result and len(result) > 300:
            html_out = result
            log.debug("trafilatura extracted %d chars", len(result))
    except Exception as exc:
        log.warning("trafilatura failed: %s", exc)

    # — readability fallback —
    if not html_out:
        try:
            from readability import Document
            doc = Document(raw_html)
            result = doc.summary(html_partial=False)
            if result and len(result) > 300:
                html_out = result
                log.debug("readability extracted %d chars", len(result))
        except Exception as exc:
            log.warning("readability failed: %s", exc)

    if not html_out:
        return None

    return _process_html(html_out, base_url)


def fetch_and_cache(db: Session, article: Article, force: bool = False) -> ArticleContent:
    """Fetch, extract and cache article content. Returns the ArticleContent row."""
    existing = db.get(ArticleContent, article.id)
    if existing and not force:
        return existing

    html_out = None
    error_msg = None

    try:
        with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=20) as client:
            resp = client.get(article.url)
            resp.raise_for_status()
            ct = resp.headers.get("content-type", "")
            if "html" not in ct:
                raise ValueError(f"Conteúdo não HTML: {ct}")
            raw = resp.text

        html_out = extract_content(raw, str(resp.url))
        if not html_out:
            raise ValueError("Extração retornou vazio")

    except Exception as exc:
        error_msg = str(exc)[:500]
        log.warning("Falha ao buscar artigo %d (%s): %s", article.id, article.url, exc)

    if existing:
        existing.html = html_out or ""
        existing.fetch_error = error_msg
        from datetime import datetime
        existing.fetched_at = datetime.utcnow()
        db.commit()
        return existing
    else:
        ac = ArticleContent(
            article_id=article.id,
            html=html_out or "",
            fetch_error=error_msg,
        )
        db.add(ac)
        db.commit()
        return ac


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/reader/{article_id}")
def reader_page(
    article_id: int,
    request: Request,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    """Renders immediately. If content is cached, shows it; otherwise JS fetches it."""
    article = db.get(Article, article_id)
    if not article:
        return RedirectResponse("/articles", status_code=303)

    content = db.get(ArticleContent, article_id)

    # Auto-mark as read
    if not db.query(ArticleRead).filter(
        ArticleRead.user_id == user.id,
        ArticleRead.article_id == article_id,
    ).first():
        db.add(ArticleRead(user_id=user.id, article_id=article_id))
        db.commit()

    return templates.TemplateResponse(
        "reader.html",
        {
            "request": request,
            "user": user,
            "article": article,
            "content": content,
        },
    )


@router.get("/reader/{article_id}/fetch")
def fetch_content_api(
    article_id: int,
    force: bool = False,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    """
    Called by JS when content is not yet cached.
    Returns JSON: {html, error}.
    """
    # If already cached and not forced, return immediately
    existing = db.get(ArticleContent, article_id)
    if existing and not force:
        return JSONResponse({
            "html": existing.html or None,
            "error": existing.fetch_error or None,
        })

    article = db.get(Article, article_id)
    if not article:
        return JSONResponse({"html": None, "error": "Artigo não encontrado"}, status_code=404)

    content = fetch_and_cache(db, article, force=force)
    return JSONResponse({
        "html": content.html or None,
        "error": content.fetch_error or None,
    })
