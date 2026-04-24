import feedparser
from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import User, require_login
from db import Feed, Setting, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")


def _resolve_feed_title(url: str) -> tuple[str, str]:
    """Fetch feed to get title and site_url. Returns (title, site_url)."""
    try:
        parsed = feedparser.parse(url)
        title = parsed.feed.get("title", "") or url
        site_url = parsed.feed.get("link", "") or ""
        return title[:200], site_url[:500]
    except Exception:
        return url, ""


@router.get("/feeds", response_class=HTMLResponse)
def feeds_page(
    request: Request,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
    msg: str = "",
):
    personal = (
        db.query(Feed)
        .filter(Feed.owner_id == user.id, Feed.active == True)
        .order_by(Feed.title)
        .all()
    )
    global_feeds = (
        db.query(Feed)
        .filter(Feed.owner_id == None, Feed.active == True)
        .order_by(Feed.title)
        .all()
    )
    return templates.TemplateResponse("feeds.html", {
        "request": request,
        "user": user,
        "personal": personal,
        "global_feeds": global_feeds,
        "msg": msg,
    })


@router.post("/feeds")
def add_feed(
    request: Request,
    url: str = Form(...),
    category: str = Form(""),
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    url = url.strip()
    if not url:
        return RedirectResponse("/feeds?msg=URL+inválida", status_code=303)

    existing = (
        db.query(Feed)
        .filter(Feed.owner_id == user.id, Feed.url == url)
        .first()
    )
    if existing:
        return RedirectResponse("/feeds?msg=Feed+já+existe", status_code=303)

    title, site_url = _resolve_feed_title(url)
    feed = Feed(
        owner_id=user.id,
        url=url,
        title=title,
        site_url=site_url,
        category=category.strip() or None,
    )
    db.add(feed)
    db.commit()
    return RedirectResponse("/feeds?msg=Feed+adicionado+com+sucesso", status_code=303)


@router.post("/feeds/{feed_id}/delete")
def delete_feed(
    feed_id: int,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    feed = db.get(Feed, feed_id)
    if not feed or feed.owner_id != user.id:
        raise HTTPException(404)
    db.delete(feed)
    db.commit()
    return RedirectResponse("/feeds?msg=Feed+removido", status_code=303)


@router.post("/feeds/{feed_id}/refresh")
def refresh_feed(
    feed_id: int,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    feed = db.get(Feed, feed_id)
    if not feed or (feed.owner_id != user.id and user.role != "admin"):
        raise HTTPException(404)
    # Signal worker to refresh this specific feed
    setting = db.get(Setting, "refresh_feed_ids")
    ids = set(setting.value.split(",")) if setting and setting.value else set()
    ids.add(str(feed_id))
    if setting:
        setting.value = ",".join(ids)
    else:
        db.add(Setting(key="refresh_feed_ids", value=",".join(ids)))
    db.commit()
    return RedirectResponse("/feeds?msg=Refresh+agendado", status_code=303)
