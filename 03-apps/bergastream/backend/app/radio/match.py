"""Comparar músicas e artistas vindos de fontes diferentes.

Cada fonte escreve do seu jeito ("Chop Suey!" / "Chop Suey! (Remastered)",
"System Of A Down" / "System of a Down"), então tudo é comparado pela chave
normalizada: sem acento, minúsculas, sem o que vem entre parênteses e sem
sufixos de versão ("- 2015 Remaster", "feat. X").
"""
from __future__ import annotations

import re
import unicodedata

# O que está entre parênteses/colchetes e os sufixos depois de " - ".
_BRACKETS = re.compile(r"\s*[\(\[][^\)\]]*[\)\]]")
_SUFFIX = re.compile(
    r"\s+-\s+.*\b(remaster(ed)?|version|mix|edit|live|ao vivo|mono|stereo|single|deluxe|"
    r"from|feat\.?|ft\.?|acoustic|demo|bonus)\b.*$", re.I)
_FEAT = re.compile(r"\s+(feat\.?|ft\.?|featuring|with)\s+.*$", re.I)
_NON_WORD = re.compile(r"[^a-z0-9]+")
_THE = re.compile(r"^the\s+")

# Versões que não entram na rádio, a não ser que a música inicial também
# seja uma delas (rádio de uma música ao vivo pode ter outras ao vivo).
VERSION_MARKERS = {
    "live": re.compile(r"\b(live|ao vivo|en vivo|live at|unplugged)\b", re.I),
    "karaoke": re.compile(r"\b(karaok[eê]|backing track|instrumental)\b", re.I),
    "remix": re.compile(r"\b(remix|rmx|sped up|slowed|nightcore|8d audio|reverb)\b", re.I),
    "cover": re.compile(r"\b(cover|tribute|in the style of|made famous)\b", re.I),
    "acoustic": re.compile(r"\b(acoustic|ac[uú]stic[oa])\b", re.I),
}


def _fold(text: str) -> str:
    text = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in text if not unicodedata.combining(c)).lower().strip()


def norm_artist(artist: str) -> str:
    """Primeiro artista, normalizado ("The Offspring, X" -> "offspring")."""
    first = re.split(r",|;|&| x | feat\.? | ft\.? ", artist or "", maxsplit=1)[0]
    folded = _THE.sub("", _fold(first))
    return _NON_WORD.sub("", folded)


def norm_title(title: str) -> str:
    t = _fold(title)
    t = _SUFFIX.sub("", t)
    t = _BRACKETS.sub("", t)
    t = _FEAT.sub("", t)
    return _NON_WORD.sub("", t)


def key(artist: str, title: str) -> str:
    return f"{norm_artist(artist)}|{norm_title(title)}"


def versions(title: str, album: str = "") -> set[str]:
    """Marcas de versão no título (ou no álbum: "Live at Wembley")."""
    text = f"{title or ''} {album or ''}"
    return {name for name, rx in VERSION_MARKERS.items() if rx.search(text)}


def plainness(title: str, album: str = "") -> int:
    """Qual versão mostrar quando a mesma música chega de várias formas:
    0 = título limpo ("Numb"), 1 = com sufixo ("Numb - 2014 Remaster"),
    2 = ao vivo, cover, remix... (só entra se a semente também for)."""
    if versions(title, album):
        return 2
    t = (title or "").strip()
    return 1 if _BRACKETS.search(t) or _SUFFIX.search(t) or " - " in t else 0
