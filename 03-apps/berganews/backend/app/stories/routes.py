"""Histórias (aba "IA"): /api/stories, e a calibração do admin.

A história é da casa; cada pessoa vê as que têm pelo menos um artigo de um
veículo que ela assina, e dentro dela todos os veículos (os que ela não
assina aparecem como "também noticiado por").
"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from app.articles.routes import _cursor, _parse_cursor
from app.auth.dependencies import CurrentUser, admin_user, current_user
from app.config import settings
from app.core import html as h
from app.core.db import get_pool
from app.core.redis import get_redis
from app.stories import cluster

router = APIRouter(prefix="/api/stories", tags=["stories"])
admin_router = APIRouter(prefix="/api/admin/stories", tags=["admin"])

RECLUSTER_KEY = cluster.RECLUSTER_KEY

# Artigos da história vindos de veículos que a pessoa assina.
_MINE = """SELECT 1 FROM story_articles m JOIN articles ma ON ma.id = m.article_id
           JOIN subscriptions ms ON ms.feed_id = ma.feed_id AND ms.user_id = $1
           WHERE m.story_id = s.id"""


class Source(BaseModel):
    feed_id: int
    title: str
    followed: bool


class StoryItem(BaseModel):
    id: int
    title: str
    first_published_at: str
    last_published_at: str
    article_count: int
    source_count: int
    unread: int
    image: str | None
    sources: list[Source]


class StoryPage(BaseModel):
    items: list[StoryItem]
    next_cursor: str | None


class TimelineArticle(BaseModel):
    id: int
    feed_id: int
    feed_title: str
    followed: bool
    title: str
    summary: str | None
    image: str | None
    url: str
    language: str | None
    published_at: str
    read: bool
    saved: bool
    full_text: bool
    similarity: float | None
    manual: bool


class Story(BaseModel):
    id: int
    title: str
    first_published_at: str
    last_published_at: str
    article_count: int
    source_count: int
    # Em ordem de publicação: a linha do tempo. O resumo chega na fase 3.
    articles: list[TimelineArticle]


class MergeIn(BaseModel):
    other_id: int


class SplitIn(BaseModel):
    article_ids: list[int] = Field(min_length=1, max_length=200)


def _image(url: str | None) -> str | None:
    return h.image_link(url) if url and url.startswith(("http://", "https://")) else None


async def _sources_and_images(pool, user_id: str, story_ids: list[int]):
    rows = await pool.fetch(
        """SELECT sa.story_id, a.feed_id,
                  coalesce(nullif(sub.title, ''), nullif(f.title, ''), f.url) AS title,
                  sub.user_id IS NOT NULL AS followed, min(a.published_at) AS first,
                  (array_agg(a.image_url ORDER BY a.published_at)
                     FILTER (WHERE a.image_url IS NOT NULL))[1] AS image
           FROM story_articles sa JOIN articles a ON a.id = sa.article_id
           JOIN feeds f ON f.id = a.feed_id
           LEFT JOIN subscriptions sub ON sub.feed_id = a.feed_id AND sub.user_id = $1
           WHERE sa.story_id = ANY($2::bigint[])
           GROUP BY sa.story_id, a.feed_id, 3, 4
           ORDER BY sa.story_id, followed DESC, first""", user_id, story_ids)
    sources: dict[int, list[Source]] = {}
    images: dict[int, str | None] = {}
    for r in rows:
        sources.setdefault(r["story_id"], []).append(
            Source(feed_id=r["feed_id"], title=r["title"], followed=r["followed"]))
        if not images.get(r["story_id"]) and r["image"]:
            images[r["story_id"]] = _image(r["image"])
    return sources, images


@router.get("", response_model=StoryPage)
async def list_stories(
    days: int = Query(3, ge=1, le=30),
    min_sources: int = Query(2, ge=1, le=20),
    cursor: str | None = Query(None, max_length=200),
    limit: int = Query(30, ge=1, le=100),
    user: CurrentUser = Depends(current_user),
):
    """Mais recentes primeiro (pela última matéria que entrou)."""
    args: list = [user.id, min_sources, days]
    where = ["s.source_count >= $2", "s.last_published_at > now() - make_interval(days => $3)",
             f"EXISTS ({_MINE})"]
    if cursor:
        when, last_id = _parse_cursor(cursor)
        args += [when, last_id]
        where.append(f"(s.last_published_at, s.id) < (${len(args) - 1}, ${len(args)})")
    args.append(limit + 1)
    pool = get_pool()
    rows = await pool.fetch(
        f"""SELECT s.*,
                   (SELECT count(*) FROM story_articles u
                     WHERE u.story_id = s.id AND NOT EXISTS (
                       SELECT 1 FROM article_states st WHERE st.user_id = $1
                         AND st.article_id = u.article_id AND st.read_at IS NOT NULL)) AS unread
            FROM stories s WHERE {' AND '.join(where)}
            ORDER BY s.last_published_at DESC, s.id DESC LIMIT ${len(args)}""", *args)
    more = len(rows) > limit
    rows = rows[:limit]
    sources, images = await _sources_and_images(pool, user.id, [r["id"] for r in rows])
    items = [StoryItem(
        id=r["id"], title=r["title"], first_published_at=r["first_published_at"].isoformat(),
        last_published_at=r["last_published_at"].isoformat(), article_count=r["article_count"],
        source_count=r["source_count"], unread=r["unread"], image=images.get(r["id"]),
        sources=sources.get(r["id"], [])) for r in rows]
    next_cursor = _cursor(rows[-1]["last_published_at"], rows[-1]["id"]) if more and rows else None
    return StoryPage(items=items, next_cursor=next_cursor)


async def _visible_story(pool, user_id: str, story_id: int):
    row = await pool.fetchrow(f"SELECT s.* FROM stories s WHERE s.id = $2 AND EXISTS ({_MINE})",
                              user_id, story_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="História não encontrada")
    return row


@router.get("/{story_id}", response_model=Story)
async def get_story(story_id: int, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    story = await _visible_story(pool, user.id, story_id)
    rows = await pool.fetch(
        """SELECT a.id, a.feed_id, coalesce(nullif(sub.title, ''), nullif(f.title, ''), f.url) AS feed_title,
                  sub.user_id IS NOT NULL AS followed, a.title, a.summary, a.image_url, a.url,
                  a.language, a.published_at, st.read_at IS NOT NULL AS read,
                  st.saved_at IS NOT NULL AS saved, a.content_status = 'ok' AS full_text,
                  sa.similarity, sa.added_by = 'manual' AS manual
           FROM story_articles sa JOIN articles a ON a.id = sa.article_id
           JOIN feeds f ON f.id = a.feed_id
           LEFT JOIN subscriptions sub ON sub.feed_id = a.feed_id AND sub.user_id = $1
           LEFT JOIN article_states st ON st.article_id = a.id AND st.user_id = $1
           WHERE sa.story_id = $2 ORDER BY a.published_at, a.id""", user.id, story_id)
    return Story(
        id=story["id"], title=story["title"],
        first_published_at=story["first_published_at"].isoformat(),
        last_published_at=story["last_published_at"].isoformat(),
        article_count=story["article_count"], source_count=story["source_count"],
        articles=[TimelineArticle(
            id=r["id"], feed_id=r["feed_id"], feed_title=r["feed_title"], followed=r["followed"],
            title=r["title"], summary=(r["summary"] or "")[:320] or None, image=_image(r["image_url"]),
            url=r["url"], language=r["language"], published_at=r["published_at"].isoformat(),
            read=r["read"], saved=r["saved"], full_text=bool(r["full_text"]),
            similarity=round(r["similarity"], 3) if r["similarity"] is not None else None,
            manual=r["manual"]) for r in rows])


@router.post("/{story_id}/merge", status_code=status.HTTP_204_NO_CONTENT)
async def merge_stories(story_id: int, body: MergeIn, user: CurrentUser = Depends(current_user)):
    """Junta outra história nesta ("é a mesma notícia"). Vale para a casa toda,
    e vira exemplo para calibrar o agrupamento."""
    if body.other_id == story_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="É a mesma história")
    pool = get_pool()
    await _visible_story(pool, user.id, story_id)
    await _visible_story(pool, user.id, body.other_id)
    async with pool.acquire() as conn, conn.transaction():
        await cluster.merge(conn, story_id, body.other_id, user.id)


@router.post("/{story_id}/split")
async def split_story(story_id: int, body: SplitIn, user: CurrentUser = Depends(current_user)):
    """Tira artigos para uma história nova ("não é a mesma notícia")."""
    pool = get_pool()
    story = await _visible_story(pool, user.id, story_id)
    if len(set(body.article_ids)) >= story["article_count"]:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            detail="Deixe pelo menos um artigo na história original")
    async with pool.acquire() as conn, conn.transaction():
        try:
            new_id = await cluster.split(conn, story_id, body.article_ids, user.id)
        except ValueError as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return {"story_id": new_id}


# ── Calibração (admin) ──────────────────────────────────────────────

class PairIn(BaseModel):
    article_a: int
    article_b: int
    same: bool


class ThresholdRow(BaseModel):
    threshold: float
    precision: float
    recall: float
    f1: float


class Calibration(BaseModel):
    current_threshold: float
    strong_threshold: float
    pairs: int
    same: int
    different: int
    best: ThresholdRow | None
    table: list[ThresholdRow]


class SuggestedPair(BaseModel):
    article_a: int
    title_a: str
    feed_a: str
    article_b: int
    title_b: str
    feed_b: str
    similarity: float


def score(pairs: list[tuple[float, bool]]) -> list[ThresholdRow]:
    """Precisão, cobertura e F1 de "junta se similaridade ≥ limite" para
    cada limite de 0,60 a 0,95. Só a similaridade: a checagem de entidade
    deixa o resultado real um pouco mais conservador."""
    table = []
    for step in range(60, 96):
        t = step / 100
        tp = sum(1 for sim, same in pairs if sim >= t and same)
        fp = sum(1 for sim, same in pairs if sim >= t and not same)
        fn = sum(1 for sim, same in pairs if sim < t and same)
        precision = tp / (tp + fp) if tp + fp else 1.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        table.append(ThresholdRow(threshold=t, precision=round(precision, 3),
                                  recall=round(recall, 3), f1=round(f1, 3)))
    return table


@admin_router.get("/calibration", response_model=Calibration)
async def calibration(_: CurrentUser = Depends(admin_user)):
    rows = await get_pool().fetch(
        """SELECT 1 - (ea.embedding <=> eb.embedding) AS sim, p.same
           FROM story_pairs p
           JOIN article_embeddings ea ON ea.article_id = p.article_a
           JOIN article_embeddings eb ON eb.article_id = p.article_b""")
    pairs = [(float(r["sim"]), r["same"]) for r in rows]
    table = score(pairs)
    same = sum(1 for _, s in pairs if s)
    best = max(table, key=lambda r: (r.f1, r.precision)) if same and len(pairs) > same else None
    return Calibration(current_threshold=settings.story_threshold,
                       strong_threshold=settings.story_strong, pairs=len(pairs), same=same,
                       different=len(pairs) - same, best=best, table=table)


@admin_router.get("/pairs/suggest", response_model=list[SuggestedPair])
async def suggest_pairs(limit: int = Query(20, ge=1, le=50), _: CurrentUser = Depends(admin_user)):
    """Pares perto do limite, de histórias diferentes, ainda sem rótulo: são
    os exemplos que mais ensinam."""
    rows = await get_pool().fetch(
        """WITH recent AS MATERIALIZED (
             SELECT e.article_id, e.embedding, sa.story_id, a.title, a.feed_id
             FROM article_embeddings e JOIN articles a ON a.id = e.article_id
             JOIN story_articles sa ON sa.article_id = e.article_id
             WHERE a.published_at > now() - interval '48 hours'
             ORDER BY a.published_at DESC LIMIT 1500)
           SELECT x.article_id AS a, y.article_id AS b, x.title AS title_a, y.title AS title_b,
                  fx.title AS feed_a, fy.title AS feed_b,
                  1 - (x.embedding <=> y.embedding) AS sim
           FROM recent x JOIN recent y ON x.article_id < y.article_id AND x.story_id <> y.story_id
                                       AND x.feed_id <> y.feed_id
           JOIN feeds fx ON fx.id = x.feed_id JOIN feeds fy ON fy.id = y.feed_id
           WHERE 1 - (x.embedding <=> y.embedding) BETWEEN $1 AND $2
             AND NOT EXISTS (SELECT 1 FROM story_pairs p
                             WHERE p.article_a = x.article_id AND p.article_b = y.article_id)
           ORDER BY abs(1 - (x.embedding <=> y.embedding) - $3) LIMIT $4""",
        settings.story_threshold - 0.10, settings.story_threshold + 0.05,
        settings.story_threshold, limit)
    return [SuggestedPair(article_a=r["a"], article_b=r["b"], title_a=r["title_a"],
                          title_b=r["title_b"], feed_a=r["feed_a"], feed_b=r["feed_b"],
                          similarity=round(float(r["sim"]), 3)) for r in rows]


@admin_router.post("/pairs", status_code=status.HTTP_204_NO_CONTENT)
async def label(body: PairIn, admin: CurrentUser = Depends(admin_user)):
    async with get_pool().acquire() as conn:
        await cluster.label_pair(conn, body.article_a, body.article_b, body.same, "label", admin.id)


@admin_router.post("/recluster", status_code=status.HTTP_202_ACCEPTED)
async def recluster(days: int = Query(3, ge=1, le=14), _: CurrentUser = Depends(admin_user)):
    """Refaz o agrupamento automático dos últimos N dias (depois de mudar o
    limite no .env e reiniciar o worker). O que foi juntado ou separado à
    mão fica como está. Quem faz é o worker de IA."""
    await (await get_redis()).set(RECLUSTER_KEY, days)
    return {"queued": True, "days": days, "requested_at": datetime.now().isoformat()}
