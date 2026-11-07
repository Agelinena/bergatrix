"""Gravar o que veio do feed (API, ao assinar, e worker, na coleta)."""
from __future__ import annotations

import math
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


def fix_future(published: datetime, now: datetime) -> datetime:
    """Data no futuro é quase sempre fuso errado no feed (o UOL manda a hora
    UTC com "-0300"): volta as horas inteiras que sobram. Mais de 15 h no
    futuro não é fuso; vira "agora"."""
    ahead = published - now
    if ahead <= timedelta(minutes=5):
        return published
    if ahead < timedelta(hours=15):
        return published - timedelta(hours=math.ceil(ahead.total_seconds() / 3600))
    return now


def publish_dates(entries, first_fetch: bool, now: datetime) -> list[datetime | None]:
    """Data de cada item; None = não guardar (mais velho que a retenção).

    Item sem data vira "visto agora", menos na primeira coleta do feed: aí
    ele é o acervo do site (o UOL manda dezenas de matérias de sempre sem
    data), e vai para depois do item datado mais antigo, em vez de encher o
    topo da aba Todas."""
    oldest_allowed = now - timedelta(days=settings.article_retention_days)
    dated = [e.published_at for e in entries if e.published_at]
    floor = min(dated) if dated else now - timedelta(days=1)
    out: list[datetime | None] = []
    for i, e in enumerate(entries):
        published = e.published_at
        if published is None:
            published = floor - timedelta(minutes=i + 1) if first_fetch else now - timedelta(seconds=i)
        published = fix_future(published, now)
        out.append(published if published >= oldest_allowed else None)
    return out


async def save_entries(conn, feed_id: int, parsed: ParsedFeed, first_fetch: bool = False) -> int:
    """Insere os artigos novos e devolve quantos. Os que já existem ficam como
    estão (a manchete pode mudar no site, mas o que a pessoa leu fica)."""
    now = datetime.now(timezone.utc)
    rows = []
    for e, published in zip(parsed.entries, publish_dates(parsed.entries, first_fetch, now)):
        if published is None:
            continue
        content = h.drop_leading_title(e.content_html, e.title) if e.content_html else None
        text = h.to_text(content) if content else ""
        # O texto que vem no feed fica de reserva: muitos (o G1, por exemplo)
        # mandam a matéria num bloco só, sem parágrafo, foto nem negrito. O
        # worker lê a página e só fica com o do feed se a página falhar.
        full = len(text) >= settings.extract_min_chars
        rows.append((
            feed_id, e.guid, e.url, e.title, e.author, e.summary, e.image_url,
            lang.detect(text or f"{e.title}. {e.summary or ''}", parsed.language),
            published,
            content if full else None,
            text if full else None,
            None,
            None,
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
