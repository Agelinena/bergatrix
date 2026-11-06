"""Assinaturas, pastas e OPML de cada pessoa: /api/subscriptions, /api/folders, /api/opml."""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field

from app.auth.dependencies import CurrentUser, current_user
from app.core import http
from app.core.db import get_pool
from app.core.redis import get_redis
from app.feeds import discovery, opml, store

logger = logging.getLogger("berganews.feeds")
router = APIRouter(prefix="/api", tags=["feeds"])

MAX_SUBSCRIPTIONS = 500


# ── Modelos ─────────────────────────────────────────────────────────

class Subscription(BaseModel):
    feed_id: int
    title: str
    feed_title: str
    url: str
    site_url: str | None
    language: str | None
    folder_id: int | None
    unread: int
    last_fetched_at: str | None
    error: str | None           # última falha da coleta, se houver


class SubscribeRequest(BaseModel):
    url: str = Field(min_length=4, max_length=2000)
    folder_id: int | None = None
    title: str | None = Field(None, max_length=200)


class SubscriptionPatch(BaseModel):
    title: str | None = Field(None, max_length=200)
    folder_id: int | None = None
    # Para tirar da pasta: folder_id null com clear_folder true.
    clear_folder: bool = False


class Folder(BaseModel):
    id: int
    name: str
    position: int
    unread: int


class FolderIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    position: int | None = None


class ImportResult(BaseModel):
    added: int
    already: int
    folders_created: int
    failed: list[str]


# ── Consultas ───────────────────────────────────────────────────────

_SUBS_SQL = """
SELECT s.feed_id, coalesce(nullif(s.title, ''), nullif(f.title, ''), f.url) AS title,
       f.title AS feed_title, f.url, f.site_url, f.language, s.folder_id,
       f.last_fetched_at, CASE WHEN f.error_count > 0 THEN f.last_error END AS error,
       (SELECT count(*) FROM articles a
         WHERE a.feed_id = s.feed_id AND a.published_at > now() - interval '30 days'
           AND NOT EXISTS (SELECT 1 FROM article_states st WHERE st.user_id = s.user_id
                           AND st.article_id = a.id AND st.read_at IS NOT NULL)) AS unread
FROM subscriptions s JOIN feeds f ON f.id = s.feed_id
WHERE s.user_id = $1 {extra}
ORDER BY lower(coalesce(nullif(s.title, ''), nullif(f.title, ''), f.url))
"""


def _sub(row) -> Subscription:
    return Subscription(
        feed_id=row["feed_id"], title=row["title"], feed_title=row["feed_title"], url=row["url"],
        site_url=row["site_url"], language=row["language"], folder_id=row["folder_id"],
        unread=row["unread"], error=row["error"],
        last_fetched_at=row["last_fetched_at"].isoformat() if row["last_fetched_at"] else None)


async def _own_folder(conn, user_id: str, folder_id: int | None) -> None:
    if folder_id is not None and not await conn.fetchval(
            "SELECT 1 FROM folders WHERE id = $1 AND user_id = $2", folder_id, user_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Pasta não encontrada")


# ── Assinaturas ─────────────────────────────────────────────────────

@router.get("/subscriptions", response_model=list[Subscription])
async def list_subscriptions(user: CurrentUser = Depends(current_user)):
    rows = await get_pool().fetch(_SUBS_SQL.format(extra=""), user.id)
    return [_sub(r) for r in rows]


@router.post("/subscriptions", response_model=Subscription, status_code=status.HTTP_201_CREATED)
async def subscribe(body: SubscribeRequest, user: CurrentUser = Depends(current_user)):
    """Assina pelo endereço do feed ou do site (o servidor acha o feed)."""
    pool = get_pool()
    await _own_folder(pool, user.id, body.folder_id)
    if await pool.fetchval("SELECT count(*) FROM subscriptions WHERE user_id = $1",
                           user.id) >= MAX_SUBSCRIPTIONS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="Limite de assinaturas atingido")
    existing = await pool.fetchval("SELECT id FROM feeds WHERE url = $1", body.url.strip())
    if existing is None:
        try:
            url, parsed = await discovery.discover(body.url)
        except http.FetchError as exc:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc))
        async with pool.acquire() as conn, conn.transaction():
            feed_id = await store.upsert_feed(conn, url, parsed)
            new = await store.save_entries(conn, feed_id, parsed)
        logger.info("[feeds] %s assinou %s (%d artigos novos)", user.id, url, new)
    else:
        feed_id = existing
    await pool.execute(
        """INSERT INTO subscriptions (user_id, feed_id, folder_id, title) VALUES ($1, $2, $3, $4)
           ON CONFLICT (user_id, feed_id) DO UPDATE SET folder_id = coalesce(EXCLUDED.folder_id,
               subscriptions.folder_id)""",
        user.id, feed_id, body.folder_id, (body.title or "").strip() or None)
    # Coleta já, para buscar o texto completo dos artigos que acabaram de chegar.
    await (await get_redis()).rpush(store.FETCH_NOW_KEY, feed_id)
    row = await pool.fetchrow(_SUBS_SQL.format(extra="AND s.feed_id = $2"), user.id, feed_id)
    return _sub(row)


@router.patch("/subscriptions/{feed_id}", response_model=Subscription)
async def patch_subscription(feed_id: int, body: SubscriptionPatch,
                             user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    await _own_folder(pool, user.id, body.folder_id)
    sets, args = [], [user.id, feed_id]
    if body.title is not None:
        args.append(body.title.strip() or None)
        sets.append(f"title = ${len(args)}")
    if body.folder_id is not None or body.clear_folder:
        args.append(body.folder_id)
        sets.append(f"folder_id = ${len(args)}")
    if sets:
        done = await pool.execute(
            f"UPDATE subscriptions SET {', '.join(sets)} WHERE user_id = $1 AND feed_id = $2", *args)
        if done.endswith(" 0"):
            raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Assinatura não encontrada")
    row = await pool.fetchrow(_SUBS_SQL.format(extra="AND s.feed_id = $2"), user.id, feed_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Assinatura não encontrada")
    return _sub(row)


@router.delete("/subscriptions/{feed_id}", status_code=status.HTTP_204_NO_CONTENT)
async def unsubscribe(feed_id: int, user: CurrentUser = Depends(current_user)):
    """Os artigos continuam na casa enquanto alguém assinar o feed (ou tiver
    salvo); a limpeza diária apaga feeds sem ninguém."""
    await get_pool().execute("DELETE FROM subscriptions WHERE user_id = $1 AND feed_id = $2",
                             user.id, feed_id)


@router.post("/subscriptions/{feed_id}/refresh", status_code=status.HTTP_202_ACCEPTED)
async def refresh_subscription(feed_id: int, user: CurrentUser = Depends(current_user)):
    if not await get_pool().fetchval(
            "SELECT 1 FROM subscriptions WHERE user_id = $1 AND feed_id = $2", user.id, feed_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Assinatura não encontrada")
    await (await get_redis()).rpush(store.FETCH_NOW_KEY, feed_id)
    return {"queued": True}


# ── Pastas ──────────────────────────────────────────────────────────

@router.get("/folders", response_model=list[Folder])
async def list_folders(user: CurrentUser = Depends(current_user)):
    rows = await get_pool().fetch(
        """SELECT f.id, f.name, f.position,
                  (SELECT count(*) FROM subscriptions s JOIN articles a ON a.feed_id = s.feed_id
                    WHERE s.user_id = f.user_id AND s.folder_id = f.id
                      AND a.published_at > now() - interval '30 days'
                      AND NOT EXISTS (SELECT 1 FROM article_states st WHERE st.user_id = f.user_id
                                      AND st.article_id = a.id AND st.read_at IS NOT NULL)) AS unread
           FROM folders f WHERE f.user_id = $1 ORDER BY f.position, lower(f.name)""", user.id)
    return [Folder(**dict(r)) for r in rows]


async def _create_folder(conn, user_id: str, name: str, position: int | None = None) -> int:
    if position is None:
        position = await conn.fetchval(
            "SELECT coalesce(max(position), -1) + 1 FROM folders WHERE user_id = $1", user_id)
    return await conn.fetchval(
        """INSERT INTO folders (user_id, name, position) VALUES ($1, $2, $3)
           ON CONFLICT (user_id, lower(name)) DO UPDATE SET name = folders.name RETURNING id""",
        user_id, name, position)


@router.post("/folders", response_model=Folder, status_code=status.HTTP_201_CREATED)
async def create_folder(body: FolderIn, user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    folder_id = await _create_folder(pool, user.id, body.name.strip(), body.position)
    row = await pool.fetchrow("SELECT id, name, position FROM folders WHERE id = $1", folder_id)
    return Folder(**dict(row), unread=0)


@router.patch("/folders/{folder_id}", status_code=status.HTTP_204_NO_CONTENT)
async def update_folder(folder_id: int, body: FolderIn, user: CurrentUser = Depends(current_user)):
    try:
        done = await get_pool().execute(
            """UPDATE folders SET name = $3, position = coalesce($4, position)
               WHERE id = $1 AND user_id = $2""",
            folder_id, user.id, body.name.strip(), body.position)
    except Exception as exc:  # asyncpg.UniqueViolationError
        if exc.__class__.__name__ == "UniqueViolationError":
            raise HTTPException(status.HTTP_409_CONFLICT, detail="Já existe uma pasta com esse nome")
        raise
    if done.endswith(" 0"):
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Pasta não encontrada")


@router.delete("/folders/{folder_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_folder(folder_id: int, user: CurrentUser = Depends(current_user)):
    """As assinaturas da pasta ficam, sem pasta."""
    await get_pool().execute("DELETE FROM folders WHERE id = $1 AND user_id = $2",
                             folder_id, user.id)


# ── OPML ────────────────────────────────────────────────────────────

@router.get("/opml")
async def export_opml(user: CurrentUser = Depends(current_user)):
    pool = get_pool()
    owner = await pool.fetchval("SELECT name FROM users WHERE id = $1", user.id) or "eu"
    rows = await pool.fetch(
        """SELECT fo.name AS folder, coalesce(nullif(s.title, ''), nullif(f.title, ''), f.url) AS title,
                  f.url, f.site_url
           FROM subscriptions s JOIN feeds f ON f.id = s.feed_id
           LEFT JOIN folders fo ON fo.id = s.folder_id
           WHERE s.user_id = $1 ORDER BY fo.position NULLS LAST, lower(fo.name), 2""", user.id)
    body = opml.build(owner, [(r["folder"], r["title"], r["url"], r["site_url"]) for r in rows])
    return Response(body, media_type="text/x-opml",
                    headers={"Content-Disposition": 'attachment; filename="berganews.opml"'})


@router.post("/opml", response_model=ImportResult)
async def import_opml(request: Request, user: CurrentUser = Depends(current_user)):
    """Corpo: o arquivo OPML. Os feeds são assinados sem baixar nada agora;
    o worker coleta cada um na sequência (um feed fora do ar não trava o
    import)."""
    chunks, size = [], 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > opml.MAX_OPML_BYTES:
            raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="Arquivo grande demais")
        chunks.append(chunk)
    body = b"".join(chunks)
    try:
        items = opml.parse(body)
    except opml.OpmlError as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc))
    pool = get_pool()
    current = await pool.fetchval("SELECT count(*) FROM subscriptions WHERE user_id = $1", user.id)
    added = already = folders_created = 0
    failed: list[str] = []
    folder_ids: dict[str, int] = {}
    redis = await get_redis()
    async with pool.acquire() as conn:
        for item in items:
            try:
                url = http.check_url(item.url)
            except http.FetchError:
                failed.append(item.url)
                continue
            if current + added >= MAX_SUBSCRIPTIONS:
                failed.append(url)
                continue
            folder_id = None
            if item.folder:
                key = item.folder.lower()
                if key not in folder_ids:
                    before = await conn.fetchval(
                        "SELECT id FROM folders WHERE user_id = $1 AND lower(name) = $2", user.id, key)
                    folder_ids[key] = before or await _create_folder(conn, user.id, item.folder[:80])
                    folders_created += before is None
                folder_id = folder_ids[key]
            feed_id = await conn.fetchval(
                """INSERT INTO feeds (url, title) VALUES ($1, $2)
                   ON CONFLICT (url) DO UPDATE SET url = EXCLUDED.url RETURNING id""",
                url, (item.title or "")[:200])
            inserted = await conn.fetchval(
                """INSERT INTO subscriptions (user_id, feed_id, folder_id, title)
                   VALUES ($1, $2, $3, NULL) ON CONFLICT DO NOTHING RETURNING 1""",
                user.id, feed_id, folder_id)
            if inserted:
                added += 1
                await redis.rpush(store.FETCH_NOW_KEY, feed_id)
            else:
                already += 1
    logger.info("[opml] %s importou %d feeds (%d já assinados)", user.id, added, already)
    return ImportResult(added=added, already=already, folders_created=folders_created, failed=failed)
