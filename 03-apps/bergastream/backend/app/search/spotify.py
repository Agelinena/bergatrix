"""Busca no Spotify via Client Credentials (spotipy)."""

from __future__ import annotations

import logging

import spotipy
from spotipy.oauth2 import SpotifyClientCredentials

from app.config import settings
from app.search.models import AlbumResult, ArtistResult, FullSearch, SearchResult

logger = logging.getLogger("bergastream.search.spotify")


def client() -> spotipy.Spotify | None:
    """Cliente do Spotify, ou None sem credenciais."""
    if not settings.spotify_client_id or not settings.spotify_client_secret:
        logger.info("Spotify credenciais não configuradas — pulando")
        return None
    auth = SpotifyClientCredentials(
        client_id=settings.spotify_client_id,
        client_secret=settings.spotify_client_secret,
    )
    return spotipy.Spotify(auth_manager=auth, requests_timeout=15)


def _image(images: list | None) -> str | None:
    return images[0]["url"] if images else None


def track_from(item: dict, album: dict | None = None) -> SearchResult:
    """Converte uma faixa da API do Spotify. [album] para faixas de álbum,
    que vêm sem o álbum dentro."""
    album_data = item.get("album") or album or {}
    return SearchResult(
        provider="spotify",
        external_id=item["id"],
        title=item.get("name", ""),
        artist=", ".join(a["name"] for a in item.get("artists", [])),
        album=album_data.get("name", ""),
        duration_seconds=int((item.get("duration_ms") or 0) / 1000),
        isrc=(item.get("external_ids") or {}).get("isrc"),
        cover_url=_image(album_data.get("images")),
        artist_id=(item.get("artists") or [{}])[0].get("id"),
        album_id=album_data.get("id"),
    )


def search(query: str, limit: int = 10) -> list[SearchResult]:
    """Busca faixas no Spotify. Retorna lista vazia se sem credenciais."""
    return search_full(query, limit=limit, only_tracks=True).tracks


def search_full(query: str, limit: int = 10, only_tracks: bool = False) -> FullSearch:
    """Busca faixas, artistas e álbuns numa chamada só."""
    sp = client()
    if sp is None:
        return FullSearch()
    try:
        raw = sp.search(q=query, type="track" if only_tracks else "track,artist,album", limit=limit)
    except Exception as exc:
        logger.warning("Erro ao buscar no Spotify: %s", exc)
        return FullSearch()

    tracks = [track_from(i) for i in (raw.get("tracks") or {}).get("items", []) if i]
    artists = [
        ArtistResult(provider="spotify", external_id=a["id"], name=a.get("name", ""),
                     image_url=_image(a.get("images")))
        for a in (raw.get("artists") or {}).get("items", []) if a
    ]
    albums = [
        AlbumResult(provider="spotify", external_id=a["id"], title=a.get("name", ""),
                    artist=", ".join(x["name"] for x in a.get("artists", [])),
                    year=(a.get("release_date") or "")[:4] or None,
                    image_url=_image(a.get("images")))
        for a in (raw.get("albums") or {}).get("items", []) if a
    ]
    logger.info("Spotify: %d faixas, %d artistas, %d álbuns para %r",
                len(tracks), len(artists), len(albums), query)
    return FullSearch(tracks=tracks, artists=artists, albums=albums)
