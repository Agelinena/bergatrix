"""Artista (populares, álbuns, todas as faixas paginadas) e álbum, no
Spotify, no YT Music e no Deezer. Respostas ficam 10 min em cache."""
from __future__ import annotations

import logging

from app.catalog.cache import cached
from app.catalog.models import AlbumPage, ArtistPage, TrackPage
from app.search import deezer, spotify, ytmusic
from app.search.models import AlbumResult, SearchResult

logger = logging.getLogger("bergastream.catalog")

_TTL = 600
MAX_PAGE = 50


class NotFound(Exception):
    pass


def page_of(tracks: list[SearchResult], offset: int, limit: int, total: int | None = None) -> TrackPage:
    """Recorta [offset, offset+limit) de uma lista já carregada."""
    limit = max(1, min(limit, MAX_PAGE))
    items = tracks[offset:offset + limit]
    end = offset + len(items)
    known_total = total if total is not None else len(tracks)
    return TrackPage(items=items, offset=offset, total=max(known_total, end),
                     next_offset=end if end < len(tracks) else None)


def dedupe(tracks: list[SearchResult]) -> list[SearchResult]:
    """A mesma música aparece em vários álbuns (coletâneas, deluxe): fica a
    primeira (pelo ISRC ou, sem ele, título + duração)."""
    seen: set[str] = set()
    result = []
    for t in tracks:
        key = t.isrc or f"{t.title.lower().strip()}|{t.duration_seconds}"
        if key not in seen:
            seen.add(key)
            result.append(t)
    return result


# ── Spotify (SpotifyScraper, sem conta) ─────────────────────────

def _sp_call(fn, *args, **kwargs):
    from spotify_scraper.errors import NotFoundError
    try:
        return fn(*args, **kwargs)
    except NotFoundError as exc:
        raise NotFound(str(args[0]) if args else "spotify") from exc


def _spotify_albums(artist_id: str) -> list:
    """Discografia completa (álbuns, singles e coletâneas), até 200."""
    return cached(f"sp:albums:{artist_id}", _TTL,
                  lambda: list(_sp_call(spotify.client().get_discography, artist_id, max_releases=200)))


def spotify_artist(artist_id: str) -> ArtistPage:
    def load():
        artist = _sp_call(spotify.client().get_artist, artist_id)
        return ArtistPage(
            provider="spotify", external_id=artist_id, name=artist.name or "",
            image_url=spotify.best_image(artist.images),
            followers=artist.followers,
            top_tracks=[spotify.track_from(t) for t in artist.top_tracks if t.id],
            albums=[spotify.album_result(a, artist.name or "") for a in _spotify_albums(artist_id)],
        )
    return cached(f"sp:artist:{artist_id}", _TTL, load)


def _spotify_album_full(album_id: str) -> tuple[object, list[SearchResult]]:
    """Álbum e suas faixas (o ISRC é buscado quando a faixa é registrada)."""
    def load():
        album = _sp_call(spotify.client().get_album, album_id)
        return album, [spotify.track_from(t, album) for t in album.tracks if t.id]
    return cached(f"sp:album:{album_id}", _TTL, load)


def spotify_artist_tracks(artist_id: str, offset: int, limit: int) -> TrackPage:
    """Todas as faixas do artista, álbum por álbum (o Spotify não tem uma
    lista única). Carrega só os álbuns necessários para a página pedida;
    se parou antes do fim, ainda há próxima página."""
    albums = _spotify_albums(artist_id)
    collected: list[SearchResult] = []
    loaded_all = True
    for album in albums:
        collected = dedupe(collected + _spotify_album_full(album.id)[1])
        if len(collected) > offset + limit:
            loaded_all = False
            break
    # A discografia não traz o número de faixas: estima ~10 por lançamento.
    total = len(collected) if loaded_all else max(len(albums) * 10, len(collected))
    return page_of(collected, offset, limit, total)


def spotify_album(album_id: str) -> AlbumPage:
    album, tracks = _spotify_album_full(album_id)
    artists = album.artists or ()
    return AlbumPage(
        provider="spotify", external_id=album_id, title=album.name or "",
        artist=", ".join(a.name for a in artists if a.name),
        artist_id=spotify.entity_id(artists[0]) if artists else None,
        year=str(album.release_date.year) if album.release_date else None,
        image_url=spotify.best_image(album.images), tracks=tracks)


# ── YT Music ─────────────────────────────────────────────────────

def _yt_artist_raw(browse_id: str) -> dict:
    return cached(f"yt:artist:{browse_id}", _TTL, lambda: ytmusic._yt().get_artist(browse_id))


def ytmusic_artist(browse_id: str) -> ArtistPage:
    raw = _yt_artist_raw(browse_id)
    if not raw:
        raise NotFound(browse_id)
    songs = (raw.get("songs") or {}).get("results") or []
    albums = []
    for section in ("albums", "singles"):
        block = raw.get(section) or {}
        results = block.get("results") or []
        if block.get("browseId") and block.get("params"):
            try:
                results = ytmusic._yt().get_artist_albums(block["browseId"], block["params"]) or results
            except Exception as exc:
                logger.info("[catalog] lista completa de %s falhou: %s", section, exc)
        for a in results:
            if a.get("browseId"):
                albums.append(AlbumResult(
                    provider="ytmusic", external_id=a["browseId"], title=a.get("title", ""),
                    artist=raw.get("name", ""), year=a.get("year"),
                    image_url=ytmusic.thumbnail(a.get("thumbnails"))))
    return ArtistPage(
        provider="ytmusic", external_id=browse_id, name=raw.get("name", ""),
        image_url=ytmusic.thumbnail(raw.get("thumbnails")),
        followers_text=raw.get("subscribers"),
        top_tracks=[t for t in (ytmusic.track_from(s) for s in songs) if t],
        albums=albums,
    )


def ytmusic_artist_tracks(browse_id: str, offset: int, limit: int) -> TrackPage:
    """Todas as músicas do artista: o YT Music tem uma playlist "Músicas"
    com tudo; carrega uma vez (até 1000) e recorta."""
    def load():
        raw = _yt_artist_raw(browse_id)
        songs = raw.get("songs") or {}
        if songs.get("browseId"):
            playlist = ytmusic._yt().get_playlist(songs["browseId"], limit=1000)
            items = playlist.get("tracks") or []
        else:
            items = songs.get("results") or []
        return dedupe([t for t in (ytmusic.track_from(i) for i in items) if t])
    return page_of(cached(f"yt:artist-tracks:{browse_id}", _TTL, load), offset, limit)


def ytmusic_album(browse_id: str) -> AlbumPage:
    album = cached(f"yt:album:{browse_id}", _TTL, lambda: ytmusic._yt().get_album(browse_id))
    if not album:
        raise NotFound(browse_id)
    cover = ytmusic.thumbnail(album.get("thumbnails"))
    artists = [a for a in album.get("artists") or [] if a.get("name")]
    return AlbumPage(
        provider="ytmusic", external_id=browse_id, title=album.get("title", ""),
        artist=", ".join(a["name"] for a in artists),
        artist_id=next((a["id"] for a in artists if a.get("id")), None),
        year=album.get("year"), image_url=cover,
        tracks=[t for t in (ytmusic.track_from(i, album.get("title", ""), cover, browse_id)
                            for i in album.get("tracks") or []) if t])


# ── Deezer ───────────────────────────────────────────────────────

def _dz(path: str, **params) -> dict:
    try:
        return deezer.get(path, **params)
    except deezer.DeezerError:
        raise NotFound(path)


def _deezer_albums(artist_id: str) -> list[dict]:
    return cached(f"dz:albums:{artist_id}", _TTL,
                  lambda: _dz(f"/artist/{artist_id}/albums", limit=100).get("data") or [])


def _deezer_album_full(album_id: str) -> tuple[dict, list[SearchResult]]:
    def load():
        album = _dz(f"/album/{album_id}")
        items = (album.get("tracks") or {}).get("data") or []
        return album, [deezer.track_from(t, album) for t in items if t.get("id")]
    return cached(f"dz:album:{album_id}", _TTL, load)


def deezer_artist(artist_id: str) -> ArtistPage:
    def load():
        raw = _dz(f"/artist/{artist_id}")
        top = _dz(f"/artist/{artist_id}/top", limit=10).get("data") or []
        return ArtistPage(
            provider="deezer", external_id=artist_id, name=raw.get("name", ""),
            image_url=raw.get("picture_xl") or raw.get("picture_big"),
            followers=raw.get("nb_fan"),
            top_tracks=[deezer.track_from(t) for t in top if t.get("id")],
            albums=[deezer.album_result(a) for a in _deezer_albums(artist_id)])
    return cached(f"dz:artist:{artist_id}", _TTL, load)


def deezer_artist_tracks(artist_id: str, offset: int, limit: int) -> TrackPage:
    """Todas as faixas, álbum por álbum (como no Spotify)."""
    albums = _deezer_albums(artist_id)
    collected: list[SearchResult] = []
    loaded_all = True
    for a in albums:
        collected = dedupe(collected + _deezer_album_full(str(a["id"]))[1])
        if len(collected) > offset + limit:
            loaded_all = False
            break
    estimated = sum(int(a.get("nb_tracks") or 0) for a in albums)
    total = len(collected) if loaded_all else max(estimated, len(collected))
    return page_of(collected, offset, limit, total)


def deezer_album(album_id: str) -> AlbumPage:
    album, tracks = _deezer_album_full(album_id)
    artist = album.get("artist") or {}
    return AlbumPage(
        provider="deezer", external_id=album_id, title=album.get("title", ""),
        artist=artist.get("name", ""), artist_id=str(artist["id"]) if artist.get("id") else None,
        year=(album.get("release_date") or "")[:4] or None,
        image_url=album.get("cover_xl") or album.get("cover_big"), tracks=tracks)


# ── Entrada ──────────────────────────────────────────────────────

def artist(provider: str, external_id: str) -> ArtistPage:
    return {"spotify": spotify_artist, "deezer": deezer_artist}.get(
        provider, ytmusic_artist)(external_id)


def artist_tracks(provider: str, external_id: str, offset: int, limit: int) -> TrackPage:
    return {"spotify": spotify_artist_tracks, "deezer": deezer_artist_tracks}.get(
        provider, ytmusic_artist_tracks)(external_id, offset, limit)


def album(provider: str, external_id: str) -> AlbumPage:
    return {"spotify": spotify_album, "deezer": deezer_album}.get(
        provider, ytmusic_album)(external_id)
