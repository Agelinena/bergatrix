"""Busca no YouTube via yt-dlp (extracão de metadados, sem download)."""

from __future__ import annotations

import logging

import yt_dlp

from app.search.models import SearchResult

logger = logging.getLogger("bergastream.search.youtube")

# Opções mínimas para busca — não baixa nada
_YDL_OPTS = {
    "quiet": True,
    "no_warnings": True,
    "extract_flat": "in_playlist",
    "default_search": "ytsearch",
    "ignoreerrors": True,
}


def search(query: str, limit: int = 10) -> list[SearchResult]:
    """Busca faixas no YouTube via yt-dlp search."""
    try:
        with yt_dlp.YoutubeDL(_YDL_OPTS) as ydl:
            info = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)
    except Exception as exc:
        logger.warning("Erro ao buscar no YouTube: %s", exc)
        return []

    entries = info.get("entries") if info else []
    if not entries:
        return []

    results: list[SearchResult] = []
    for entry in entries:
        if not entry:
            continue
        duration = entry.get("duration") or 0
        # channel/uploader é o "artista" no YouTube
        uploader = entry.get("channel") or entry.get("uploader") or ""
        results.append(SearchResult(
            provider="youtube",
            external_id=entry.get("id", ""),
            title=entry.get("title", ""),
            artist=uploader,
            album="",
            duration_seconds=int(duration),
            isrc=None,  # YouTube não fornece ISRC
            cover_url=entry.get("thumbnail"),
        ))

    logger.info("YouTube: %d resultados para %r", len(results), query)
    return results