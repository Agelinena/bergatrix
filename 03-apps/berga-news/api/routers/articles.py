"""
Articles router — /articles
List all articles grouped by feed; toggle read/unread; share link.
"""
import logging
from typing import Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import require_login
from db import Article, ArticleRead, Feed, User, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")
log = logging.getLogger("articles")

PAGE_SIZE = 50


@router.get("/articles")
def articles_page(
    request: Request,
    feed_id: Optional[int] = None,
    show: str = "all",          # all | unread
    page: int = 1,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    # All feeds visible to this user (personal + global)
    feeds = (
        db.query(Feed)
        .filter(
            Feed.active.is_(True),
            (Feed.owner_id == user.id) | (Feed.owner_id.is_(None)),
        )
        .order_by(Feed.title)
        .all()
    )

    # Read article IDs for this user
    read_ids: set[int] = {
        r.article_id
        for r in db.query(ArticleRead).filter(ArticleRead.user_id == user.id).all()
    }

    # Build article query
    q = (
        db.query(Article)
        .join(Feed, Article.feed_id == Feed.id)
        .filter(
            (Feed.owner_id == user.id) | (Feed.owner_id.is_(None)),
            Feed.active.is_(True),
        )
    )

    if feed_id:
        q = q.filter(Article.feed_id == feed_id)

    if show == "unread":
        q = q.filter(Article.id.not_in(read_ids) if read_ids else Article.id.isnot(None))

    total = q.count()
    articles = (
        q.order_by(Article.published_at.desc())
        .offset((page - 1) * PAGE_SIZE)
        .limit(PAGE_SIZE)
        .all()
    )

    # Unread counts per feed (for tab badges)
    unread_by_feed: dict[int, int] = {}
    for f in feeds:
        unread_by_feed[f.id] = (
            db.query(Article)
            .filter(
                Article.feed_id == f.id,
                Article.id.not_in(read_ids) if read_ids else Article.id.isnot(None),
            )
            .count()
        )

    total_unread = sum(unread_by_feed.values())
    pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)

    return templates.TemplateResponse(
        "articles.html",
        {
            "request": request,
            "user": user,
            "feeds": feeds,
            "articles": articles,
            "read_ids": read_ids,
            "selected_feed_id": feed_id,
            "show": show,
            "page": page,
            "pages": pages,
            "total": total,
            "unread_by_feed": unread_by_feed,
            "total_unread": total_unread,
        },
    )


@router.post("/articles/{article_id}/toggle-read")
def toggle_read(
    article_id: int,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    existing = (
        db.query(ArticleRead)
        .filter(ArticleRead.user_id == user.id, ArticleRead.article_id == article_id)
        .first()
    )
    if existing:
        db.delete(existing)
        db.commit()
        return JSONResponse({"read": False})
    else:
        db.add(ArticleRead(user_id=user.id, article_id=article_id))
        db.commit()
        return JSONResponse({"read": True})


@router.post("/articles/mark-all-read")
def mark_all_read(
    request: Request,
    feed_id: Optional[int] = None,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    """Mark all visible articles as read (optionally filtered by feed)."""
    q = (
        db.query(Article)
        .join(Feed, Article.feed_id == Feed.id)
        .filter(
            (Feed.owner_id == user.id) | (Feed.owner_id.is_(None)),
            Feed.active.is_(True),
        )
    )
    if feed_id:
        q = q.filter(Article.feed_id == feed_id)

    already_read: set[int] = {
        r.article_id
        for r in db.query(ArticleRead).filter(ArticleRead.user_id == user.id).all()
    }
    new_reads = [
        ArticleRead(user_id=user.id, article_id=a.id)
        for a in q.all()
        if a.id not in already_read
    ]
    if new_reads:
        db.bulk_save_objects(new_reads)
        db.commit()

    redirect_url = "/articles"
    if feed_id:
        redirect_url += f"?feed_id={feed_id}"
    from fastapi.responses import RedirectResponse
    return RedirectResponse(redirect_url, status_code=303)
