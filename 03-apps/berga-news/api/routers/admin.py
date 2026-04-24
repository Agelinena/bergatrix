import secrets

import feedparser
from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import desc
from sqlalchemy.orm import Session

from auth import User, hash_password, require_admin
from db import DigestRun, Feed, Setting, get_db

router = APIRouter(prefix="/admin")
templates = Jinja2Templates(directory="templates")


def _resolve_feed_title(url: str) -> tuple[str, str]:
    try:
        parsed = feedparser.parse(url)
        title = parsed.feed.get("title", "") or url
        site_url = parsed.feed.get("link", "") or ""
        return title[:200], site_url[:500]
    except Exception:
        return url, ""


@router.get("", response_class=HTMLResponse)
def admin_page(
    request: Request,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
    msg: str = "",
):
    from db import User as UserModel
    users = db.query(UserModel).order_by(UserModel.username).all()
    global_feeds = (
        db.query(Feed).filter(Feed.owner_id == None).order_by(Feed.title).all()
    )
    runs = (
        db.query(DigestRun)
        .order_by(desc(DigestRun.started_at))
        .limit(20)
        .all()
    )
    return templates.TemplateResponse("admin.html", {
        "request": request,
        "user": user,
        "users": users,
        "global_feeds": global_feeds,
        "runs": runs,
        "msg": msg,
    })


# ── Users ────────────────────────────────────────────────────────────────────

@router.post("/users")
def create_user(
    username: str = Form(...),
    password: str = Form(""),
    role: str = Form("user"),
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    from db import User as UserModel
    if db.query(UserModel).filter(UserModel.username == username).first():
        return RedirectResponse("/admin?msg=Usuário+já+existe", status_code=303)
    pwd = password.strip() or secrets.token_urlsafe(12)
    db.add(UserModel(username=username, password_hash=hash_password(pwd), role=role))
    db.commit()
    return RedirectResponse(f"/admin?msg=Usuário+{username}+criado+(senha:+{pwd})", status_code=303)


@router.post("/users/{user_id}/delete")
def delete_user(
    user_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    from db import User as UserModel
    target = db.get(UserModel, user_id)
    if not target:
        raise HTTPException(404)
    if target.id == user.id:
        return RedirectResponse("/admin?msg=Não+pode+deletar+a+si+mesmo", status_code=303)
    db.delete(target)
    db.commit()
    return RedirectResponse("/admin?msg=Usuário+removido", status_code=303)


# ── Global Feeds ─────────────────────────────────────────────────────────────

@router.post("/feeds")
def add_global_feed(
    url: str = Form(...),
    category: str = Form(""),
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    url = url.strip()
    if not url:
        return RedirectResponse("/admin?msg=URL+inválida", status_code=303)
    existing = db.query(Feed).filter(Feed.owner_id == None, Feed.url == url).first()
    if existing:
        return RedirectResponse("/admin?msg=Feed+já+existe", status_code=303)
    title, site_url = _resolve_feed_title(url)
    db.add(Feed(owner_id=None, url=url, title=title, site_url=site_url, category=category.strip() or None))
    db.commit()
    return RedirectResponse("/admin?msg=Feed+global+adicionado", status_code=303)


@router.post("/feeds/{feed_id}/delete")
def delete_global_feed(
    feed_id: int,
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    feed = db.get(Feed, feed_id)
    if not feed or feed.owner_id is not None:
        raise HTTPException(404)
    db.delete(feed)
    db.commit()
    return RedirectResponse("/admin?msg=Feed+removido", status_code=303)


# ── Digest trigger ────────────────────────────────────────────────────────────

@router.post("/digest/trigger")
def trigger_digest(
    user: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    setting = db.get(Setting, "pending_digest_trigger")
    if setting:
        setting.value = "1"
    else:
        db.add(Setting(key="pending_digest_trigger", value="1"))
    db.commit()
    return RedirectResponse("/admin?msg=Digest+agendado+para+execução+imediata", status_code=303)
