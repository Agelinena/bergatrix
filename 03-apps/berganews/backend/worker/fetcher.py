"""Worker de coleta: feeds, texto completo dos artigos e limpeza diária.

Sem rota e sem internet direta: só a rede interna da stack, saindo pelo
proxy `egress` (smokescreen). Roda: python -m worker.fetcher
"""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone

import trafilatura

from app.config import settings
from app.core import db, html as h, http, lang, videos
from app.core.redis import get_redis
from app.feeds import parse as feedparse, store
from app.images import cache as image_cache
from app.articles.keep import KEEP_IMAGES_KEY

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO),
                    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("berganews.fetcher")

MAX_FEED_BYTES = 10 * 1024 * 1024
MAX_PAGE_BYTES = 5 * 1024 * 1024
CLEANUP_HOUR = 4          # hora local da limpeza diária
# Sobe quando a extração melhora: as matérias antigas são refeitas.
EXTRACT_VERSION = 4


# ── Feeds ───────────────────────────────────────────────────────────

def _next_fetch(error_count: int) -> datetime:
    minutes = settings.fetch_interval_minutes
    if error_count:
        minutes = min(minutes * 2 ** error_count, settings.fetch_max_backoff_hours * 60)
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)


async def fetch_feed(pool, client, feed_id: int) -> None:
    feed = await pool.fetchrow("SELECT id, url, etag, last_modified, error_count, last_fetched_at FROM feeds WHERE id = $1",
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
        new = await store.save_entries(conn, feed_id, parsed,
                                       first_fetch=feed["last_fetched_at"] is None)
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
    """Página → (HTML limpo, texto). Vazio se o trafilatura não achar o artigo.
    Fotos do corpo, vídeos (como cartões) e a formatação ficam."""
    # Páginas AMP (o G1) usam <amp-img>, que o trafilatura não vê como foto:
    # sobrava só a legenda. Troca nos bytes (vale para qualquer codificação).
    page = page.replace(b"<amp-img", b"<img").replace(b"</amp-img>", b"")
    extracted = trafilatura.extract(
        page, url=url, output_format="html", include_images=True, include_links=True,
        include_formatting=True, include_tables=True, include_comments=False,
        favor_precision=True, deduplicate=True)
    if not extracted:
        return "", ""
    clean = h.sanitize(h.trafilatura_images(extracted), url)
    clean = videos.add_embeds(videos.globo_thumbs_to_cards(clean), page)
    return clean, h.to_text(clean)


def _og_image(page: bytes, url: str) -> str | None:
    try:
        meta = trafilatura.extract_metadata(page, default_url=url)
    except Exception:
        return None
    image = getattr(meta, "image", None) if meta else None
    return image if image and image.startswith(("http://", "https://")) else None


_RANK = {"ok": 3, "short": 2, "error": 1, None: 0}


def _choose(row, page_html: str, page_text: str, video, feed_html: str | None):
    """(status, html) a partir do que a página e o feed deram.

    - texto da página com o tamanho de uma matéria → ok;
    - a página é um vídeo → ok, com o cartão do vídeo e o que houver de texto;
    - texto da página curto, mas mais que o trecho do RSS → short (pode ser
      só o começo, por paywall: fica guardado e o app oferece o site);
    - senão, o texto do feed (se for a matéria inteira, ok)."""
    summary_len = len(row["summary"] or "")
    if len(page_text) >= settings.extract_min_chars:
        return "ok", page_html
    if video:
        url, thumb, title = video
        body = page_html or (f"<p>{h.escape(row['summary'])}</p>" if row["summary"] else "")
        return "ok", videos.card(url, thumb, title or row["title"]) + body
    if page_text and len(page_text) > summary_len + 40:
        return "short", page_html
    if feed_html:
        feed_text = h.to_text(feed_html)
        return ("ok" if len(feed_text) >= settings.extract_min_chars else "short"), feed_html
    return "short", page_html or None


async def extract_article(pool, client, row) -> None:
    """Busca a página e guarda o texto. Na reextração (versão antiga do
    extrator), só troca o que já estava guardado se o novo não for pior."""
    reextract = row["content_status"] is not None
    feed_html = None if reextract else row["content_html"]
    status, error, content, image = "short", None, None, None
    try:
        r, page = await http.get(client, row["url"], MAX_PAGE_BYTES,
                                 headers={"Accept": "text/html,application/xhtml+xml"})
        if r.status_code != 200:
            raise http.FetchError(f"O site respondeu {r.status_code}")
        if "html" not in (r.headers.get("content-type") or "html"):
            raise http.FetchError("A página não é HTML")
        final = str(r.url)
        found_html, _ = await asyncio.to_thread(_extract, page, final)
        found_html = h.drop_leading_title(found_html, row["title"])
        found_text = h.to_text(found_html)
        video = videos.page_video(page, final) if len(found_text) < settings.extract_min_chars else None
        if not row["image_url"]:
            image = await asyncio.to_thread(_og_image, page, final)
        status, content = _choose(row, found_html, found_text, video, feed_html)
    except http.FetchError as exc:
        status, error = "error", str(exc)[:300]
        if feed_html:
            status, content = _choose(row, "", "", None, feed_html)
    text = h.to_text(content) if content else None

    if reextract and (_RANK[status] < _RANK[row["content_status"]] or
                      status == row["content_status"] and
                      len(text or "") < 0.7 * (row["old_len"] or 0)):
        # Ficou pior (o site mudou, saiu do ar, paywall novo): mantém o antigo.
        await pool.execute(
            "UPDATE articles SET extract_version = $2, image_url = coalesce(image_url, $3) WHERE id = $1",
            row["id"], EXTRACT_VERSION, image)
        return
    detected = lang.detect(text or f"{row['title']}. {row['summary'] or ''}", row["feed_language"])
    async with pool.acquire() as conn, conn.transaction():
        await conn.execute(
            """UPDATE articles SET content_status = $2, content_error = $3, content_html = $4,
                      content_text = $5, image_url = coalesce(image_url, $6),
                      language = coalesce($7, language), extracted_at = now(),
                      extract_version = $8
               WHERE id = $1""",
            row["id"], status, error, content, text, image, detected, EXTRACT_VERSION)
        if reextract:
            # O texto mudou: as traduções antigas não batem mais com ele.
            await conn.execute("DELETE FROM article_translations WHERE article_id = $1", row["id"])


_SELECT = """SELECT a.id, a.url, a.title, a.summary, a.image_url, a.content_html,
                    a.content_status, length(coalesce(a.content_text, '')) AS old_len,
                    f.language AS feed_language
             FROM articles a JOIN feeds f ON f.id = a.feed_id"""


async def extract_loop(pool) -> None:
    """Primeiro as matérias novas; nos intervalos, refaz as que foram
    extraídas por uma versão antiga do extrator (até a retenção), em lotes
    pequenos, da mais recente para a mais antiga."""
    sem = asyncio.Semaphore(settings.fetch_concurrency)

    async def one(client, row):
        async with sem:
            try:
                await extract_article(pool, client, row)
            except Exception:
                logger.exception("[artigo %d] extração falhou", row["id"])
                await pool.execute(
                    "UPDATE articles SET content_status = coalesce(content_status, 'error'), "
                    "content_error = coalesce(content_error, 'erro interno'), extracted_at = now(), "
                    "extract_version = $2 WHERE id = $1", row["id"], EXTRACT_VERSION)

    async with http.client(timeout=25.0) as client:
        while True:
            rows = await pool.fetch(
                _SELECT + """ WHERE a.content_status IS NULL AND a.fetched_at > now() - $1::interval
                              ORDER BY a.published_at DESC LIMIT $2""",
                timedelta(hours=settings.extract_max_age_hours), settings.extract_batch)
            if rows:
                await asyncio.gather(*(one(client, r) for r in rows))
                logger.info("[extração] %d artigos novos", len(rows))
                continue
            old = await pool.fetch(
                _SELECT + """ WHERE a.content_status IS NOT NULL AND a.extract_version < $1
                                AND a.published_at > now() - $2::interval
                              ORDER BY a.published_at DESC LIMIT $3""",
                EXTRACT_VERSION, timedelta(days=settings.article_retention_days),
                settings.reextract_batch)
            if old:
                await asyncio.gather(*(one(client, r) for r in old))
                logger.info("[extração] %d artigos antigos refeitos (versão %d)", len(old), EXTRACT_VERSION)
                await asyncio.sleep(2)
            else:
                await asyncio.sleep(30)


# ── Imagens das matérias salvas ─────────────────────────────────────

async def _article_images(pool, article_id: int) -> list[str]:
    row = await pool.fetchrow("SELECT image_url, content_html FROM articles WHERE id = $1", article_id)
    if row is None:
        return []
    urls = image_cache.urls_in(row["content_html"])
    if row["image_url"]:
        urls.insert(0, row["image_url"])
    return list(dict.fromkeys(urls))


async def keep_loop(pool) -> None:
    """Matéria salva: baixa já as imagens dela para o servidor, para não
    sumirem se o site apagar (a limpeza nunca apaga imagem de matéria salva)."""
    redis = await get_redis()
    async with http.client(timeout=20.0) as client:
        while True:
            popped = await redis.blpop(KEEP_IMAGES_KEY, timeout=60)
            if not popped:
                continue
            urls = await _article_images(pool, int(popped[1]))
            kept = 0
            for url in urls[:40]:
                kept += await image_cache.keep(url, client)
            logger.info("[salva] artigo %s: %d de %d imagens guardadas", popped[1], kept, len(urls))


# ── Limpeza diária ──────────────────────────────────────────────────

async def _images_in_use(pool) -> set[str]:
    """Hash de toda imagem que uma matéria guardada (ou a tradução dela) usa."""
    in_use: set[str] = set()
    async with pool.acquire() as conn, conn.transaction():
        async for row in conn.cursor(
                """SELECT a.image_url, a.content_html,
                          (SELECT string_agg(t.html, '') FROM article_translations t
                            WHERE t.article_id = a.id) AS translated
                   FROM articles a"""):
            if row["image_url"]:
                in_use.add(image_cache.digest(row["image_url"]))
            for url in image_cache.urls_in(row["content_html"]) + image_cache.urls_in(row["translated"]):
                in_use.add(image_cache.digest(url))
    return in_use


async def cleanup(pool) -> None:
    # Matérias com mais de ARTICLE_RETENTION_DAYS (5 meses) que ninguém salvou.
    articles = await pool.execute(
        """DELETE FROM articles a WHERE a.published_at < now() - $1::interval
             AND NOT EXISTS (SELECT 1 FROM article_states st
                             WHERE st.article_id = a.id AND st.saved_at IS NOT NULL)""",
        timedelta(days=settings.article_retention_days))
    # Velhos demais para buscar a página: ficam com o que veio no feed.
    await pool.execute(
        """UPDATE articles SET extracted_at = now(), extract_version = $3,
                  content_status = CASE WHEN length(coalesce(content_text, '')) >= $2
                                        THEN 'ok' ELSE 'short' END
           WHERE content_status IS NULL AND fetched_at <= now() - $1::interval""",
        timedelta(hours=settings.extract_max_age_hours), settings.extract_min_chars, EXTRACT_VERSION)
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
    # Imagens que nenhuma matéria guardada usa mais (as das salvas ficam).
    in_use = await _images_in_use(pool)
    images = await asyncio.to_thread(image_cache.prune, in_use)
    logger.info("[limpeza] artigos: %s, feeds: %s, sessões: %s, imagens: %d (em uso: %d)",
                articles.split()[-1], feeds.split()[-1], tokens.split()[-1], images, len(in_use))


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
    pool = await db.create_pool(min_size=2, max_size=settings.fetch_concurrency * 2 + 3)
    logger.info("Coleta pronta: a cada %d min, %d em paralelo, saída por %s, extrator v%d",
                settings.fetch_interval_minutes, settings.fetch_concurrency, settings.egress_proxy,
                EXTRACT_VERSION)
    await asyncio.gather(feeds_loop(pool), extract_loop(pool), keep_loop(pool), cleanup_loop(pool))


if __name__ == "__main__":
    asyncio.run(main())
