"""Conferência das tags do arquivo baixado contra a faixa pedida."""
from __future__ import annotations

import json
import logging
import re
import subprocess
import unicodedata
from pathlib import Path

logger = logging.getLogger("bergastream.downloads.tags")


def normalize_title(text: str) -> str:
    """Título comparável: sem acentos, maiúsculas, parênteses/colchetes e
    sufixos depois de " - " (ex.: "Remastered 2011")."""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[\(\[].*?[\)\]]", " ", text.lower())
    text = text.split(" - ")[0]
    return re.sub(r"[^a-z0-9]+", "", text)


def titles_match(expected: str, found: str) -> bool:
    a, b = normalize_title(expected), normalize_title(found)
    if not a or not b:
        return True  # sem como comparar
    return a == b or a in b or b in a


def read_title(path: Path) -> str | None:
    """Título gravado nas tags (ID3/Vorbis), ou None se não houver."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format_tags=title",
             "-of", "json", str(path)],
            capture_output=True, text=True, timeout=15, check=False,
        ).stdout
        tags = (json.loads(out or "{}").get("format") or {}).get("tags") or {}
        return next((v for k, v in tags.items() if k.lower() == "title"), None)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        logger.warning("[tags] não leu %s: %s", path, exc)
        return None


def file_matches(path: Path, expected_title: str) -> bool:
    """O arquivo é da faixa pedida? Sem tag de título, aceita."""
    title = read_title(path)
    if title is None:
        return True
    ok = titles_match(expected_title, title)
    if not ok:
        logger.warning("[tags] %s tem título %r, esperado %r", path.name, title, expected_title)
    return ok
