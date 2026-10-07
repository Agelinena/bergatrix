"""Busca no YouTube Music via ytmusicapi (sem login).

O ytmusicapi traz artista, álbum, duração e capa; a busca antiga via yt-dlp
(que vinha sem esses campos) ficou só como reserva se ele falhar.
"""
from __future__ import annotations

import logging
import re
import threading

import yt_dlp
from ytmusicapi import YTMusic

from app.search.models import AlbumResult, ArtistResult, FullSearch, SearchResult

logger = logging.getLogger("bergastream.search.ytmusic")
_YDL_OPTS = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", "ignoreerrors": True}
_VIDEO_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{11}$")
_SIZE_RE = re.compile(r"=w\d+-h\d+")

_local = threading.local()


def _yt() -> YTMusic:
    """Um cliente por thread (as buscas rodam em threads)."""
    if not hasattr(_local, "yt"):
        _local.yt = YTMusic()
    return _local.yt


def thumbnail(thumbnails: list | None, size: int = 544) -> str | None:
    """Maior miniatura, pedindo [size] px ao servidor de imagens do Google."""
    if not thumbnails:
        return None
    url = thumbnails[-1].get("url")
    return _SIZE_RE.sub(f"=w{size}-h{size}", url) if url else None


def track_from(item: dict, album_name: str = "", cover: str | None = None,
               album_id: str | None = None) -> SearchResult | None:
    """Converte uma música do ytmusicapi (busca, álbum ou playlist)."""
    vid = item.get("videoId")
    if not vid or not _is_valid_video_id(vid):
        return None
    album = item.get("album")
    artists = [a for a in item.get("artists") or [] if a.get("name")]
    return SearchResult(
        provider="ytmusic",
        external_id=vid,
        title=(item.get("title") or "").strip(),
        artist=", ".join(a["name"] for a in artists),
        album=(album.get("name") if isinstance(album, dict) else album) or album_name,
        duration_seconds=int(item.get("duration_seconds") or 0),
        isrc=None,
        cover_url=thumbnail(item.get("thumbnails")) or cover,
        artist_id=next((a["id"] for a in artists if a.get("id")), None),
        album_id=(album.get("id") if isinstance(album, dict) else None) or album_id,
    )


def watch_track_from(item: dict) -> SearchResult | None:
    """Faixa de uma rádio (get_watch_playlist): duração em texto ("4:34")
    e miniatura em `thumbnail`."""
    seconds = 0
    for part in str(item.get("length") or "").split(":"):
        if part.isdigit():
            seconds = seconds * 60 + int(part)
    return track_from({**item, "duration_seconds": seconds,
                       "thumbnails": item.get("thumbnails") or item.get("thumbnail")})


def _is_valid_video_id(vid: str) -> bool:
    if not vid or not _VIDEO_ID_RE.match(vid):
        return False
    for prefix in ("UC", "RD", "PL", "FL", "UU", "PU", "LL"):
        if vid.startswith(prefix):
            return False
    return True


def search(query: str, limit: int = 10) -> list[SearchResult]:
    try:
        items = _yt().search(query, filter="songs", limit=limit)
        results = [t for t in (track_from(i) for i in items) if t][:limit]
        logger.info("[ytmusic] %d músicas para %r", len(results), query)
        return results
    except Exception as exc:
        logger.warning("[ytmusic] ytmusicapi falhou (%s); usando yt-dlp", exc)
        return _search_ytdlp(query)


def search_full(query: str, limit: int = 10) -> FullSearch:
    tracks = search(query, limit)
    artists: list[ArtistResult] = []
    albums: list[AlbumResult] = []
    try:
        for a in _yt().search(query, filter="artists", limit=6)[:6]:
            if a.get("browseId"):
                artists.append(ArtistResult(
                    provider="ytmusic", external_id=a["browseId"],
                    name=a.get("artist") or "", image_url=thumbnail(a.get("thumbnails"))))
        for a in _yt().search(query, filter="albums", limit=6)[:6]:
            if a.get("browseId"):
                albums.append(AlbumResult(
                    provider="ytmusic", external_id=a["browseId"], title=a.get("title") or "",
                    artist=", ".join(x["name"] for x in a.get("artists") or [] if x.get("name")),
                    year=a.get("year"), image_url=thumbnail(a.get("thumbnails"))))
    except Exception as exc:
        logger.warning("[ytmusic] artistas/álbuns falharam: %s", exc)
    return FullSearch(tracks=tracks, artists=artists, albums=albums)


def _search_ytdlp(query: str) -> list[SearchResult]:
    import urllib.parse
    url = f"https://music.youtube.com/search?q={urllib.parse.quote_plus(query)}"
    try:
        with yt_dlp.YoutubeDL(_YDL_OPTS) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as exc:
        logger.warning("[ytmusic] erro: %s", exc)
        return []

    results: list[SearchResult] = []
    for entry in (info.get("entries") if info else None) or []:
        if not entry:
            continue
        vid = entry.get("id", "")
        title = (entry.get("title") or "").strip()
        if not title or not _is_valid_video_id(vid):
            continue
        results.append(SearchResult(
            provider="ytmusic", external_id=vid, title=title,
            artist=entry.get("channel") or entry.get("uploader") or "",
            album=entry.get("album", "") or "", duration_seconds=int(entry.get("duration") or 0),
            isrc=entry.get("isrc") or None, cover_url=entry.get("thumbnail"),
        ))
    return results
