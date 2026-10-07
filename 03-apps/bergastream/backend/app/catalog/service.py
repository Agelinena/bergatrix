"""Artista (populares, álbuns, todas as faixas paginadas) e álbum, no
Spotify e no YT Music. Respostas ficam 10 min em cache."""
from __future__ import annotations

import logging

from app.catalog.cache import cached
from app.catalog.models import AlbumPage, ArtistPage, TrackPage
from app.search import spotify, ytmusic
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


# ── Spotify ──────────────────────────────────────────────────────

def _sp():
    sp = spotify.client()
    if sp is None:
        raise NotFound("Spotify sem credenciais")
    return sp


def _spotify_albums(artist_id: str) -> list[dict]:
    def load():
        sp = _sp()
        albums, page = [], sp.artist_albums(artist_id, include_groups="album,single", limit=50)
        while page and len(albums) < 200:
            albums += [a for a in page["items"] if a]
            page = sp.next(page) if page.get("next") else None
        return albums
    return cached(f"sp:albums:{artist_id}", _TTL, load)


def spotify_artist(artist_id: str) -> ArtistPage:
    def load():
        sp = _sp()
        artist = sp.artist(artist_id)
        top = sp.artist_top_tracks(artist_id, country="BR").get("tracks") or []
        return ArtistPage(
            provider="spotify", external_id=artist_id, name=artist.get("name", ""),
            image_url=spotify._image(artist.get("images")),
            followers=(artist.get("followers") or {}).get("total"),
            top_tracks=[spotify.track_from(t) for t in top],
            albums=[_spotify_album_result(a) for a in _spotify_albums(artist_id)],
        )
    return cached(f"sp:artist:{artist_id}", _TTL, load)


def _spotify_album_result(a: dict) -> AlbumResult:
    return AlbumResult(provider="spotify", external_id=a["id"], title=a.get("name", ""),
                       artist=", ".join(x["name"] for x in a.get("artists", [])),
                       year=(a.get("release_date") or "")[:4] or None,
                       image_url=spotify._image(a.get("images")))


def _spotify_album_full(album_id: str) -> tuple[dict, list[SearchResult]]:
    """Álbum e suas faixas completas (com ISRC; as do álbum vêm sem)."""
    def load():
        sp = _sp()
        album = sp.album(album_id)
        ids, page = [], album["tracks"]
        while page:
            ids += [i["id"] for i in page["items"] if i and i.get("id")]
            page = sp.next(page) if page.get("next") else None
        tracks = []
        for start in range(0, len(ids), 50):
            tracks += [spotify.track_from(t, album) for t in sp.tracks(ids[start:start + 50])["tracks"] if t]
        return album, tracks
    return cached(f"sp:album:{album_id}", _TTL, load)


def spotify_artist_tracks(artist_id: str, offset: int, limit: int) -> TrackPage:
    """Todas as faixas do artista, álbum por álbum (o Spotify não tem um
    endpoint único). Carrega só os álbuns necessários para a página pedida;
    se parou antes do fim, ainda há próxima página."""
    albums = _spotify_albums(artist_id)
    collected: list[SearchResult] = []
    loaded_all = True
    for album in albums:
        collected = dedupe(collected + _spotify_album_full(album["id"])[1])
        if len(collected) > offset + limit:
            loaded_all = False
            break
    estimated = sum(a.get("total_tracks", 0) for a in albums)
    total = len(collected) if loaded_all else max(estimated, len(collected))
    return page_of(collected, offset, limit, total)


def spotify_album(album_id: str) -> AlbumPage:
    album, tracks = _spotify_album_full(album_id)
    artists = album.get("artists") or []
    return AlbumPage(
        provider="spotify", external_id=album_id, title=album.get("name", ""),
        artist=", ".join(a["name"] for a in artists), artist_id=artists[0]["id"] if artists else None,
        year=(album.get("release_date") or "")[:4] or None,
        image_url=spotify._image(album.get("images")), tracks=tracks)


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


# ── Entrada ──────────────────────────────────────────────────────

def artist(provider: str, external_id: str) -> ArtistPage:
    return spotify_artist(external_id) if provider == "spotify" else ytmusic_artist(external_id)


def artist_tracks(provider: str, external_id: str, offset: int, limit: int) -> TrackPage:
    if provider == "spotify":
        return spotify_artist_tracks(external_id, offset, limit)
    return ytmusic_artist_tracks(external_id, offset, limit)


def album(provider: str, external_id: str) -> AlbumPage:
    return spotify_album(external_id) if provider == "spotify" else ytmusic_album(external_id)
