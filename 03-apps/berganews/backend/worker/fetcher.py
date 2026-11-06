"""Worker de coleta: feeds, texto completo dos artigos e limpeza diária.

Sem rota e sem internet direta: só a rede interna da stack, saindo pelo
proxy `egress` (smokescreen). Roda: python -m worker.fetcher
"""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import trafilatura

from app.config import settings
from app.core import db, html as h, http, lang
from app.core.redis import get_redis
from app.feeds import parse as feedparse, store

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO),
                    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("berganews.fetcher")

MAX_FEED_BYTES = 10 * 1024 * 1024
MAX_PAGE_BYTES = 5 * 1024 * 1024
CLEANUP_HOUR = 4          # hora local da limpeza diária


# ── Feeds ───────────────────────────────────────────────────────────

def _next_fetch(error_count: int) -> datetime:
    minutes = settings.fetch_interval_minutes
    if error_count:
        minutes = min(minutes * 2 ** error_count, settings.fetch_max_backoff_hours * 60)
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)


async def fetch_feed(pool, client, feed_id: int) -> None:
    feed = await pool.fetchrow("SELECT id, url, etag, last_modified, error_count FROM feeds WHERE id = $1",
                               feed_id)
    if feed is None:
        return
    headers = {"Accept": "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5"}
    if feed["etag"]:
        headers["If-None-Match"] = feed["etag"]
    if feed["last_modified"]:
        headers["If-Modified-Since"] = feed["last_modified"]
    try:
        r, body = await http.get(client, feed["url"], MAX_FEED_BYTES, headers=headers)
        if r.status_code == 304:
            await pool.execute(
                """UPDATE feeds SET last_fetched_at = now(), last_status = 304, error_count = 0,
                          last_error = NULL, next_fetch_at = $2 WHERE id = $1""",
                feed_id, _next_fetch(0))
            return
        if r.status_code != 200:
            raise http.FetchError(f"O site respondeu {r.status_code}")
        parsed = await asyncio.to_thread(feedparse.parse, body, str(r.url))
    except (http.FetchError, feedparse.NotAFeed) as exc:
        message = "O endereço não é mais um feed" if isinstance(exc, feedparse.NotAFeed) else str(exc)
        errors = feed["error_count"] + 1
        await pool.execute(
            """UPDATE feeds SET last_fetched_at = now(), last_error = $2, error_count = $3,
                      next_fetch_at = $4 WHERE id = $1""",
            feed_id, message[:300], errors, _next_fetch(errors))
        logger.info("[feed %d] falhou (%d seguidas): %s", feed_id, errors, message)
        return
    async with pool.acquire() as conn, conn.transaction():
        new = await store.save_entries(conn, feed_id, parsed)
        await conn.execute(
            """UPDATE feeds SET title = CASE WHEN title = '' THEN $2 ELSE title END,
                      site_url = coalesce(site_url, $3), description = coalesce(description, $4),
                      language = coalesce($5, language), etag = $6, last_modified = $7,
                      last_fetched_at = now(), last_status = 200, last_error = NULL,
                      error_count = 0, next_fetch_at = $8
               WHERE id = $1""",
            feed_id, parsed.title, parsed.site_url, parsed.description, parsed.language,
            r.headers.get("etag"), r.headers.get("last-modified"), _next_fetch(0))
    if new:
        logger.info("[feed %d] %d artigos novos", feed_id, new)


async def feeds_loop(pool) -> None:
    """Feeds na vez (com alguém assinando), em paralelo limitado; e os pedidos
    "coletar já" da API (assinatura nova, botão atualizar)."""
    redis = await get_redis()
    sem = asyncio.Semaphore(settings.fetch_concurrency)
    running: set[int] = set()

    async def one(client, feed_id: int):
        if feed_id in running:
            return
        running.add(feed_id)
        try:
            async with sem:
                await fetch_feed(pool, client, feed_id)
        except Exception:
            logger.exception("[feed %d] erro inesperado", feed_id)
        finally:
            running.discard(feed_id)

    tasks: set[asyncio.Task] = set()

    def start(client, feed_id: int):
        task = asyncio.create_task(one(client, feed_id))
        tasks.add(task)
        task.add_done_callback(tasks.discard)

    async with http.client() as client:
        last_scan = 0.0
        while True:
            popped = await redis.blpop(store.FETCH_NOW_KEY, timeout=30)
            if popped:
                start(client, int(popped[1]))
            if time.monotonic() - last_scan >= 60:
                last_scan = time.monotonic()
                due = await pool.fetch(
                    """SELECT f.id FROM feeds f
                       WHERE f.next_fetch_at <= now()
                         AND EXISTS (SELECT 1 FROM subscriptions s WHERE s.feed_id = f.id)
                       ORDER BY f.next_fetch_at LIMIT 200""")
                for row in due:
                    start(client, row["id"])


# ── Texto completo ──────────────────────────────────────────────────

def _extract(page: bytes, url: str) -> tuple[str, str]:
    """Página → (HTML limpo, texto). Vazio se o trafilatura não achar o artigo."""
    extracted = trafilatura.extract(
        page, url=url, output_format="html", include_images=True, include_links=True,
        include_formatting=True, include_tables=True, include_comments=False,
        favor_precision=True, deduplicate=True)
    if not extracted:
        return "", ""
    clean = h.sanitize(extracted, url)
    return clean, h.to_text(clean)


def _og_image(page: bytes, url: str) -> str | None:
    try:
        meta = trafilatura.extract_metadata(page, default_url=url)
    except Exception:
        return None
    image = getattr(meta, "image", None) if meta else None
    return image if image and image.startswith(("http://", "https://")) else None


async def extract_article(pool, client, row) -> None:
    status, error, content, text, image = "short", None, row["content_html"], None, None
    try:
        r, page = await http.get(client, row["url"], MAX_PAGE_BYTES,
                                 headers={"Accept": "text/html,application/xhtml+xml"})
        if r.status_code != 200:
            raise http.FetchError(f"O site respondeu {r.status_code}")
        if "html" not in (r.headers.get("content-type") or "html"):
            raise http.FetchError("A página não é HTML")
        found_html, found_text = await asyncio.to_thread(_extract, page, str(r.url))
        if not row["image_url"]:
            image = await asyncio.to_thread(_og_image, page, str(r.url))
        if len(found_text) >= settings.extract_min_chars:
            status, content, text = "ok", found_html, found_text
    except http.FetchError as exc:
        status, error = "error", str(exc)[:300]
    if text is None and content:
        text = h.to_text(content)
    detected = lang.detect(text or f"{row['title']}. {row['summary'] or ''}", row["feed_language"])
    await pool.execute(
        """UPDATE articles SET content_status = $2, content_error = $3, content_html = $4,
                  content_text = $5, image_url = coalesce(image_url, $6),
                  language = coalesce($7, language), extracted_at = now()
           WHERE id = $1""",
        row["id"], status, error, content, text, image, detected)


async def extract_loop(pool) -> None:
    """Artigos novos sem texto completo: busca a página e extrai (sem anúncio,
    sem menu). Paywall ou extração ruim → 'short' (o app mostra o trecho e
    leva ao site)."""
    sem = asyncio.Semaphore(settings.fetch_concurrency)

    async def one(client, row):
        async with sem:
            try:
                await extract_article(pool, client, row)
            except Exception:
                logger.exception("[artigo %d] extração falhou", row["id"])
                await pool.execute(
                    "UPDATE articles SET content_status = 'error', content_error = 'erro interno', "
                    "extracted_at = now() WHERE id = $1", row["id"])

    async with http.client(timeout=25.0) as client:
        while True:
            rows = await pool.fetch(
                """SELECT a.id, a.url, a.title, a.summary, a.image_url, a.content_html,
                          f.language AS feed_language
                   FROM articles a JOIN feeds f ON f.id = a.feed_id
                   WHERE a.content_status IS NULL AND a.fetched_at > now() - $1::interval
                   ORDER BY a.published_at DESC LIMIT $2""",
                timedelta(hours=settings.extract_max_age_hours), settings.extract_batch)
            if rows:
                await asyncio.gather(*(one(client, r) for r in rows))
                logger.info("[extração] %d artigos processados", len(rows))
            else:
                await asyncio.sleep(30)


# ── Limpeza diária ──────────────────────────────────────────────────

def _clean_images() -> int:
    root = Path(settings.image_cache_dir)
    if not root.is_dir():
        return 0
    limit = time.time() - settings.image_cache_days * 86400
    removed = 0
    for file in root.rglob("*"):
        if file.is_file() and file.stat().st_atime < limit and file.stat().st_mtime < limit:
            file.unlink(missing_ok=True)
            removed += 1
    return removed


async def cleanup(pool) -> None:
    # Artigos antigos que ninguém salvou.
    articles = await pool.execute(
        """DELETE FROM articles a WHERE a.published_at < now() - $1::interval
             AND NOT EXISTS (SELECT 1 FROM article_states st
                             WHERE st.article_id = a.id AND st.saved_at IS NOT NULL)""",
        timedelta(days=settings.article_retention_days))
    # Velhos demais para buscar o texto: ficam com o trecho do RSS.
    await pool.execute(
        """UPDATE articles SET content_status = 'short', extracted_at = now()
           WHERE content_status IS NULL AND fetched_at <= now() - $1::interval""",
        timedelta(hours=settings.extract_max_age_hours))
    # Feeds sem assinatura e sem artigo salvo.
    feeds = await pool.execute(
        """DELETE FROM feeds f WHERE NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.feed_id = f.id)
             AND NOT EXISTS (SELECT 1 FROM articles a JOIN article_states st ON st.article_id = a.id
                             WHERE a.feed_id = f.id AND st.saved_at IS NOT NULL)""")
    # Histórias que ficaram sem artigo (os artigos saíram pela retenção).
    await pool.execute(
        "DELETE FROM stories s WHERE NOT EXISTS (SELECT 1 FROM story_articles sa WHERE sa.story_id = s.id)")
    tokens = await pool.execute(
        "DELETE FROM refresh_tokens WHERE expires_at < now() - interval '7 days'")
    images = await asyncio.to_thread(_clean_images)
    logger.info("[limpeza] artigos: %s, feeds: %s, sessões: %s, imagens: %d",
                articles.split()[-1], feeds.split()[-1], tokens.split()[-1], images)


async def cleanup_loop(pool) -> None:
    last_day = None
    while True:
        now = datetime.now().astimezone()
        if now.hour == CLEANUP_HOUR and now.date() != last_day:
            last_day = now.date()
            try:
                await cleanup(pool)
            except Exception:
                logger.exception("[limpeza] falhou")
        await asyncio.sleep(300)


async def main() -> None:
    pool = await db.create_pool(min_size=2, max_size=settings.fetch_concurrency * 2 + 2)
    logger.info("Coleta pronta: a cada %d min, %d em paralelo, saída por %s",
                settings.fetch_interval_minutes, settings.fetch_concurrency, settings.egress_proxy)
    await asyncio.gather(feeds_loop(pool), extract_loop(pool), cleanup_loop(pool))


if __name__ == "__main__":
    asyncio.run(main())
