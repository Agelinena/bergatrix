from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import desc
from sqlalchemy.orm import Session, joinedload

from auth import User, require_login
from db import Article, Cluster, DigestRun, Feed, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")


@router.get("/", response_class=HTMLResponse)
def root(user: User = Depends(require_login)):
    return RedirectResponse("/digest/latest", status_code=303)


@router.get("/digest/latest", response_class=HTMLResponse)
def latest_digest(
    request: Request,
    category: str = "",
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    run = (
        db.query(DigestRun)
        .filter(DigestRun.status == "done")
        .order_by(desc(DigestRun.finished_at))
        .first()
    )
    if not run:
        return templates.TemplateResponse(
            "index.html",
            {"request": request, "user": user, "run": None, "clusters": [], "categories": []},
        )
    return _render_run(request, run.id, category, user, db)


@router.get("/digest/{run_id}", response_class=HTMLResponse)
def digest_by_id(
    run_id: int,
    request: Request,
    category: str = "",
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    return _render_run(request, run_id, category, user, db)


def _render_run(request, run_id: int, category: str, user: User, db: Session):
    run = db.get(DigestRun, run_id)
    if not run:
        raise HTTPException(404, "Digest não encontrado.")

    q = db.query(Cluster).filter(Cluster.digest_run_id == run_id)
    clusters_raw = q.order_by(desc(Cluster.article_count)).all()

    cluster_data = []
    all_categories = set()
    for c in clusters_raw:
        articles = (
            db.query(Article)
            .options(joinedload(Article.feed))
            .filter(Article.cluster_id == c.id)
            .all()
        )
        sources = list({a.feed.title or a.feed.url for a in articles if a.feed})
        cats = list({a.feed.category for a in articles if a.feed and a.feed.category})
        for cat in cats:
            all_categories.add(cat)
        cluster_data.append({
            "id": c.id,
            "label": c.label,
            "summary": c.summary,
            "article_count": c.article_count,
            "sources": sources,
            "categories": cats,
        })

    if category:
        cluster_data = [c for c in cluster_data if category in c["categories"]]

    recent_runs = (
        db.query(DigestRun)
        .filter(DigestRun.status == "done")
        .order_by(desc(DigestRun.finished_at))
        .limit(10)
        .all()
    )

    return templates.TemplateResponse("index.html", {
        "request": request,
        "user": user,
        "run": run,
        "clusters": cluster_data,
        "categories": sorted(all_categories),
        "selected_category": category,
        "recent_runs": recent_runs,
    })


@router.get("/digest/{run_id}/cluster/{cluster_id}", response_class=HTMLResponse)
def cluster_detail(
    run_id: int,
    cluster_id: int,
    request: Request,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    cluster = db.get(Cluster, cluster_id)
    if not cluster or cluster.digest_run_id != run_id:
        raise HTTPException(404, "Cluster não encontrado.")

    articles = (
        db.query(Article)
        .options(joinedload(Article.feed))
        .filter(Article.cluster_id == cluster_id)
        .order_by(desc(Article.published_at))
        .all()
    )

    return templates.TemplateResponse("cluster.html", {
        "request": request,
        "user": user,
        "cluster": cluster,
        "run_id": run_id,
        "articles": articles,
    })
