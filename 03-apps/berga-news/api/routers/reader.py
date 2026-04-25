"""
Reader router — /reader/{article_id}
Fetches and renders full article content in a clean reading view.
"""
import logging
from urllib.parse import urljoin, urlparse

import httpx
import lxml.html
from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from readability import Document
from sqlalchemy.orm import Session

from auth import require_login
from db import Article, ArticleContent, ArticleRead, User, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")
log = logging.getLogger("reader")

_FETCH_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Mobile Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "DNT": "1",
}


def _extract_content(raw_html: str, base_url: str) -> str:
    """Use readability + lxml to extract clean, processed article HTML."""
    doc = Document(raw_html)
    summary_html = doc.summary(html_partial=False)

    # Parse and walk the DOM
    root = lxml.html.document_fromstring(summary_html)

    # Fix images: absolute src + lazy load + responsive class
    for img in root.iter("img"):
        src = img.get("src", "").strip()
        if not src or src.startswith("data:"):
            parent = img.getparent()
            if parent is not None:
                parent.remove(img)
            continue
        img.set("src", urljoin(base_url, src))
        img.set("loading", "lazy")
        # Preserve alt; set class for styling
        img.set("class", "reader-img")

    # Fix links: absolute href + open in new tab
    for a in root.iter("a"):
        href = a.get("href", "").strip()
        if href:
            a.set("href", urljoin(base_url, href))
        a.set("target", "_blank")
        a.set("rel", "noopener noreferrer")

    # Strip dangerous/useless elements
    for tag in ("script", "style", "iframe", "form", "button",
                 "input", "select", "textarea", "noscript", "svg"):
        for el in root.iter(tag):
            p = el.getparent()
            if p is not None:
                p.remove(el)

    # Extract body HTML string
    body = root.find(".//body")
    if body is not None:
        return lxml.html.tostring(body, encoding="unicode", method="html")

    return lxml.html.tostring(root, encoding="unicode", method="html")


def _fetch_and_cache(db: Session, article: Article) -> ArticleContent:
    """Fetch article URL, extract readable HTML, cache in DB."""
    try:
        with httpx.Client(
            headers=_FETCH_HEADERS,
            follow_redirects=True,
            timeout=20,
        ) as client:
            resp = client.get(article.url)
            resp.raise_for_status()
            content_type = resp.headers.get("content-type", "")
            if "html" not in content_type:
                raise ValueError(f"Tipo de conteúdo não suportado: {content_type}")

        html = _extract_content(resp.text, article.url)
        ac = ArticleContent(article_id=article.id, html=html)

    except Exception as exc:
        log.warning("Falha ao buscar artigo %s: %s", article.id, exc)
        # Store error so we don't retry on every request (cache the failure)
        ac = ArticleContent(
            article_id=article.id,
            html="",
            fetch_error=str(exc)[:500],
        )

    # Upsert
    existing = db.get(ArticleContent, article.id)
    if existing:
        existing.html = ac.html
        existing.fetch_error = ac.fetch_error
        from datetime import datetime
        existing.fetched_at = datetime.utcnow()
    else:
        db.add(ac)
    db.commit()
    db.refresh(ac if not existing else existing)
    return existing or ac


@router.get("/reader/{article_id}")
def reader_page(
    article_id: int,
    request: Request,
    refetch: bool = False,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    article = db.get(Article, article_id)
    if not article:
        return RedirectResponse("/articles", status_code=303)

    # Get or fetch cached content
    content = db.get(ArticleContent, article_id)
    if content is None or refetch:
        content = _fetch_and_cache(db, article)

    # Auto-mark as read when opening reader
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
