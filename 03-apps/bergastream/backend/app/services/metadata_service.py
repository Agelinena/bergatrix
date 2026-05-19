"""
Fetches track/album/artist metadata from Deezer, Spotify, and YouTube Music.
Falls back across sources transparently.
"""
import asyncio
import hashlib
import json
import logging
import httpx
from app.config import get_settings
from app.schemas.track import TrackSchema, ArtistSchema, AlbumSchema, SearchResponse

settings = get_settings()
logger = logging.getLogger(__name__)

DEEZER_API = "https://api.deezer.com"

# search_deezer_tracks results cached in Redis (24 h TTL).
_DEEZER_SEARCH_TTL = 24 * 3600


async def _search_cache_get(query: str, limit: int) -> list[TrackSchema] | None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        digest = hashlib.sha1(f"{query.lower().strip()}|{limit}".encode("utf-8")).hexdigest()[:16]
        raw = await r.get(f"bergastream:deezer_search:{digest}")
        if not raw:
            return None
        data = json.loads(raw)
        return [TrackSchema(**d) for d in data]
    except Exception as e:
        logger.debug(f"[deezer-search-cache] get error: {e}")
        return None


async def _search_cache_set(query: str, limit: int, tracks: list[TrackSchema]) -> None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        digest = hashlib.sha1(f"{query.lower().strip()}|{limit}".encode("utf-8")).hexdigest()[:16]
        payload = json.dumps([t.model_dump() for t in tracks])
        await r.set(f"bergastream:deezer_search:{digest}", payload, ex=_DEEZER_SEARCH_TTL)
    except Exception as e:
        logger.debug(f"[deezer-search-cache] set error: {e}")


def _deezer_track_to_schema(t: dict) -> TrackSchema:
    return TrackSchema(
        id=f"deezer_{t['id']}",
        title=t.get("title", ""),
        artist=t.get("artist", {}).get("name", ""),
        album=t.get("album", {}).get("title"),
        album_id=f"deezer_{t['album']['id']}" if t.get("album") else None,
        artist_id=f"deezer_{t['artist']['id']}" if t.get("artist") else None,
        duration_ms=t.get("duration", 0) * 1000,
        year=None,
        cover_url=t.get("album", {}).get("cover_xl") or t.get("album", {}).get("cover_medium"),
        source="deezer",
        source_id=str(t["id"]),
        is_permanent=False,
        audio_quality=None,
    )


def _deezer_album_to_schema(a: dict) -> AlbumSchema:
    return AlbumSchema(
        id=f"deezer_{a['id']}",
        title=a.get("title", ""),
        artist=a.get("artist", {}).get("name", ""),
        cover_url=a.get("cover_xl") or a.get("cover_medium"),
        year=a.get("release_date", "")[:4] if a.get("release_date") else None,
        nb_tracks=a.get("nb_tracks"),
        source="deezer",
    )


def _deezer_artist_to_schema(a: dict) -> ArtistSchema:
    return ArtistSchema(
        id=f"deezer_{a['id']}",
        name=a.get("name", ""),
        picture_url=a.get("picture_xl") or a.get("picture_medium"),
        nb_fan=a.get("nb_fan"),
        source="deezer",
    )


async def search_deezer(query: str, limit: int = 20) -> SearchResponse:
    async with httpx.AsyncClient(timeout=10) as client:
        results = await asyncio.gather(
            client.get(f"{DEEZER_API}/search", params={"q": query, "limit": limit}),
            client.get(f"{DEEZER_API}/search/album", params={"q": query, "limit": 10}),
            client.get(f"{DEEZER_API}/search/artist", params={"q": query, "limit": 10}),
            return_exceptions=True,
        )

    tracks, albums, artists = [], [], []

    if not isinstance(results[0], Exception) and results[0].status_code == 200:
        data = results[0].json().get("data", [])
        tracks = [_deezer_track_to_schema(t) for t in data]

    if not isinstance(results[1], Exception) and results[1].status_code == 200:
        data = results[1].json().get("data", [])
        albums = [_deezer_album_to_schema(a) for a in data]

    if not isinstance(results[2], Exception) and results[2].status_code == 200:
        data = results[2].json().get("data", [])
        artists = [_deezer_artist_to_schema(a) for a in data]

    return SearchResponse(tracks=tracks, albums=albums, artists=artists)


async def get_deezer_track(deezer_id: str) -> TrackSchema | None:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/track/{deezer_id}")
    if resp.status_code != 200:
        return None
    return _deezer_track_to_schema(resp.json())


async def get_deezer_album(deezer_id: str) -> tuple[AlbumSchema | None, list[TrackSchema]]:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/album/{deezer_id}")
    if resp.status_code != 200:
        return None, []
    data = resp.json()
    if "error" in data or "id" not in data:
        return None, []
    album = _deezer_album_to_schema(data)
    tracks = [_deezer_track_to_schema(t) for t in data.get("tracks", {}).get("data", [])]
    return album, tracks


async def get_deezer_artist(deezer_id: str) -> tuple[ArtistSchema | None, list[AlbumSchema], list[TrackSchema]]:
    async with httpx.AsyncClient(timeout=10) as client:
        artist_resp, albums_resp, top_resp = await asyncio.gather(
            client.get(f"{DEEZER_API}/artist/{deezer_id}"),
            client.get(f"{DEEZER_API}/artist/{deezer_id}/albums"),
            client.get(f"{DEEZER_API}/artist/{deezer_id}/top", params={"limit": 10}),
        )
    if artist_resp.status_code != 200:
        return None, [], []
    artist_data = artist_resp.json()
    if "error" in artist_data or "id" not in artist_data:
        return None, [], []
    artist = _deezer_artist_to_schema(artist_data)
    albums = []
    if albums_resp.status_code == 200:
        albums = [
            _deezer_album_to_schema(a)
            for a in albums_resp.json().get("data", [])
            if "id" in a and "error" not in a
        ]
    top_tracks = []
    if top_resp.status_code == 200:
        top_tracks = [
            _deezer_track_to_schema(t)
            for t in top_resp.json().get("data", [])
            if "id" in t and "error" not in t
        ]
    return artist, albums, top_tracks


async def get_album_for_spotify_id(spotify_id: str) -> tuple[AlbumSchema | None, list[TrackSchema]]:
    """Fetches Spotify album name, finds Deezer equivalent, returns Deezer profile."""
    if not settings.spotipy_client_id or not settings.spotipy_client_secret:
        return None, []
    try:
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials
        sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
            client_id=settings.spotipy_client_id,
            client_secret=settings.spotipy_client_secret,
        ))
        loop = asyncio.get_event_loop()
        data = await loop.run_in_executor(None, lambda: sp.album(spotify_id))
        title = data.get("name", "")
        artist = data.get("artists", [{}])[0].get("name", "") if data.get("artists") else ""
        if not title:
            return None, []
        query = f"{artist} {title}".strip()
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{DEEZER_API}/search/album", params={"q": query, "limit": 5})
        if resp.status_code != 200:
            return None, []
        results = [a for a in resp.json().get("data", []) if "id" in a]
        if not results:
            return None, []
        return await get_deezer_album(str(results[0]["id"]))
    except Exception:
        return None, []


async def get_artist_for_spotify_id(spotify_id: str) -> tuple[ArtistSchema | None, list[AlbumSchema], list[TrackSchema]]:
    """Fetches Spotify artist name, finds Deezer equivalent, returns Deezer profile."""
    if not settings.spotipy_client_id or not settings.spotipy_client_secret:
        return None, [], []
    try:
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials
        sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
            client_id=settings.spotipy_client_id,
            client_secret=settings.spotipy_client_secret,
        ))
        loop = asyncio.get_event_loop()
        data = await loop.run_in_executor(None, lambda: sp.artist(spotify_id))
        name = data.get("name", "")
        if not name:
            return None, [], []
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{DEEZER_API}/search/artist", params={"q": name, "limit": 5})
        if resp.status_code != 200:
            return None, [], []
        results = [a for a in resp.json().get("data", []) if "id" in a]
        if not results:
            return None, [], []
        return await get_deezer_artist(str(results[0]["id"]))
    except Exception:
        return None, [], []


async def find_deezer_track_id(title: str, artist: str, duration_ms: int | None = None) -> str | None:
    """
    Searches Deezer for title+artist and returns the best-matching track ID.
    If duration_ms is provided, picks the closest-duration result within tolerance
    (±5% or ±10 s, whichever is larger).
    Returns None if no suitable match is found.
    """
    query = f"{artist} {title}".strip()
    if not query:
        return None
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/search", params={"q": query, "limit": 20})
    if resp.status_code != 200:
        return None
    results = resp.json().get("data", [])
    if not results:
        return None
    if not duration_ms or duration_ms <= 0:
        return str(results[0]["id"])
    tolerance = max(10_000, duration_ms * 0.05)  # ±5% or ±10 s floor
    best_id: str | None = None
    best_diff = float("inf")
    for t in results:
        track_ms = t.get("duration", 0) * 1000
        if track_ms <= 0:
            continue
        diff = abs(track_ms - duration_ms)
        if diff <= tolerance and diff < best_diff:
            best_id = str(t["id"])
            best_diff = diff
    return best_id


async def get_deezer_radio(deezer_id: str, limit: int = 10) -> list[TrackSchema]:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/track/{deezer_id}/radio")
    if resp.status_code != 200:
        return []
    data = resp.json()
    if "error" in data or "data" not in data:
        return []
    return [_deezer_track_to_schema(t) for t in data["data"][:limit] if "id" in t and "error" not in t]


async def search_deezer_tracks(query: str, limit: int = 1) -> list[TrackSchema]:
    """
    Lightweight track-only search.  One HTTP call to /search, returns TrackSchemas.
    Used by radio resolvers that don't need album/artist results.

    Results cached in Redis (24 h TTL) — drastically speeds up repeated
    radio refills on the same Last.fm / AI suggestion pools.
    """
    if not query.strip():
        return []

    cached = await _search_cache_get(query, limit)
    if cached is not None:
        return cached

    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/search", params={"q": query, "limit": limit})
    if resp.status_code != 200:
        return []
    data = resp.json().get("data", [])
    tracks = [_deezer_track_to_schema(t) for t in data if "id" in t and "error" not in t]
    if tracks:
        await _search_cache_set(query, limit, tracks)
    return tracks


async def get_deezer_artist_top(deezer_id: str, limit: int = 50) -> list[TrackSchema]:
    """
    One HTTP call to /artist/{id}/top.  Used by the radio "artist top tracks"
    fallback, which previously iterated every album of the artist (~100
    requests for a prolific artist).
    """
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{DEEZER_API}/artist/{deezer_id}/top", params={"limit": limit},
        )
    if resp.status_code != 200:
        return []
    data = resp.json()
    if "error" in data:
        return []
    return [
        _deezer_track_to_schema(t)
        for t in data.get("data", [])
        if "id" in t and "error" not in t
    ]


async def get_deezer_artist_tracks(deezer_id: str, index: int = 0, limit: int = 100) -> tuple[list[TrackSchema], bool]:
    """Returns ALL tracks of an artist by iterating through their albums.
    The index/limit params are kept for API compatibility but all tracks are
    returned on the first call (index=0); subsequent calls return empty + has_more=False.

    Dedupes both the URL pagination cursor AND the album IDs themselves —
    Deezer occasionally returns the same album across pages, which previously
    caused N redundant `/album/{id}` requests.
    """
    if index > 0:
        # Everything was already returned on the first call
        return [], False

    # ── 1. Collect all albums (paginate via 'next', dedupe by album id) ────
    all_albums: list[dict] = []
    seen_album_ids: set[int] = set()
    async with httpx.AsyncClient(timeout=30) as client:
        next_url: str | None = f"{DEEZER_API}/artist/{deezer_id}/albums"
        seen_urls: set[str] = set()
        first = True
        while next_url and len(seen_urls) < 50:
            if next_url in seen_urls:
                break
            seen_urls.add(next_url)
            resp = await client.get(next_url, params={"limit": 100} if first else {})
            first = False
            if resp.status_code != 200:
                break
            data = resp.json()
            if "error" in data:
                break
            for alb in data.get("data", []):
                aid = alb.get("id")
                if aid and aid not in seen_album_ids:
                    seen_album_ids.add(aid)
                    all_albums.append(alb)
            next_url = data.get("next")

    if not all_albums:
        # Fallback: top tracks (at least something)
        return await get_deezer_artist_top(deezer_id, limit=100), False

    # ── 2. Fetch tracks from each album in parallel (batches of 10) ───────
    seen_ids: set[int] = set()
    all_tracks: list[TrackSchema] = []

    async def _album_tracks(client: httpx.AsyncClient, album: dict) -> list[dict]:
        album_id = album.get("id")
        if not album_id:
            return []
        r = await client.get(f"{DEEZER_API}/album/{album_id}")
        if r.status_code != 200:
            return []
        d = r.json()
        if "error" in d:
            return []
        raw = d.get("tracks", {}).get("data", [])
        # Inject album cover so _deezer_track_to_schema has artwork
        for t in raw:
            t.setdefault("album", {
                "id": album_id,
                "title": album.get("title", ""),
                "cover_xl": album.get("cover_xl"),
                "cover_medium": album.get("cover_medium"),
            })
        return raw

    BATCH = 10
    async with httpx.AsyncClient(timeout=30) as client:
        for i in range(0, len(all_albums), BATCH):
            batch = all_albums[i : i + BATCH]
            results = await asyncio.gather(*[_album_tracks(client, a) for a in batch])
            for raw_tracks in results:
                for t in raw_tracks:
                    tid = t.get("id")
                    if tid and tid not in seen_ids and "error" not in t:
                        seen_ids.add(tid)
                        all_tracks.append(_deezer_track_to_schema(t))

    return all_tracks, False


async def search_spotify(query: str, limit: int = 20) -> SearchResponse:
    """Searches Spotify. Returns empty if credentials not configured."""
    if not settings.spotipy_client_id or not settings.spotipy_client_secret:
        return SearchResponse(tracks=[], albums=[], artists=[])

    try:
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials

        sp = spotipy.Spotify(
            auth_manager=SpotifyClientCredentials(
                client_id=settings.spotipy_client_id,
                client_secret=settings.spotipy_client_secret,
            )
        )

        loop = asyncio.get_event_loop()
        results = await loop.run_in_executor(None, lambda: sp.search(q=query, limit=limit, type="track,album,artist"))

        tracks = [_spotify_track(t) for t in results.get("tracks", {}).get("items", [])]
        albums = [_spotify_album(a) for a in results.get("albums", {}).get("items", [])]
        artists = [_spotify_artist(a) for a in results.get("artists", {}).get("items", [])]
        return SearchResponse(tracks=tracks, albums=albums, artists=artists)
    except Exception:
        return SearchResponse(tracks=[], albums=[], artists=[])


def _spotify_track(t: dict) -> TrackSchema:
    return TrackSchema(
        id=f"spotify_{t['id']}",
        title=t.get("name", ""),
        artist=", ".join(a["name"] for a in t.get("artists", [])),
        album=t.get("album", {}).get("name"),
        album_id=f"spotify_{t['album']['id']}" if t.get("album") else None,
        artist_id=f"spotify_{t['artists'][0]['id']}" if t.get("artists") else None,
        duration_ms=t.get("duration_ms"),
        year=t.get("album", {}).get("release_date", "")[:4] if t.get("album") else None,
        cover_url=t.get("album", {}).get("images", [{}])[0].get("url") if t.get("album", {}).get("images") else None,
        source="spotify",
        source_id=t["id"],
        is_permanent=False,
        audio_quality=None,
    )


def _spotify_album(a: dict) -> AlbumSchema:
    return AlbumSchema(
        id=f"spotify_{a['id']}",
        title=a.get("name", ""),
        artist=", ".join(art["name"] for art in a.get("artists", [])),
        cover_url=a.get("images", [{}])[0].get("url") if a.get("images") else None,
        year=a.get("release_date", "")[:4] if a.get("release_date") else None,
        nb_tracks=a.get("total_tracks"),
        source="spotify",
    )


def _spotify_artist(a: dict) -> ArtistSchema:
    return ArtistSchema(
        id=f"spotify_{a['id']}",
        name=a.get("name", ""),
        picture_url=a.get("images", [{}])[0].get("url") if a.get("images") else None,
        nb_fan=a.get("followers", {}).get("total"),
        source="spotify",
    )


async def search_youtube(query: str, limit: int = 20) -> SearchResponse:
    try:
        from ytmusicapi import YTMusic
        loop = asyncio.get_event_loop()
        yt = YTMusic()
        results = await loop.run_in_executor(None, lambda: yt.search(query, limit=limit))

        tracks = []
        for r in results:
            if r.get("resultType") == "song":
                tracks.append(TrackSchema(
                    id=f"youtube_{r['videoId']}",
                    title=r.get("title", ""),
                    artist=r.get("artists", [{}])[0].get("name", "") if r.get("artists") else "",
                    album=r.get("album", {}).get("name") if r.get("album") else None,
                    album_id=None,
                    artist_id=None,
                    duration_ms=r.get("duration_seconds", 0) * 1000 if r.get("duration_seconds") else None,
                    year=None,
                    cover_url=r.get("thumbnails", [{}])[-1].get("url") if r.get("thumbnails") else None,
                    source="youtube",
                    source_id=r.get("videoId"),
                    is_permanent=False,
                    audio_quality="mp3_128",
                ))
        return SearchResponse(tracks=tracks, albums=[], artists=[])
    except Exception:
        return SearchResponse(tracks=[], albums=[], artists=[])


async def search_all(query: str, limit: int = 20) -> SearchResponse:
    deezer, spotify, youtube = await asyncio.gather(
        search_deezer(query, limit),
        search_spotify(query, limit),
        search_youtube(query, limit),
        return_exceptions=True,
    )

    def safe(r, empty):
        return r if not isinstance(r, Exception) else empty

    empty = SearchResponse(tracks=[], albums=[], artists=[])
    d = safe(deezer, empty)
    s = safe(spotify, empty)
    y = safe(youtube, empty)

    return SearchResponse(
        tracks=d.tracks + s.tracks + y.tracks,
        albums=d.albums + s.albums,
        artists=d.artists + s.artists,
    )


# ── URL resolution ─────────────────────────────────────────────────────────────

import re as _re


def _parse_track_url(url: str) -> tuple[str, str] | None:
    """Returns (platform, id) from a track URL, or None if not recognised."""
    # Spotify track
    m = _re.search(r'open\.spotify\.com/(?:[a-z-]+/)?track/([A-Za-z0-9]+)', url)
    if m:
        return ("spotify", m.group(1))

    # Deezer track
    m = _re.search(r'deezer\.com/(?:[a-z]+/)?track/(\d+)', url)
    if m:
        return ("deezer", m.group(1))

    # YouTube full URL
    m = _re.search(r'youtube\.com/watch\?.*?v=([A-Za-z0-9_-]{11})', url)
    if m:
        return ("youtube", m.group(1))

    # youtu.be short URL
    m = _re.search(r'youtu\.be/([A-Za-z0-9_-]{11})', url)
    if m:
        return ("youtube", m.group(1))

    return None


def _parse_playlist_url(url: str) -> tuple[str, str] | None:
    """Returns (platform, id) from a playlist URL, or None if not recognised."""
    # Spotify playlist
    m = _re.search(r'open\.spotify\.com/(?:[a-z-]+/)?playlist/([A-Za-z0-9]+)', url)
    if m:
        return ("spotify", m.group(1))

    # Deezer playlist
    m = _re.search(r'deezer\.com/(?:[a-z]+/)?playlist/(\d+)', url)
    if m:
        return ("deezer", m.group(1))

    # YouTube playlist
    m = _re.search(r'youtube\.com/playlist\?.*?list=([A-Za-z0-9_-]+)', url)
    if m:
        return ("youtube", m.group(1))

    return None


async def get_spotify_track(spotify_id: str) -> TrackSchema | None:
    """Fetch a single Spotify track by its raw ID."""
    if not settings.spotipy_client_id or not settings.spotipy_client_secret:
        return None
    try:
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials
        sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
            client_id=settings.spotipy_client_id,
            client_secret=settings.spotipy_client_secret,
        ))
        loop = asyncio.get_event_loop()
        t = await loop.run_in_executor(None, lambda: sp.track(spotify_id))
        return _spotify_track(t)
    except Exception:
        return None


async def get_youtube_track(video_id: str) -> TrackSchema | None:
    """Fetch a YouTube video as a TrackSchema via YTMusic."""
    try:
        from ytmusicapi import YTMusic
        loop = asyncio.get_event_loop()
        yt = YTMusic()
        song = await loop.run_in_executor(None, lambda: yt.get_song(video_id))
        vd = song.get("videoDetails", {})
        thumb = vd.get("thumbnail", {}).get("thumbnails", [])
        cover = thumb[-1].get("url") if thumb else None
        duration_sec = int(vd.get("lengthSeconds", 0))
        return TrackSchema(
            id=f"youtube_{video_id}",
            title=vd.get("title", ""),
            artist=vd.get("author", ""),
            album=None,
            album_id=None,
            artist_id=None,
            duration_ms=duration_sec * 1000 if duration_sec else None,
            year=None,
            cover_url=cover,
            source="youtube",
            source_id=video_id,
            is_permanent=False,
            audio_quality="mp3_128",
        )
    except Exception:
        return None


async def resolve_track_url(url: str) -> TrackSchema | None:
    """Resolve a Spotify / Deezer / YouTube track URL to a TrackSchema.

    For Spotify links: fetches Spotify metadata, then immediately looks up the
    Deezer equivalent by title+artist+duration so the returned track has a
    deezer_XXXX id — giving the downloader a direct Deezer ID instead of having
    to guess via a text search at play time.
    """
    parsed = _parse_track_url(url)
    if parsed is None:
        return None
    platform, track_id = parsed

    if platform == "deezer":
        return await get_deezer_track(track_id)

    if platform == "spotify":
        spotify_track = await get_spotify_track(track_id)
        if spotify_track is None:
            return None
        # Try to resolve to a Deezer track for reliable download
        deezer_id = await find_deezer_track_id(
            spotify_track.title,
            spotify_track.artist,
            spotify_track.duration_ms,
        )
        if deezer_id:
            deezer_track = await get_deezer_track(deezer_id)
            if deezer_track:
                return deezer_track
        # Fallback: return Spotify metadata as-is
        return spotify_track

    if platform == "youtube":
        return await get_youtube_track(track_id)

    return None


async def get_deezer_playlist(deezer_id: str) -> tuple[str, list[TrackSchema]] | None:
    """Fetch a public Deezer playlist by ID, paginando todas as faixas via campo 'next'."""
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(f"{DEEZER_API}/playlist/{deezer_id}")
        if resp.status_code != 200:
            return None
        data = resp.json()
        if "error" in data:
            return None
        name = data.get("title", "Playlist")
        tracks_block = data.get("tracks", {})
        all_raw: list[dict] = list(tracks_block.get("data", []))

        # Pagina enquanto houver campo "next"
        next_url: str | None = tracks_block.get("next")
        while next_url:
            page_resp = await client.get(next_url)
            if page_resp.status_code != 200:
                break
            page = page_resp.json()
            if "error" in page:
                break
            all_raw.extend(page.get("data", []))
            next_url = page.get("next")

    return name, [_deezer_track_to_schema(t) for t in all_raw if "id" in t and "error" not in t]


async def _isrc_to_deezer(isrc: str) -> TrackSchema | None:
    """
    Resolve a track by ISRC (International Standard Recording Code) on Deezer.
    ISRC is a universal recording identifier shared across platforms — this gives
    an exact match with no text-search ambiguity.
    Returns None if Deezer doesn't have the ISRC.
    """
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            resp = await client.get(f"{DEEZER_API}/track/isrc:{isrc}")
        if resp.status_code != 200:
            return None
        data = resp.json()
        if "error" in data or "id" not in data:
            return None
        return _deezer_track_to_schema(data)
    except Exception:
        return None


async def _resolve_spotify_track_to_deezer(t: dict) -> TrackSchema:
    """
    Convert a raw Spotify track dict to a Deezer TrackSchema using ISRC lookup.
    Falls back to keeping the Spotify metadata if Deezer doesn't have the track.
    """
    isrc = t.get("external_ids", {}).get("isrc")
    if isrc:
        deezer = await _isrc_to_deezer(isrc)
        if deezer:
            return deezer
    # Fallback: return Spotify metadata as-is (downloader will text-search Deezer later)
    return _spotify_track(t)


async def get_spotify_playlist(spotify_id: str) -> tuple[str, list[TrackSchema]] | None:
    """Fetch a Spotify playlist by ID, paginando todas as faixas. Returns (name, tracks).

    Each Spotify track is resolved to its Deezer equivalent via ISRC lookup so that
    the downloader uses a direct Deezer ID instead of a potentially-ambiguous text search.
    """
    if not settings.spotipy_client_id or not settings.spotipy_client_secret:
        return None
    try:
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials
        sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
            client_id=settings.spotipy_client_id,
            client_secret=settings.spotipy_client_secret,
        ))
        loop = asyncio.get_event_loop()

        # Nome da playlist
        pl = await loop.run_in_executor(None, lambda: sp.playlist(spotify_id, fields="name"))
        name = pl.get("name", "Playlist")

        # 1. Coleta todas as faixas Spotify com paginação completa
        raw_tracks: list[dict] = []
        page = await loop.run_in_executor(None, lambda: sp.playlist_tracks(spotify_id))
        while page:
            for item in page.get("items", []):
                t = item.get("track")
                if t and t.get("id") and not t.get("is_local", False):
                    raw_tracks.append(t)
            if page.get("next"):
                page = await loop.run_in_executor(None, lambda p=page: sp.next(p))
            else:
                break

        # 2. Resolve cada faixa para Deezer via ISRC em lotes de 20
        #    (ISRC = código universal → match exato, sem ambiguidade de busca por texto)
        BATCH = 20
        tracks: list[TrackSchema] = []
        for i in range(0, len(raw_tracks), BATCH):
            batch = raw_tracks[i: i + BATCH]
            results = await asyncio.gather(
                *[_resolve_spotify_track_to_deezer(t) for t in batch],
                return_exceptions=True,
            )
            for t, result in zip(batch, results):
                if isinstance(result, TrackSchema):
                    tracks.append(result)
                else:
                    tracks.append(_spotify_track(t))  # fallback on error

        return name, tracks
    except Exception:
        return None


async def get_youtube_playlist(yt_id: str) -> tuple[str, list[TrackSchema]] | None:
    """Fetch a YouTube playlist by ID using YTMusic."""
    try:
        from ytmusicapi import YTMusic
        loop = asyncio.get_event_loop()
        yt = YTMusic()
        pl = await loop.run_in_executor(None, lambda: yt.get_playlist(yt_id, limit=None))
        name = pl.get("title", "Playlist")
        tracks = []
        for t in pl.get("tracks", []):
            vid_id = t.get("videoId")
            if not vid_id:
                continue
            thumb = t.get("thumbnails", [])
            cover = thumb[-1].get("url") if thumb else None
            duration_ms = t.get("duration_seconds", 0) * 1000 if t.get("duration_seconds") else None
            tracks.append(TrackSchema(
                id=f"youtube_{vid_id}",
                title=t.get("title", ""),
                artist=t.get("artists", [{}])[0].get("name", "") if t.get("artists") else "",
                album=t.get("album", {}).get("name") if t.get("album") else None,
                album_id=None, artist_id=None,
                duration_ms=duration_ms, year=None, cover_url=cover,
                source="youtube", source_id=vid_id,
                is_permanent=False, audio_quality="mp3_128",
            ))
        return name, tracks
    except Exception:
        return None


async def resolve_playlist_url(url: str) -> tuple[str, list[TrackSchema]] | None:
    """Resolve a Spotify / Deezer / YouTube playlist URL to (name, tracks)."""
    parsed = _parse_playlist_url(url)
    if parsed is None:
        return None
    platform, pl_id = parsed
    if platform == "deezer":
        return await get_deezer_playlist(pl_id)
    if platform == "spotify":
        return await get_spotify_playlist(pl_id)
    if platform == "youtube":
        return await get_youtube_playlist(pl_id)
    return None
