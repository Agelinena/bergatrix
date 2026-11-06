"""Artigos: lista (abas), leitor, lido/salvo, busca e tradução. /api/articles."""
from __future__ import annotations

import base64
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.config import settings
from app.core import html as h
from app.core.db import get_pool
from app.core.redis import get_redis
from app.articles import translation
from app.prefs.routes import load as load_prefs

router = APIRouter(prefix="/api/articles", tags=["articles"])

# Só conta como "não lido" o que saiu nos últimos N dias (o resto é arquivo).
UNREAD_DAYS = 30


class ArticleItem(BaseModel):
    id: int
    feed_id: int
    feed_title: str
    title: str
    summary: str | None
    image: str | None
    url: str
    author: str | None
    language: str | None
    published_at: str
    read: bool
    saved: bool
    full_text: bool
    # História (mesma notícia em outros veículos): o app mostra "em N veículos".
    story_id: int | None = None
    story_sources: int = 0


class ArticlePage(BaseModel):
    items: list[ArticleItem]
    next_cursor: str | None


class Article(ArticleItem):
    content_html: str | None
    # ok = texto completo; short = só o trecho (paywall): o app oferece o site;
    # error/None = ainda não extraído ou falhou.
    content_status: str | None
    translate_to: str | None          # idioma do botão "Traduzir", se fizer sentido
    translations: list[str]           # idiomas já traduzidos


class StateIn(BaseModel):
    read: bool | None = None
    saved: bool | None = None


class MarkReadIn(BaseModel):
    feed_id: int | None = None
    folder_id: int | None = None
    ids: list[int] | None = Field(None, max_length=500)
    # Só o que foi publicado até este instante (o que chegou depois continua não lido).
    before: datetime | None = None


class Translation(BaseModel):
    lang: str
    title: str
    content_html: str
    model: str


class TranslationStatus(BaseModel):
    state: str          # queued | running | error
    done: int = 0
    total: int = 0
    error: str | None = None


# ── Cursor ──────────────────────────────────────────────────────────

def _cursor(published: datetime, article_id: int) -> str:
    raw = f"{published.isoformat()}|{article_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _parse_cursor(cursor: str) -> tuple[datetime, int]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        when, article_id = raw.split("|")
        return datetime.fromisoformat(when), int(article_id)
    except (ValueError, UnicodeDecodeError):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Cursor inválido")


# ── Consultas ───────────────────────────────────────────────────────

_SELECT = """
SELECT a.id, a.feed_id, coalesce(nullif(s.title, ''), nullif(f.title, ''), f.url) AS feed_title,
       a.title, a.summary, a.image_url, a.url, a.author, a.language, a.published_at,
       st.read_at IS NOT NULL AS read, st.saved_at IS NOT NULL AS saved,
       a.content_status = 'ok' AS full_text, sx.story_id, coalesce(sy.source_count, 0) AS story_sources
       {extra_cols}
FROM articles a
JOIN feeds f ON f.id = a.feed_id
LEFT JOIN subscriptions s ON s.feed_id = a.feed_id AND s.user_id = $1
LEFT JOIN article_states st ON st.article_id = a.id AND st.user_id = $1
LEFT JOIN story_articles sx ON sx.article_id = a.id
LEFT JOIN stories sy ON sy.id = sx.story_id
"""

# Também se vê o artigo de um veículo que a pessoa não assina quando ele está
# numa história com algum que ela assina ("como cada veículo contou").
VISIBLE = """(s.user_id IS NOT NULL OR st.saved_at IS NOT NULL OR EXISTS (
    SELECT 1 FROM story_articles y JOIN articles ya ON ya.id = y.article_id
    JOIN subscriptions ys ON ys.feed_id = ya.feed_id AND ys.user_id = $1
    WHERE y.story_id = sx.story_id))"""


def _item(row) -> dict:
    image = row["image_url"]
    return dict(
        id=row["id"], feed_id=row["feed_id"], feed_title=row["feed_title"], title=row["title"],
        summary=(row["summary"] or "")[:320] or None,
        image=h.image_link(image) if image and image.startswith(("http://", "https://")) else None,
        url=row["url"], author=row["author"], language=row["language"],
        published_at=row["published_at"].isoformat(), read=row["read"], saved=row["saved"],
        full_text=bool(row["full_text"]), story_id=row["story_id"],
        story_sources=row["story_sources"])


@router.get("", response_model=ArticlePage)
async def list_articles(
    view: str = Query("all", pattern="^(all|unread|saved)$"),
    feed_id: int | None = None,
    folder_id: int | None = None,
    q: str | None = Query(None, max_length=200),
    cursor: str | None = Query(None, max_length=200),
    limit: int = Query(40, ge=1, le=100),
    user: CurrentUser = Depends(current_user),
):
    """Uma consulta serve todas as abas: Todas (sem filtro), Por veículo
    (feed_id), Por pasta (folder_id), Salvos (view=saved) e a busca (q)."""
    where, args = [], [user.id]
    if view == "saved":
        where.append("st.saved_at IS NOT NULL")
    else:
        where.append("s.user_id IS NOT NULL")
    if view == "unread":
        where.append(f"st.read_at IS NULL AND a.published_at > now() - interval '{UNREAD_DAYS} days'")
    if feed_id is not None:
        args.append(feed_id)
        where.append(f"a.feed_id = ${len(args)}")
    if folder_id is not None:
        args.append(folder_id)
        where.append(f"s.folder_id = ${len(args)}")
    if q and q.strip():
        args.append(q.strip())
        n = len(args)
        where.append(f"a.search @@ (websearch_to_tsquery('portuguese', f_unaccent(${n})) || "
                     f"websearch_to_tsquery('english', f_unaccent(${n})))")
    # Salvos seguem a ordem de quando foram salvos; o resto, a de publicação.
    key = "st.saved_at" if view == "saved" else "a.published_at"
    if cursor:
        when, last_id = _parse_cursor(cursor)
        args += [when, last_id]
        where.append(f"({key}, a.id) < (${len(args) - 1}, ${len(args)})")
    args.append(limit + 1)
    sql = _SELECT.format(extra_cols=", st.saved_at") + " WHERE " + " AND ".join(where) + \
        f" ORDER BY {key} DESC, a.id DESC LIMIT ${len(args)}"
    rows = await get_pool().fetch(sql, *args)
    more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = None
    if more and rows:
        last = rows[-1]
        next_cursor = _cursor(last["saved_at"] if view == "saved" else last["published_at"], last["id"])
    return ArticlePage(items=[ArticleItem(**_item(r)) for r in rows], next_cursor=next_cursor)


async def _get_visible(pool, user_id: str, article_id: int, extra_cols: str = ""):
    """O artigo, se a pessoa assina o feed ou salvou."""
    row = await pool.fetchrow(
        _SELECT.format(extra_cols=extra_cols) +
        f" WHERE a.id = $2 AND {VISIBLE}",
        user_id, article_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Artigo não encontrado")
    return row


def translate_target(article_lang: str | None, reading_lang: str) -> str | None:
    """Artigo em outro idioma → o de leitura; no de leitura → o outro da lista.
    Idioma desconhecido → o de leitura (melhor oferecer do que esconder)."""
    langs = settings.translate_langs
    if not article_lang:
        return reading_lang
    if article_lang != reading_lang:
        return reading_lang
    others = [x for x in langs if x != reading_lang]
    return others[0] if others else None


@router.get("/{article_id}", response_model=Article)
async def get_article(article_id: int, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    row = await _get_visible(pool, user.id, article_id,
                             ", a.content_html, a.content_status")
    prefs = await load_prefs(pool, user.id)
    langs = [r["lang"] for r in await pool.fetch(
        "SELECT lang FROM article_translations WHERE article_id = $1", article_id)]
    if prefs.mark_read_on_open and not row["read"]:
        await _set_state(pool, user.id, article_id, read=True)
    item = _item(row)
    item["read"] = item["read"] or prefs.mark_read_on_open
    return Article(**item,
                   content_html=h.proxy_images(row["content_html"]) if row["content_html"] else None,
                   content_status=row["content_status"],
                   translate_to=translate_target(row["language"], prefs.language),
                   translations=langs)


async def _set_state(pool, user_id: str, article_id: int, read: bool | None = None,
                     saved: bool | None = None) -> None:
    await pool.execute(
        """INSERT INTO article_states (user_id, article_id, read_at, saved_at)
           VALUES ($1, $2, CASE WHEN $3 THEN now() END, CASE WHEN $4 THEN now() END)
           ON CONFLICT (user_id, article_id) DO UPDATE SET
             read_at = CASE WHEN $3 IS NULL THEN article_states.read_at
                            WHEN $3 THEN coalesce(article_states.read_at, now()) END,
             saved_at = CASE WHEN $4 IS NULL THEN article_states.saved_at
                             WHEN $4 THEN coalesce(article_states.saved_at, now()) END""",
        user_id, article_id, read, saved)


@router.post("/{article_id}/state", status_code=status.HTTP_204_NO_CONTENT)
async def set_state(article_id: int, body: StateIn, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    await _get_visible(pool, user.id, article_id)
    await _set_state(pool, user.id, article_id, body.read, body.saved)


@router.post("/read", status_code=status.HTTP_200_OK)
async def mark_read(body: MarkReadIn, user: CurrentUser = Depends(current_user)):
    """Marcar como lido: uma lista de ids, um veículo, uma pasta, ou tudo."""
    where, args = ["s.user_id = $1", f"a.published_at > now() - interval '{UNREAD_DAYS} days'"], [user.id]
    if body.ids:
        args.append(body.ids)
        where.append(f"a.id = ANY(${len(args)}::bigint[])")
    if body.feed_id is not None:
        args.append(body.feed_id)
        where.append(f"a.feed_id = ${len(args)}")
    if body.folder_id is not None:
        args.append(body.folder_id)
        where.append(f"s.folder_id = ${len(args)}")
    if body.before is not None:
        args.append(body.before)
        where.append(f"a.published_at <= ${len(args)}")
    result = await get_pool().execute(
        f"""INSERT INTO article_states (user_id, article_id, read_at)
            SELECT $1, a.id, now() FROM articles a
            JOIN subscriptions s ON s.feed_id = a.feed_id
            WHERE {' AND '.join(where)}
            ON CONFLICT (user_id, article_id) DO UPDATE
              SET read_at = coalesce(article_states.read_at, now())""", *args)
    return {"marked": int(result.split()[-1])}


# ── Tradução ────────────────────────────────────────────────────────

def _check_lang(lang: str) -> None:
    if lang not in settings.translate_langs:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail=f"Idiomas aceitos: {', '.join(settings.translate_langs)}")


@router.get("/{article_id}/translation/{lang}",
            responses={202: {"model": TranslationStatus}}, response_model=Translation)
async def get_translation(article_id: int, lang: str, user: CurrentUser = Depends(current_user)):
    """200 com a tradução; 202 com o progresso; 404 se ninguém pediu."""
    _check_lang(lang)
    pool = get_pool()
    await _get_visible(pool, user.id, article_id)
    row = await pool.fetchrow(
        "SELECT title, html, model FROM article_translations WHERE article_id = $1 AND lang = $2",
        article_id, lang)
    if row:
        return Translation(lang=lang, title=row["title"], content_html=h.proxy_images(row["html"]),
                           model=row["model"])
    current = await translation.get_status(await get_redis(), article_id, lang)
    if current is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Tradução não pedida")
    from fastapi.responses import JSONResponse
    return JSONResponse(TranslationStatus(**current).model_dump(), status_code=202)


@router.post("/{article_id}/translation/{lang}", status_code=status.HTTP_202_ACCEPTED,
             response_model=TranslationStatus)
async def request_translation(article_id: int, lang: str,
                              user: CurrentUser = Depends(current_user)):
    """Pede a tradução ao modelo local. Fica pronta em segundos a poucos
    minutos, conforme o tamanho e o que mais estiver usando a GPU."""
    _check_lang(lang)
    pool = get_pool()
    row = await _get_visible(pool, user.id, article_id, ", a.content_html, a.content_status")
    if row["language"] == lang:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="O artigo já está nesse idioma")
    if not row["content_html"] and not row["summary"]:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="O artigo ainda não tem texto para traduzir")
    redis = await get_redis()
    current = await translation.get_status(redis, article_id, lang)
    if current and current.get("state") == "error":
        await translation.clear_status(redis, article_id, lang)
    return TranslationStatus(**await translation.enqueue(redis, article_id, lang))
