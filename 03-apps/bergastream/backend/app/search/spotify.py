"""Spotify sem a Web API oficial.

Desde fevereiro de 2026 a Web API exige que o dono do app tenha Premium ativo
(sem ele as chamadas falham). O app passou a ler o Spotify como o próprio web
player faz, com um token anônimo das páginas públicas:

- busca, faixas, álbuns, artistas e playlists: biblioteca SpotifyScraper;
- ISRC, álbum e capa de uma faixa: endpoint interno de metadados
  (`app.search.spotify_meta`), que a SpotifyScraper não usa.

Não precisa de conta nem de chave. Pode quebrar quando o Spotify muda o web
player: o teste diário (`app.search.spotify_health`) detecta e atualiza a
biblioteca sozinho.
"""

from __future__ import annotations

import logging
import threading

from spotify_scraper import SpotifyClient

from app.search.models import AlbumResult, ArtistResult, FullSearch, SearchResult

logger = logging.getLogger("bergastream.search.spotify")

_client: SpotifyClient | None = None
_client_lock = threading.Lock()

# Hashes das capas do Spotify por tamanho (quando a resposta não informa a
# largura): 640 px, 300 px, 64 px.
_COVER_SIZES = ("ab67616d0000b273", "ab67616d00001e02", "ab67616d00004851")


def client() -> SpotifyClient:
    """Cliente compartilhado (um token anônimo para todas as chamadas)."""
    global _client
    with _client_lock:
        if _client is None:
            _client = SpotifyClient(timeout=15)
        return _client


def reset_client() -> None:
    """Descarta o cliente (depois de atualizar a biblioteca ou de erros)."""
    global _client
    with _client_lock:
        if _client is not None:
            try:
                _client.close()
            except Exception:
                pass
        _client = None


def best_image(images) -> str | None:
    """A maior imagem. Sem largura informada, escolhe pelo hash da capa."""
    images = [i for i in images or () if getattr(i, "url", None)]
    if not images:
        return None
    sized = [i for i in images if i.width]
    if sized:
        return max(sized, key=lambda i: i.width).url
    for size in _COVER_SIZES:
        for image in images:
            if size in image.url:
                return image.url
    return images[0].url


def entity_id(ref) -> str | None:
    """Id de uma referência (a busca às vezes só traz o `uri`)."""
    if ref is None:
        return None
    if getattr(ref, "id", ""):
        return ref.id
    uri = getattr(ref, "uri", "") or ""
    return uri.rsplit(":", 1)[-1] or None


def track_from(track, album=None) -> SearchResult:
    """Converte uma faixa da SpotifyScraper. [album] para faixas de álbum,
    que vêm sem o álbum dentro. O ISRC fica vazio: é buscado quando a faixa
    é registrada (ver app.tracks.service)."""
    album_ref = track.album or album
    artists = track.artists or ()
    return SearchResult(
        provider="spotify",
        external_id=track.id,
        title=track.name or "",
        artist=", ".join(a.name for a in artists if a.name),
        album=getattr(album_ref, "name", "") or "",
        duration_seconds=int((track.duration_ms or 0) / 1000),
        isrc=None,
        cover_url=best_image(getattr(album_ref, "images", None)) or best_image(track.images),
        artist_id=entity_id(artists[0]) if artists else None,
        album_id=entity_id(album_ref),
    )


def album_result(album, artist_name: str = "") -> AlbumResult:
    """Álbum (Album ou AlbumRef) como resultado de busca/discografia."""
    artists = getattr(album, "artists", None) or ()
    release = getattr(album, "release_date", None)
    return AlbumResult(
        provider="spotify", external_id=album.id, title=album.name or "",
        artist=", ".join(a.name for a in artists if a.name) or artist_name,
        year=str(release.year) if release else None,
        image_url=best_image(album.images))


def search(query: str, limit: int = 10) -> list[SearchResult]:
    """Busca faixas no Spotify."""
    return search_full(query, limit=limit, only_tracks=True).tracks


def search_full(query: str, limit: int = 10, only_tracks: bool = False) -> FullSearch:
    """Busca faixas, artistas e álbuns numa chamada só. Erros sobem para a
    rota, que responde "a origem não respondeu" em vez de uma lista vazia."""
    types = ("track",) if only_tracks else ("track", "artist", "album")
    raw = client().search(query, types=types, limit=limit)
    tracks = [track_from(t) for t in raw.tracks if t.id]
    artists = [
        ArtistResult(provider="spotify", external_id=a.id, name=a.name or "",
                     image_url=best_image(a.images))
        for a in raw.artists if a.id
    ]
    albums = [album_result(a) for a in raw.albums if a.id]
    logger.info("Spotify: %d faixas, %d artistas, %d álbuns para %r",
                len(tracks), len(artists), len(albums), query)
    return FullSearch(tracks=tracks, artists=artists, albums=albums)
