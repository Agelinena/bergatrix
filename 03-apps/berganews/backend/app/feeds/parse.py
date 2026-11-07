"""RSS/Atom → dados limpos (feedparser). Usado na coleta e ao assinar."""
from __future__ import annotations

import calendar
import re
import html as htmllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import urljoin

import feedparser

from app.core import html as h
from app.core.urls import canonical


@dataclass
class Entry:
    guid: str
    url: str
    title: str
    author: str | None
    summary: str | None          # texto puro, até 1000 caracteres
    content_html: str | None     # HTML limpo, se o feed trouxer o texto
    image_url: str | None
    published_at: datetime | None


@dataclass
class ParsedFeed:
    title: str
    site_url: str | None
    description: str | None
    language: str | None
    entries: list[Entry] = field(default_factory=list)


class NotAFeed(Exception):
    pass


def _date(entry) -> datetime | None:
    for key in ("published_parsed", "updated_parsed", "created_parsed"):
        value = entry.get(key)
        if value:
            try:
                return datetime.fromtimestamp(calendar.timegm(value), tz=timezone.utc)
            except (OverflowError, ValueError):
                continue
    return None


def _image(entry, content_html: str | None) -> str | None:
    for media in entry.get("media_content", []) + entry.get("media_thumbnail", []):
        url = media.get("url")
        if url and (media.get("medium") in (None, "image") or "image" in (media.get("type") or "")):
            return url
    for link in entry.get("links", []):
        if link.get("rel") == "enclosure" and (link.get("type") or "").startswith("image/"):
            return link.get("href")
    return h.first_image(content_html or "")


def _text(value: str | None, limit: int) -> str | None:
    if not value:
        return None
    text = h.to_text(h.sanitize(value)) if "<" in value else htmllib.unescape(value)
    text = " ".join(text.split())
    return text[:limit] or None


def _headline(text: str | None, limit: int = 160) -> str:
    """Primeira frase do texto, cortada numa palavra inteira."""
    if not text:
        return ""
    sentence = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0].strip()
    if len(sentence) <= limit:
        return sentence
    return sentence[:limit].rsplit(" ", 1)[0].rstrip(",;:") + "…"


def parse(body: bytes, url: str) -> ParsedFeed:
    data = feedparser.parse(body)
    feed = data.get("feed", {})
    if not data.get("version") and not data.get("entries"):
        raise NotAFeed()
    site = feed.get("link")
    parsed = ParsedFeed(
        title=_text(feed.get("title"), 200) or "",
        site_url=urljoin(url, site) if site else None,
        description=_text(feed.get("subtitle") or feed.get("description"), 500),
        language=feed.get("language"),
    )
    for e in data.get("entries", []):
        link = e.get("link") or ""
        link = canonical(urljoin(url, link)) if link else ""
        title = _text(e.get("title"), 500) or ""
        guid = (e.get("id") or link or title).strip()[:1000]
        if not guid or not (link or title):
            continue
        content = None
        if e.get("content"):
            content = max((c.get("value") or "" for c in e["content"]), key=len)
        summary_raw = e.get("summary") or ""
        # Muitos feeds mandam o texto inteiro no <description>.
        if not content and len(summary_raw) > 1500:
            content = summary_raw
        content_html = h.sanitize(content, link or url) if content else None
        if not title:
            # O RSS permite item sem <title> (o UOL manda a manchete só no
            # <description>): a manchete vira o começo do trecho.
            title = _headline(_text(summary_raw or content, 1000))
        parsed.entries.append(Entry(
            guid=guid,
            url=link or url,
            title=title or "(sem título)",
            author=_text(e.get("author"), 200),
            summary=_text(summary_raw or content, 1000),
            content_html=content_html or None,
            image_url=_image(e, content_html),
            published_at=_date(e),
        ))
    return parsed
