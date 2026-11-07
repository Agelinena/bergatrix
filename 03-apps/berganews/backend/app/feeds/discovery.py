"""Endereço colado pela pessoa → endereço do feed.

Pode ser o próprio feed ou a página do site: aí procura o <link
rel="alternate"> da página e, sem ele, os caminhos de costume (/feed, /rss).
Tudo pelo proxy de saída.
"""
from __future__ import annotations

from urllib.parse import urljoin, urlsplit

import httpx
import lxml.html

from app.core import http
from app.feeds.parse import NotAFeed, ParsedFeed, parse

MAX_FEED_BYTES = 10 * 1024 * 1024
_TYPES = ("application/rss+xml", "application/atom+xml", "application/feed+json",
          "application/rss", "text/xml", "application/xml")
_GUESSES = ("/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml")


# Portais que não anunciam o feed na página e cujo endereço não dá para
# adivinhar. Chave: o domínio sem "www.".
KNOWN = {
    "folha.uol.com.br": ["https://feeds.folha.uol.com.br/emcimadahora/rss091.xml"],
    "estadao.com.br": ["https://www.estadao.com.br/arc/outboundfeeds/feeds/rss/sections/ultimas/"],
    "agenciabrasil.ebc.com.br": ["https://agenciabrasil.ebc.com.br/rss/ultimasnoticias/feed.xml"],
    "senado.leg.br": ["https://www12.senado.leg.br/noticias/feed/todasnoticias/RSS"],
    "www12.senado.leg.br": ["https://www12.senado.leg.br/noticias/feed/todasnoticias/RSS"],
}


def guesses(url: str) -> list[str]:
    """Endereços de costume, do mais provável ao menos: os conhecidos do
    portal, os da seção aberta (bbc.com/portuguese → /portuguese/index.xml),
    os da raiz e o padrão da Globo (g1.globo.com → /rss/g1/)."""
    parts = urlsplit(url)
    host = parts.netloc.lower()
    root = f"{parts.scheme}://{parts.netloc}"
    found = list(KNOWN.get(host.removeprefix("www."), []))
    section = parts.path.rstrip("/")
    if section:
        found += [root + section + suffix for suffix in ("/index.xml", "/rss.xml", "/feed", "/rss")]
    found += [root + path for path in _GUESSES]
    label = host.removeprefix("www.").split(".")[0]
    found += [f"{root}/rss/{label}/"]
    return list(dict.fromkeys(found))


def feed_links(page: bytes, base_url: str) -> list[str]:
    try:
        doc = lxml.html.fromstring(page)
    except (ValueError, lxml.etree.ParserError):
        return []
    found = []
    for link in doc.iter("link"):
        rel = (link.get("rel") or "").lower().split()
        kind = (link.get("type") or "").lower()
        href = link.get("href")
        if "alternate" in rel and href and kind in _TYPES:
            url = urljoin(base_url, href)
            if url not in found:
                found.append(url)
    return found


async def _try(client: httpx.AsyncClient, url: str) -> tuple[str, ParsedFeed, bytes] | None:
    try:
        r, body = await http.get(client, url, MAX_FEED_BYTES)
    except http.FetchError:
        return None
    if r.status_code != 200:
        return None
    try:
        return str(r.url), parse(body, str(r.url)), body
    except NotAFeed:
        return None


async def discover(url: str) -> tuple[str, ParsedFeed]:
    """Devolve (endereço do feed, feed lido). FetchError com a explicação se
    não houver feed."""
    url = http.check_url(url)
    async with http.client() as client:
        r, body = await http.get(client, url, MAX_FEED_BYTES)
        if r.status_code >= 400:
            raise http.FetchError(f"O site respondeu {r.status_code}")
        final = str(r.url)
        try:
            return final, parse(body, final)
        except NotAFeed:
            pass
        # Os conhecidos primeiro: o feed que a página anuncia pode estar
        # parado (o do Estadão traz matérias de 2015).
        known = KNOWN.get(urlsplit(final).netloc.lower().removeprefix("www."), [])
        candidates = list(dict.fromkeys(known + feed_links(body, final) + guesses(final)))
        for candidate in candidates:
            found = await _try(client, candidate)
            if found:
                return found[0], found[1]
    raise http.FetchError("Não encontrei um feed RSS ou Atom nesse endereço")
