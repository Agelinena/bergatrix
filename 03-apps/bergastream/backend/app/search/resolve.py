"""Resolução de links (Spotify, Deezer, YouTube/YT Music) em faixa, álbum ou
playlist com as faixas, para tocar e importar.

Uso: GET /api/resolve?url=...
"""
from __future__ import annotations

import asyncio
import html
import logging
import re
from dataclasses import dataclass
from urllib.parse import parse_qs, urlparse

import httpx
from pydantic import BaseModel

from app.search import deezer, spotify, ytmusic
from app.search.models import SearchResult

logger = logging.getLogger("bergastream.search.resolve")

# Limite de faixas lidas de um link (uma playlist do Spotify tem no máximo
# 10.000). Antes era 500 e playlists maiores chegavam cortadas.
MAX_TRACKS = 10_000


class ResolvedLink(BaseModel):
    source: str  # spotify | deezer | youtube
    kind: str  # track | album | playlist
    title: str
    subtitle: str = ""  # artista do álbum ou dono da playlist
    cover_url: str | None = None
    description: str = ""  # da playlist original (importar com os dados)
    total: int = 0
    tracks: list[SearchResult] = []
    external_url: str


class UnsupportedLink(Exception):
    """Não é um link de faixa, álbum ou playlist que sabemos ler."""


class LinkNotFound(Exception):
    """Link válido, mas o conteúdo não existe ou é privado."""


@dataclass(frozen=True)
class ParsedLink:
    source: str
    kind: str
    id: str
    music: bool = False  # music.youtube.com


_SPOTIFY_RE = re.compile(r"open\.spotify\.com/(?:intl-[\w-]+/)?(track|album|playlist)/([A-Za-z0-9]+)")
_SPOTIFY_URI_RE = re.compile(r"^spotify:(track|album|playlist):([A-Za-z0-9]+)$")
_DEEZER_RE = re.compile(r"deezer\.com/(?:[a-z]{2}(?:-[a-z]{2})?/)?(track|album|playlist)/(\d+)")
_YT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def clean_description(text: str | None) -> str:
    """Descrição da origem como texto simples (o Spotify manda HTML escapado
    e links), no limite de 500 caracteres das playlists."""
    if not text:
        return ""
    plain = re.sub(r"<[^>]+>", "", html.unescape(text))
    return re.sub(r"\s+", " ", plain).strip()[:500]


def parse_link(url: str) -> ParsedLink | None:
    """Reconhece o link sem acessar a rede. Links curtos do Deezer precisam
    ser seguidos antes (ver [resolve])."""
    url = url.strip()
    if m := _SPOTIFY_URI_RE.match(url):
        return ParsedLink("spotify", m.group(1), m.group(2))
    if m := _SPOTIFY_RE.search(url):
        return ParsedLink("spotify", m.group(1), m.group(2))
    if m := _DEEZER_RE.search(url):
        return ParsedLink("deezer", m.group(1), m.group(2))

    parsed = urlparse(url if "://" in url else f"https://{url}")
    host = (parsed.hostname or "").lower().removeprefix("www.").removeprefix("m.")
    query = parse_qs(parsed.query)
    music = host == "music.youtube.com"
    if host == "youtu.be":
        vid = parsed.path.strip("/").split("/")[0]
        return ParsedLink("youtube", "track", vid) if _YT_ID_RE.match(vid) else None
    if host in ("youtube.com", "music.youtube.com"):
        path = parsed.path.rstrip("/")
        if path.startswith("/browse/MPREb_"):
            return ParsedLink("youtube", "album", path.split("/")[-1], music=True)
        if path.startswith("/shorts/"):
            vid = path.split("/")[-1]
            return ParsedLink("youtube", "track", vid, music) if _YT_ID_RE.match(vid) else None
        if path == "/watch" and query.get("v") and _YT_ID_RE.match(query["v"][0]):
            return ParsedLink("youtube", "track", query["v"][0], music)
        if path == "/playlist" and query.get("list"):
            return ParsedLink("youtube", "playlist", query["list"][0], music)
    return None


async def resolve(url: str) -> ResolvedLink:
    link = parse_link(url)
    if link is None and re.search(r"(deezer\.page\.link|link\.deezer\.com)/", url):
        link = parse_link(await _follow_redirects(url))
    if link is None:
        raise UnsupportedLink(url)
    try:
        if link.source == "spotify":
            return await asyncio.to_thread(_resolve_spotify, link)
        if link.source == "deezer":
            return await _resolve_deezer(link)
        return await asyncio.to_thread(_resolve_youtube, link)
    except (UnsupportedLink, LinkNotFound):
        raise
    except Exception as exc:
        logger.warning("[resolve] %s falhou: %s", url, exc)
        raise LinkNotFound(url) from exc


async def _follow_redirects(url: str) -> str:
    async with httpx.AsyncClient(follow_redirects=True, timeout=10) as cli:
        r = await cli.get(url if "://" in url else f"https://{url}")
        return str(r.url)


# ── Spotify ──────────────────────────────────────────────────────

def _resolve_spotify(link: ParsedLink) -> ResolvedLink:
    sp = spotify.client()
    if sp is None:
        raise LinkNotFound("Spotify sem credenciais")
    external = f"https://open.spotify.com/{link.kind}/{link.id}"

    if link.kind == "track":
        t = spotify.track_from(sp.track(link.id))
        return ResolvedLink(source="spotify", kind="track", title=t.title, subtitle=t.artist,
                            cover_url=t.cover_url, total=1, tracks=[t], external_url=external)

    if link.kind == "album":
        album = sp.album(link.id)
        ids: list[str] = []
        page = album["tracks"]
        while page and len(ids) < MAX_TRACKS:
            ids += [i["id"] for i in page["items"] if i and i.get("id")]
            page = sp.next(page) if page.get("next") else None
        # Faixas de álbum vêm sem ISRC; busca as completas em lotes de 50.
        tracks: list[SearchResult] = []
        for start in range(0, len(ids), 50):
            for full in sp.tracks(ids[start:start + 50])["tracks"]:
                if full:
                    tracks.append(spotify.track_from(full, album))
        return ResolvedLink(
            source="spotify", kind="album", title=album.get("name", ""),
            subtitle=", ".join(a["name"] for a in album.get("artists", [])),
            cover_url=spotify._image(album.get("images")),
            total=album.get("total_tracks", len(tracks)), tracks=tracks, external_url=external)

    playlist = sp.playlist(link.id, fields="name,description,owner(display_name),images,tracks(total)")
    tracks = []
    page = sp.playlist_items(link.id, limit=100, additional_types=("track",))
    while page and len(tracks) < MAX_TRACKS:
        for item in page["items"]:
            t = (item or {}).get("track")
            if t and t.get("id") and t.get("type") == "track":
                tracks.append(spotify.track_from(t))
        page = sp.next(page) if page.get("next") else None
    return ResolvedLink(
        source="spotify", kind="playlist", title=playlist.get("name", ""),
        subtitle=(playlist.get("owner") or {}).get("display_name") or "",
        cover_url=spotify._image(playlist.get("images")),
        description=clean_description(playlist.get("description")),
        total=(playlist.get("tracks") or {}).get("total", len(tracks)),
        tracks=tracks[:MAX_TRACKS], external_url=external)


# ── Deezer (API pública) ─────────────────────────────────────────

async def _resolve_deezer(link: ParsedLink) -> ResolvedLink:
    external = f"https://www.deezer.com/{link.kind}/{link.id}"
    async with httpx.AsyncClient(base_url="https://api.deezer.com", timeout=15) as cli:
        async def get(path: str) -> dict:
            data = (await cli.get(path)).json()
            if isinstance(data, dict) and data.get("error"):
                raise LinkNotFound(external)
            return data

        data = await get(f"/{link.kind}/{link.id}")
        if link.kind == "track":
            t = deezer.track_from(data)
            return ResolvedLink(source="deezer", kind="track", title=t.title, subtitle=t.artist,
                                cover_url=t.cover_url, total=1, tracks=[t], external_url=external)

        items = list((data.get("tracks") or {}).get("data") or [])
        next_url = (data.get("tracks") or {}).get("next")
        while next_url and len(items) < MAX_TRACKS:
            page = (await cli.get(next_url)).json()
            items += page.get("data") or []
            next_url = page.get("next")
        album = data if link.kind == "album" else None
        tracks = [deezer.track_from(i, album) for i in items[:MAX_TRACKS] if i.get("id")]
        return ResolvedLink(
            source="deezer", kind=link.kind, title=data.get("title", ""),
            subtitle=((data.get("artist") or data.get("creator")) or {}).get("name", ""),
            cover_url=data.get("cover_xl") or data.get("picture_xl"),
            description=clean_description(data.get("description")),
            total=data.get("nb_tracks", len(tracks)), tracks=tracks, external_url=external)


# ── YouTube / YT Music ───────────────────────────────────────────

def _resolve_youtube(link: ParsedLink) -> ResolvedLink:
    yt = ytmusic._yt()
    host = "music.youtube.com" if link.music else "www.youtube.com"

    if link.kind == "track":
        details = (yt.get_song(link.id) or {}).get("videoDetails") or {}
        if not details:
            raise LinkNotFound(link.id)
        t = SearchResult(
            provider="ytmusic" if link.music else "youtube", external_id=link.id,
            title=details.get("title", ""), artist=details.get("author", ""),
            duration_seconds=int(details.get("lengthSeconds") or 0),
            cover_url=ytmusic.thumbnail((details.get("thumbnail") or {}).get("thumbnails")),
        )
        return ResolvedLink(source="youtube", kind="track", title=t.title, subtitle=t.artist,
                            cover_url=t.cover_url, total=1, tracks=[t],
                            external_url=f"https://{host}/watch?v={link.id}")

    if link.kind == "album":
        album = yt.get_album(link.id)
        cover = ytmusic.thumbnail(album.get("thumbnails"))
        tracks = [t for t in (ytmusic.track_from(i, album.get("title", ""), cover)
                              for i in album.get("tracks") or []) if t]
        return ResolvedLink(
            source="youtube", kind="album", title=album.get("title", ""),
            subtitle=", ".join(a["name"] for a in album.get("artists") or [] if a.get("name")),
            cover_url=cover, total=len(tracks), tracks=tracks[:MAX_TRACKS],
            external_url=f"https://music.youtube.com/browse/{link.id}")

    if link.id.startswith("RD") and not link.id.startswith("RDCLAK"):
        # Rádio (de artista ou de música): lista "infinita", sem página de
        # playlist; vem pelo get_watch_playlist.
        watch = yt.get_watch_playlist(playlistId=link.id, limit=100)
        tracks = [t for t in (ytmusic.watch_track_from(i) for i in watch.get("tracks") or []) if t]
        if not tracks:
            raise LinkNotFound(link.id)
        first_artist = tracks[0].artist.split(",")[0].strip()
        return ResolvedLink(
            source="youtube", kind="playlist", title=f"Rádio {first_artist}",
            subtitle="YouTube Music", cover_url=tracks[0].cover_url,
            description="Músicas do artista e parecidas, escolhidas pelo YouTube Music.",
            total=len(tracks), tracks=tracks,
            external_url=f"https://music.youtube.com/playlist?list={link.id}")

    playlist = yt.get_playlist(link.id, limit=MAX_TRACKS)
    tracks = [t for t in (ytmusic.track_from(i) for i in playlist.get("tracks") or []) if t]
    author = playlist.get("author")
    return ResolvedLink(
        source="youtube", kind="playlist", title=playlist.get("title", ""),
        subtitle=author.get("name", "") if isinstance(author, dict) else (author or ""),
        cover_url=ytmusic.thumbnail(playlist.get("thumbnails")),
        description=clean_description(playlist.get("description")),
        total=playlist.get("trackCount") or len(tracks), tracks=tracks[:MAX_TRACKS],
        external_url=f"https://{host}/playlist?list={link.id}")
