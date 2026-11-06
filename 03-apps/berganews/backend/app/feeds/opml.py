"""OPML: importar (de outro leitor) e exportar (para backup ou outro leitor).

A pasta é o <outline> de cima, sem xmlUrl, como no FreshRSS, Feedly e
Inoreader. Feed dentro de várias pastas fica na primeira.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from xml.etree.ElementTree import Element, SubElement, tostring

from defusedxml import ElementTree as SafeET

MAX_OPML_BYTES = 2 * 1024 * 1024


@dataclass
class OpmlFeed:
    url: str
    title: str | None
    folder: str | None


class OpmlError(Exception):
    pass


def parse(body: bytes) -> list[OpmlFeed]:
    if len(body) > MAX_OPML_BYTES:
        raise OpmlError("Arquivo grande demais")
    try:
        root = SafeET.fromstring(body)
    except Exception as exc:  # defusedxml recusa entidades: também cai aqui
        raise OpmlError("Arquivo OPML inválido") from exc
    body_el = root.find("body")
    if body_el is None:
        raise OpmlError("Arquivo OPML sem <body>")
    feeds: dict[str, OpmlFeed] = {}

    def walk(el, folder: str | None):
        for outline in el.findall("outline"):
            url = (outline.get("xmlUrl") or "").strip()
            label = (outline.get("title") or outline.get("text") or "").strip() or None
            if url:
                if url.startswith(("http://", "https://")) and url not in feeds:
                    feeds[url] = OpmlFeed(url=url, title=label, folder=folder)
            else:
                walk(outline, label if folder is None else folder)

    walk(body_el, None)
    return list(feeds.values())


def build(owner: str, rows) -> bytes:
    """rows: (folder, title, url, site_url), já ordenadas por pasta."""
    opml = Element("opml", version="2.0")
    head = SubElement(opml, "head")
    SubElement(head, "title").text = f"Berganews — {owner}"
    SubElement(head, "dateCreated").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S GMT")
    body = SubElement(opml, "body")
    folders: dict[str, Element] = {}
    for folder, title, url, site_url in rows:
        parent = body
        if folder:
            if folder not in folders:
                folders[folder] = SubElement(body, "outline", text=folder, title=folder)
            parent = folders[folder]
        attrs = {"type": "rss", "text": title or url, "title": title or url, "xmlUrl": url}
        if site_url:
            attrs["htmlUrl"] = site_url
        SubElement(parent, "outline", attrs)
    return b'<?xml version="1.0" encoding="UTF-8"?>\n' + tostring(opml, encoding="utf-8")
