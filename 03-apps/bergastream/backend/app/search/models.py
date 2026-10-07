"""Modelos de dados para busca."""

from __future__ import annotations

from pydantic import BaseModel


class SearchResult(BaseModel):
    """Item único de resultado de busca (Spotify ou YouTube)."""
    provider: str  # 'spotify' | 'youtube'
    external_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    isrc: str | None = None
    cover_url: str | None = None
    # Para "Ir para o artista/álbum" no app (quando a origem informa).
    artist_id: str | None = None
    album_id: str | None = None

class ArtistResult(BaseModel):
    """Artista nos resultados de busca."""
    provider: str  # 'spotify' | 'ytmusic'
    external_id: str
    name: str
    image_url: str | None = None


class AlbumResult(BaseModel):
    """Álbum nos resultados de busca."""
    provider: str
    external_id: str
    title: str
    artist: str = ""
    year: str | None = None
    image_url: str | None = None


class FullSearch(BaseModel):
    """Resposta de GET /api/search/full."""
    tracks: list[SearchResult] = []
    artists: list[ArtistResult] = []
    albums: list[AlbumResult] = []
