"""As fontes da rádio. Funções síncronas (rodam em threads pelo guard) que
devolvem só dados simples, para irem ao cache do Redis como JSON.

- YouTube Music: a rádio da própria música (get_watch_playlist radio=True).
- Last.fm: músicas parecidas com nota (track.getSimilar), artistas parecidos
  (artist.getSimilar) e as tags do artista. Precisa de LASTFM_API_KEY.
- Deezer: artistas relacionados e a rádio do artista.
- ListenBrainz: artistas parecidos pelo que as pessoas ouvem (pelo MBID que
  o Last.fm informa).
"""
from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.radio import match
from app.search import deezer, ytmusic
from app.search.models import SearchResult

logger = logging.getLogger("bergastream.radio.sources")

LASTFM_API = "https://ws.audioscrobbler.com/2.0/"
LISTENBRAINZ_SIMILAR = "https://labs.api.listenbrainz.org/similar-artists/json"
LISTENBRAINZ_ALGORITHM = (
    "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30")
_UA = {"User-Agent": "Bergastream/1.0 (self-hosted music server)"}


# ── YouTube Music ────────────────────────────────────────────────

def ytmusic_video_id(seed: SearchResult) -> str | None:
    """O vídeo da música no YT Music (procura se ela veio de outra fonte)."""
    if seed.provider in ("ytmusic", "youtube"):
        return seed.external_id
    want = match.key(seed.artist, seed.title)
    want_artist = match.norm_artist(seed.artist)
    for found in ytmusic.search(f"{seed.artist} {seed.title}", limit=5):
        if match.key(found.artist, found.title) == want:
            return found.external_id
    for found in ytmusic.search(f"{seed.artist} {seed.title}", limit=5):
        if match.norm_artist(found.artist) == want_artist:
            return found.external_id
    return None


def ytmusic_radio(seed: SearchResult) -> dict:
    vid = ytmusic_video_id(seed)
    if not vid:
        return {"tracks": []}
    watch = ytmusic._yt().get_watch_playlist(videoId=vid, radio=True, limit=60)
    tracks = [t for t in (ytmusic.watch_track_from(i) for i in watch.get("tracks") or []) if t]
    # A primeira é a própria música.
    return {"tracks": [t.model_dump() for t in tracks if t.external_id != vid]}


# ── Last.fm ──────────────────────────────────────────────────────

def _lastfm(method: str, **params) -> dict:
    if not settings.lastfm_api_key:
        raise RuntimeError("LASTFM_API_KEY vazio")
    with httpx.Client(timeout=settings.radio_source_timeout, headers=_UA) as cli:
        data = cli.get(LASTFM_API, params={
            "method": method, "api_key": settings.lastfm_api_key, "format": "json",
            "autocorrect": 1, **params}).json()
    if isinstance(data, dict) and data.get("error"):
        raise RuntimeError(f"Last.fm {data.get('error')}: {data.get('message')}")
    return data


def lastfm_similar_tracks(artist: str, title: str) -> dict:
    data = _lastfm("track.getSimilar", artist=artist, track=title, limit=60)
    out = []
    for t in (data.get("similartracks") or {}).get("track") or []:
        name = t.get("name")
        art = (t.get("artist") or {}).get("name")
        if name and art:
            out.append({"artist": art, "title": name, "match": float(t.get("match") or 0),
                        "duration": int(t.get("duration") or 0)})
    return {"tracks": out}


def lastfm_artist(artist: str) -> dict:
    """Artistas parecidos, tags e MBID do artista."""
    similar = _lastfm("artist.getSimilar", artist=artist, limit=80)
    artists = [{"name": a["name"], "match": float(a.get("match") or 0), "mbid": a.get("mbid") or ""}
               for a in (similar.get("similarartists") or {}).get("artist") or [] if a.get("name")]
    attr = (similar.get("similarartists") or {}).get("@attr") or {}
    tags_data = _lastfm("artist.getTopTags", artist=artist)
    tags = [t["name"].lower() for t in (tags_data.get("toptags") or {}).get("tag") or []
            if t.get("name") and int(t.get("count") or 0) >= 10][:15]
    mbid = ""
    try:
        info = _lastfm("artist.getInfo", artist=attr.get("artist") or artist)
        mbid = (info.get("artist") or {}).get("mbid") or ""
    except Exception as exc:  # o MBID só serve ao ListenBrainz
        logger.info("[rádio] sem MBID de %s: %s", artist, exc)
    return {"artists": artists, "tags": tags, "mbid": mbid}


def lastfm_tags(artist: str) -> list[str]:
    data = _lastfm("artist.getTopTags", artist=artist)
    return [t["name"].lower() for t in (data.get("toptags") or {}).get("tag") or []
            if t.get("name") and int(t.get("count") or 0) >= 10][:15]


# ── Deezer ───────────────────────────────────────────────────────

def _deezer_artist_id(seed: SearchResult) -> str | None:
    if seed.provider == "deezer":
        track = deezer.get(f"/track/{seed.external_id}")
        return str((track.get("artist") or {}).get("id") or "") or None
    want = match.norm_artist(seed.artist)
    found = deezer.get("/search", q=f'artist:"{seed.artist}" track:"{seed.title}"', limit=5)
    for t in found.get("data") or []:
        if match.norm_artist((t.get("artist") or {}).get("name", "")) == want:
            return str(t["artist"]["id"])
    artists = deezer.get("/search/artist", q=seed.artist, limit=5)
    for a in artists.get("data") or []:
        if match.norm_artist(a.get("name", "")) == want:
            return str(a["id"])
    return None


def deezer_radio(seed: SearchResult) -> dict:
    artist_id = _deezer_artist_id(seed)
    if not artist_id:
        return {"tracks": [], "artists": []}
    related = deezer.get(f"/artist/{artist_id}/related", limit=50).get("data") or []
    radio = deezer.get(f"/artist/{artist_id}/radio", limit=50).get("data") or []
    return {
        "artists": [a["name"] for a in related if a.get("name")],
        "tracks": [deezer.track_from(t).model_dump() for t in radio
                   if t.get("id") and t.get("readable", True)],
    }


# ── ListenBrainz ─────────────────────────────────────────────────

def listenbrainz_similar(mbid: str) -> dict:
    if not mbid:
        return {"artists": []}
    with httpx.Client(timeout=settings.radio_source_timeout, headers=_UA) as cli:
        resp = cli.get(LISTENBRAINZ_SIMILAR,
                       params={"artist_mbids": mbid, "algorithm": LISTENBRAINZ_ALGORITHM})
        resp.raise_for_status()
        data = resp.json()
    rows: list[dict] = []

    def walk(node):  # o formato do labs muda; pega toda linha com nome e nota
        if isinstance(node, dict):
            if node.get("name") and node.get("score") is not None:
                rows.append(node)
            else:
                for v in node.values():
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(data)
    rows = [r for r in rows if r.get("artist_mbid") != mbid]
    top = max((float(r["score"]) for r in rows), default=0) or 1
    return {"artists": [{"name": r["name"], "match": float(r["score"]) / top} for r in rows[:80]]}


# ── Resolver músicas que vieram só com nome ──────────────────────

def resolve(artist: str, title: str, duration: int = 0) -> dict | None:
    """Acha no YT Music uma música que o Last.fm citou só pelo nome."""
    want = match.key(artist, title)
    want_artist = match.norm_artist(artist)
    for found in ytmusic.search(f"{artist} {title}", limit=5):
        if match.norm_artist(found.artist) != want_artist:
            continue
        if match.key(found.artist, found.title) == want or match.norm_title(title) in match.norm_title(found.title):
            if duration and found.duration_seconds and abs(found.duration_seconds - duration) > 30:
                continue
            return found.model_dump()
    return None
