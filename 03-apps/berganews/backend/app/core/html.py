"""HTML dos artigos: limpeza, texto puro e links de imagem pelo servidor.

O que fica guardado no banco já está limpo (sem script, estilo, iframe,
formulário nem atributo de rastreio). Na hora de servir, as imagens passam
a apontar para /api/img, assinadas: o aparelho nunca fala com o site do
veículo, então nada de rastreador nem de imagem que some.
"""
from __future__ import annotations

import re
from html import escape
from urllib.parse import quote, urljoin

import lxml.html
import nh3
from lxml import etree

from app.core import keys

_TAGS = {
    "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "a", "img", "figure", "figcaption",
    "blockquote", "q", "cite", "ul", "ol", "li", "dl", "dt", "dd", "strong", "b", "em", "i",
    "u", "s", "sub", "sup", "small", "mark", "code", "pre", "table", "thead", "tbody", "tr",
    "th", "td", "caption", "abbr", "time",
}
_ATTRS = {
    "a": {"href", "title"},
    "img": {"src", "alt", "title", "width", "height"},
    "td": {"colspan", "rowspan"},
    "th": {"colspan", "rowspan"},
    "abbr": {"title"},
    "time": {"datetime"},
}
_LAZY = ("data-src", "data-lazy-src", "data-original", "data-url")
BLOCKS = {"p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "figcaption",
          "td", "th", "dt", "dd", "caption", "pre"}
_WS = re.compile(r"[ \t\r\f\v]+")


def fragment(html: str):
    return lxml.html.fragment_fromstring(html, create_parent="div")


def serialize_children(root) -> str:
    out = [escape(root.text, quote=False)] if root.text else []
    out += [etree.tostring(child, encoding="unicode", method="html") for child in root]
    return "".join(out)


def sanitize(html: str, base_url: str | None = None) -> str:
    """HTML qualquer (RSS, página, trafilatura) → HTML seguro, com links e
    imagens absolutos e imagens preguiçosas (data-src) resolvidas."""
    if not html or not html.strip():
        return ""
    try:
        root = fragment(html)
    except (etree.ParserError, ValueError):
        return ""
    for img in root.iter("img"):
        src = img.get("src") or ""
        if not src or src.startswith("data:"):
            for attr in _LAZY:
                if img.get(attr):
                    img.set("src", img.get(attr))
                    break
    if base_url:
        for el in root.iter("a"):
            if el.get("href"):
                el.set("href", urljoin(base_url, el.get("href").strip()))
        for el in root.iter("img"):
            if el.get("src"):
                el.set("src", urljoin(base_url, el.get("src").strip()))
    cleaned = nh3.clean(
        serialize_children(root),
        tags=_TAGS,
        attributes=_ATTRS,
        url_schemes={"http", "https", "mailto"},
        link_rel="noopener noreferrer nofollow",
        strip_comments=True,
        clean_content_tags={"script", "style", "noscript", "iframe", "form", "button",
                            "svg", "template", "select", "textarea"},
    )
    return _drop_empty(cleaned)


def _drop_empty(html: str) -> str:
    """Tira imagens sem src e parágrafos vazios que sobram da limpeza."""
    if not html.strip():
        return ""
    root = fragment(html)
    for img in list(root.iter("img")):
        if not (img.get("src") or "").startswith(("http://", "https://")):
            img.drop_tree()
    for el in list(root.iter("p", "figure", "li")):
        if not (el.text_content() or "").strip() and el.find(".//img") is None:
            el.drop_tree()
    return serialize_children(root).strip()


def to_text(html: str) -> str:
    """Texto puro, um bloco por linha (busca, embeddings, contagem)."""
    if not html:
        return ""
    root = fragment(html)
    for el in root.iter(*BLOCKS, "br"):
        el.tail = "\n" + (el.tail or "")
    text = root.text_content()
    lines = (_WS.sub(" ", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if line)


def first_image(html: str) -> str | None:
    if not html:
        return None
    for img in fragment(html).iter("img"):
        src = img.get("src") or ""
        if src.startswith(("http://", "https://")):
            return src
    return None


def image_link(url: str) -> str:
    """Endereço da imagem pelo servidor, assinado (não vira proxy aberto)."""
    return f"/api/img?u={quote(url, safe='')}&s={keys.sign('img', url)}"


def proxy_images(html: str) -> str:
    """Na hora de servir: <img src> do veículo → /api/img assinado."""
    if not html:
        return ""
    root = fragment(html)
    for img in root.iter("img"):
        src = img.get("src") or ""
        if src.startswith(("http://", "https://")):
            img.set("src", image_link(src))
            img.set("loading", "lazy")
    return serialize_children(root)
