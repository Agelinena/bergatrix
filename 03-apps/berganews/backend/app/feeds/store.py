"""Gravar o que veio do feed (API, ao assinar, e worker, na coleta)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.config import settings
from app.core import html as h, lang
from app.feeds.parse import ParsedFeed

# A API avisa o worker por aqui: feed novo para coletar já, sem esperar a vez.
FETCH_NOW_KEY = "berganews:fetch:now"


async def upsert_feed(conn, url: str, parsed: ParsedFeed) -> int:
    return await conn.fetchval(
        """INSERT INTO feeds (url, title, site_url, description, language)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (url) DO UPDATE SET
               title = CASE WHEN feeds.title = '' THEN EXCLUDED.title ELSE feeds.title END,
               site_url = coalesce(feeds.site_url, EXCLUDED.site_url),
               description = coalesce(feeds.description, EXCLUDED.description),
               language = coalesce(EXCLUDED.language, feeds.language)
           RETURNING id""",
        url, parsed.title, parsed.site_url, parsed.description, parsed.language)


async def save_entries(conn, feed_id: int, parsed: ParsedFeed) -> int:
    """Insere os artigos novos e devolve quantos. Os que já existem ficam como
    estão (a manchete pode mudar no site, mas o que a pessoa leu fica)."""
    now = datetime.now(timezone.utc)
    rows = []
    for e in parsed.entries:
        published = e.published_at or now
        if published > now + timedelta(minutes=5):  # fuso errado no feed
            published = now
        text = h.to_text(e.content_html) if e.content_html else ""
        full = len(text) >= settings.extract_min_chars
        rows.append((
            feed_id, e.guid, e.url, e.title, e.author, e.summary, e.image_url,
            lang.detect(text or f"{e.title}. {e.summary or ''}", parsed.language),
            published,
            e.content_html if full else None,
            text if full else None,
            "ok" if full else None,
            now if full else None,
        ))
    if not rows:
        return 0
    inserted = await conn.fetch(
        """INSERT INTO articles (feed_id, guid, url, title, author, summary, image_url, language,
                                 published_at, content_html, content_text, content_status,
                                 extracted_at)
           SELECT * FROM unnest($1::bigint[], $2::text[], $3::text[], $4::text[], $5::text[],
                                $6::text[], $7::text[], $8::text[], $9::timestamptz[],
                                $10::text[], $11::text[], $12::text[], $13::timestamptz[])
           ON CONFLICT (feed_id, guid) DO NOTHING
           RETURNING id""",
        *[list(col) for col in zip(*rows)])
    return len(inserted)
