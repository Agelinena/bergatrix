"""Busca de playlists (GET /api/search/playlists): Spotify, Deezer e
YouTube Music, mais a rádio de um artista ("rádio scorpions").

Cada resultado traz a `url` da playlist: o app abre pelo mesmo caminho dos
links colados (resolve → "Importar").

Spotify: desde 27/11/2024, apps de desenvolvedor novos não leem as faixas
das playlists do próprio Spotify ("This Is…", "Rock Classics"); a busca já
as omite e, por garantia, as de dono "spotify" são descartadas.
"""
from __future__ import annotations

import asyncio
import logging
import re

import httpx

from app.search import spotify, ytmusic
from app.search.models import PlaylistResult

logger = logging.getLogger("bergastream.search.playlists")

_PER_SOURCE = 6
_RADIO_RE = re.compile(r"^\s*r[aá]dio\s+(.+)$", re.IGNORECASE)


def _spotify(query: str) -> list[PlaylistResult]:
    sp = spotify.client()
    if sp is None:
        return []
    raw = sp.search(q=query, type="playlist", limit=_PER_SOURCE + 4)
    out = []
    for p in (raw.get("playlists") or {}).get("items") or []:
        if not p or (p.get("owner") or {}).get("id") == "spotify":
            continue
        out.append(PlaylistResult(
            provider="spotify", external_id=p["id"], title=p.get("name") or "",
            owner=(p.get("owner") or {}).get("display_name") or "",
            track_count=(p.get("tracks") or {}).get("total"),
            image_url=spotify._image(p.get("images")),
            url=f"https://open.spotify.com/playlist/{p['id']}"))
    return out[:_PER_SOURCE]


async def _deezer(query: str) -> list[PlaylistResult]:
    async with httpx.AsyncClient(timeout=10) as cli:
        data = (await cli.get("https://api.deezer.com/search/playlist",
                              params={"q": query, "limit": _PER_SOURCE})).json()
    return [PlaylistResult(
        provider="deezer", external_id=str(p["id"]), title=p.get("title") or "",
        owner=(p.get("user") or {}).get("name") or "", track_count=p.get("nb_tracks"),
        image_url=p.get("picture_xl") or p.get("picture_big"),
        url=f"https://www.deezer.com/playlist/{p['id']}")
        for p in data.get("data") or [] if p.get("id")]


def _ytmusic(query: str) -> list[PlaylistResult]:
    yt = ytmusic._yt()
    out: list[PlaylistResult] = []
    seen: set[str] = set()
    # Editoriais do YouTube Music primeiro, depois as da comunidade.
    for kind in ("featured_playlists", "community_playlists"):
        for p in yt.search(query, filter=kind, limit=_PER_SOURCE)[:_PER_SOURCE]:
            browse = p.get("browseId") or ""
            pid = browse[2:] if browse.startswith("VL") else browse
            if not pid or pid in seen:
                continue
            seen.add(pid)
            count = p.get("itemCount")
            out.append(PlaylistResult(
                provider="ytmusic", external_id=pid, title=p.get("title") or "",
                owner=p.get("author") if isinstance(p.get("author"), str) else "",
                track_count=int(count) if str(count or "").isdigit() else None,
                image_url=ytmusic.thumbnail(p.get("thumbnails")),
                url=f"https://music.youtube.com/playlist?list={pid}"))
    return out


def _radio(artist_query: str) -> PlaylistResult | None:
    """Rádio do artista no YouTube Music (músicas dele e parecidas)."""
    yt = ytmusic._yt()
    found = yt.search(artist_query, filter="artists", limit=1)
    if not found:
        return None
    artist = yt.get_artist(found[0]["browseId"])
    radio = artist.get("radioId")
    if not radio:
        return None
    return PlaylistResult(
        provider="ytmusic", external_id=radio, kind="radio",
        title=f"Rádio {found[0].get('artist') or artist.get('name') or artist_query}",
        owner="YouTube Music", image_url=ytmusic.thumbnail(artist.get("thumbnails")),
        url=f"https://music.youtube.com/playlist?list={radio}")


async def search_playlists(query: str) -> list[PlaylistResult]:
    """Rádio (se pedida) primeiro; depois YouTube Music, Deezer e Spotify
    intercalados. Uma origem fora do ar não derruba as outras."""
    radio_match = _RADIO_RE.match(query)

    async def safe(name, coro):
        try:
            return await coro
        except Exception as exc:
            logger.info("[playlists] %s falhou: %s", name, exc)
            return []

    radio_task = (safe("rádio", asyncio.to_thread(_radio, radio_match.group(1).strip()))
                  if radio_match else asyncio.sleep(0, result=None))
    # "rádio X": no YouTube Music a palavra "rádio" atrapalha a busca.
    yt_query = radio_match.group(1).strip() if radio_match else query
    yt, dz, sp, radio = await asyncio.gather(
        safe("ytmusic", asyncio.to_thread(_ytmusic, yt_query)),
        safe("deezer", _deezer(query)),
        safe("spotify", asyncio.to_thread(_spotify, query)),
        radio_task)
    mixed: list[PlaylistResult] = [radio] if isinstance(radio, PlaylistResult) else []
    for i in range(max(len(yt), len(dz), len(sp))):
        for source in (yt, dz, sp):
            if i < len(source):
                mixed.append(source[i])
    return mixed
