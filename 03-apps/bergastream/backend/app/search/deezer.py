"""Deezer pela API pública (sem login): busca de músicas, artistas e
álbuns. As músicas baixam pelo próprio Deezer (Deemix), com o YouTube de
reserva."""
from __future__ import annotations

import httpx

from app.search.models import AlbumResult, ArtistResult, FullSearch, SearchResult

API = "https://api.deezer.com"


class DeezerError(Exception):
    pass


def get(path: str, **params) -> dict:
    with httpx.Client(base_url=API, timeout=15) as cli:
        data = cli.get(path, params=params).json()
    if isinstance(data, dict) and data.get("error"):
        raise DeezerError(str(data["error"]))
    return data


def track_from(item: dict, album: dict | None = None) -> SearchResult:
    alb = item.get("album") or album or {}
    artist = item.get("artist") or {}
    return SearchResult(
        provider="deezer", external_id=str(item["id"]), title=item.get("title", ""),
        artist=artist.get("name", ""), album=alb.get("title", ""),
        duration_seconds=int(item.get("duration") or 0), isrc=item.get("isrc"),
        cover_url=alb.get("cover_xl") or alb.get("cover_big"),
        artist_id=str(artist["id"]) if artist.get("id") else None,
        album_id=str(alb["id"]) if alb.get("id") else None,
    )


def album_result(a: dict) -> AlbumResult:
    return AlbumResult(
        provider="deezer", external_id=str(a["id"]), title=a.get("title", ""),
        artist=(a.get("artist") or {}).get("name", ""),
        year=(a.get("release_date") or "")[:4] or None,
        image_url=a.get("cover_xl") or a.get("cover_big"))


def search_full(query: str, limit: int = 10) -> FullSearch:
    tracks = get("/search", q=query, limit=limit).get("data") or []
    artists = get("/search/artist", q=query, limit=6).get("data") or []
    albums = get("/search/album", q=query, limit=6).get("data") or []
    return FullSearch(
        tracks=[track_from(t) for t in tracks if t.get("id") and t.get("readable", True)],
        artists=[ArtistResult(provider="deezer", external_id=str(a["id"]), name=a.get("name", ""),
                              image_url=a.get("picture_xl") or a.get("picture_big"))
                 for a in artists if a.get("id")],
        albums=[album_result(a) for a in albums if a.get("id")],
    )
