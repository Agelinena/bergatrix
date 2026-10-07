"""Modelos das páginas de artista e álbum (Seção 6.7 do app)."""
from __future__ import annotations

from pydantic import BaseModel

from app.search.models import AlbumResult, SearchResult


class ArtistPage(BaseModel):
    provider: str
    external_id: str
    name: str
    image_url: str | None = None
    followers: int | None = None  # Spotify
    followers_text: str | None = None  # YT Music ("6,67 mi")
    top_tracks: list[SearchResult] = []
    albums: list[AlbumResult] = []


class TrackPage(BaseModel):
    """Página de "Todas as músicas" (paginação por offset)."""
    items: list[SearchResult] = []
    offset: int
    total: int
    next_offset: int | None = None


class AlbumPage(BaseModel):
    provider: str
    external_id: str
    title: str
    artist: str = ""
    artist_id: str | None = None
    year: str | None = None
    image_url: str | None = None
    tracks: list[SearchResult] = []
