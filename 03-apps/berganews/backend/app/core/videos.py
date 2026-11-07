"""Vídeos das matérias, como cartões: miniatura e o endereço do player.

O arquivo de vídeo em si não vem para o servidor: os sites mandam em
pedaços (HLS), muitas vezes com proteção, e cada um pesa centenas de MB.
O cartão mostra a miniatura (que vem, como as outras imagens) e abre o
vídeo no player do veículo (Globoplay, YouTube, Vimeo, a página da BBC).

No HTML guardado, o cartão é um link com title="berganews:video" em volta
da miniatura; o app desenha o cartão com o botão de play.
"""
from __future__ import annotations

import html as htmllib
import re
from urllib.parse import urljoin

MARK = "berganews:video"

# Só os embutidos de verdade (<iframe>): um link do YouTube no rodapé não é
# vídeo da matéria.
_YOUTUBE = re.compile(
    rb'<iframe[^>]+?(?:src|data-src)="[^"]*?youtube(?:-nocookie)?\.com/embed/([\w-]{11})', re.I)
_VIMEO = re.compile(rb'<iframe[^>]+?(?:src|data-src)="[^"]*?player\.vimeo\.com/video/(\d+)', re.I)
# Miniatura de vídeo da Globo no meio do texto: s0N.video.glbimg.com/x240/<id>.jpg
_GLOBO_THUMB = re.compile(
    r'<img([^>]*?)src="(https?://s\d+\.video\.glbimg\.com/x\d+/(\d+)\.jpg)"([^>]*)>')
_META = re.compile(rb'<meta\s+[^>]*?(?:property|name)="([^"]+)"[^>]*?content="([^"]*)"', re.I)
_VIDEO_PATH = re.compile(r"/(videos?|playlist|play/videos|ao-vivo)/")


def card(url: str, thumb: str | None, caption: str | None) -> str:
    label = htmllib.escape(caption or "Vídeo", quote=True)
    link = htmllib.escape(url, quote=True)
    if thumb:
        return (f'<p><a href="{link}" title="{MARK}"><img src="{htmllib.escape(thumb, quote=True)}" '
                f'alt="{label}"></a></p>')
    return f'<p><a href="{link}" title="{MARK}">▶ {label}</a></p>'


# Vídeos de vitrine que a Globo põe em várias páginas, sem relação com a
# matéria: saem.
_GLOBO_GENERIC = {"agora no g1", "agora no ge", "agora no gshow", "assista ao vivo"}
_GLOBO_GENERIC_CAPTION = re.compile(
    r"<p>\s*(?:" + "|".join(re.escape(x) for x in sorted(_GLOBO_GENERIC)) + r")\s*</p>", re.I)


def globo_thumbs_to_cards(html: str) -> str:
    """Miniatura de vídeo da Globo vira cartão que abre o vídeo no Globoplay."""
    def repl(m: re.Match) -> str:
        attrs = m.group(1) + m.group(4)
        alt = re.search(r'alt="([^"]*)"', attrs)
        if alt and alt.group(1).strip().lower() in _GLOBO_GENERIC:
            return ""
        url = f"https://globoplay.globo.com/v/{m.group(3)}/"
        return (f'<a href="{url}" title="{MARK}"><img src="{m.group(2)}" '
                f'alt="{alt.group(1) if alt else "Vídeo"}"></a>')
    html = _GLOBO_THUMB.sub(repl, html)
    # A legenda da vitrine fica solta num parágrafo: sai também.
    return _GLOBO_GENERIC_CAPTION.sub("", html)


def meta(page: bytes) -> dict[str, str]:
    out: dict[str, str] = {}
    head = page[:300_000]
    for key, value in _META.findall(head):
        k = key.decode("utf-8", "replace").lower()
        out.setdefault(k, htmllib.unescape(value.decode("utf-8", "replace")))
    return out


def embeds(page: bytes, limit: int = 3) -> list[tuple[str, str | None]]:
    """Vídeos do YouTube e do Vimeo embutidos na página: (endereço, miniatura)."""
    found: list[tuple[str, str | None]] = []
    for vid in dict.fromkeys(m.decode() for m in _YOUTUBE.findall(page)):
        found.append((f"https://www.youtube.com/watch?v={vid}", f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"))
    for vid in dict.fromkeys(m.decode() for m in _VIMEO.findall(page)):
        found.append((f"https://vimeo.com/{vid}", None))
    return found[:limit]


def page_video(page: bytes, url: str) -> tuple[str, str | None, str | None] | None:
    """A página é um vídeo (og:type video, og:video, ou /videos/ no endereço)?
    Devolve (endereço para assistir, miniatura, título)."""
    m = meta(page)
    is_video = (m.get("og:type", "").startswith("video") or "og:video" in m
                or "og:video:url" in m or bool(_VIDEO_PATH.search(url)))
    if not is_video:
        return None
    thumb = m.get("og:image")
    return url, urljoin(url, thumb) if thumb else None, m.get("og:title")


def add_embeds(html: str, page: bytes) -> str:
    """Põe no fim os vídeos embutidos que ainda não estão no texto."""
    extra = [card(u, t, None) for u, t in embeds(page) if u not in html]
    if not extra:
        return html
    return html + "<h3>Vídeos da matéria</h3>" + "".join(extra)
