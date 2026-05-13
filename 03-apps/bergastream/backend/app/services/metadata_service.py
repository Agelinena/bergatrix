"""
Fetches track/album/artist metadata from Deezer, Spotify, and YouTube Music.
Falls back across sources transparently.
"""
import asyncio
import httpx
from app.config import get_settings
from app.schemas.track import TrackSchema, ArtistSchema, AlbumSchema, SearchResponse

settings = get_settings()

DEEZER_API = "https://api.deezer.com"


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
    If duration_ms is provided, only returns a result that matches within 10%.
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
    tolerance = duration_ms * 0.10
    for t in results:
        track_ms = t.get("duration", 0) * 1000
        if abs(track_ms - duration_ms) <= tolerance:
            return str(t["id"])
    return None  # no match within duration tolerance


async def get_deezer_radio(deezer_id: str, limit: int = 10) -> list[TrackSchema]:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{DEEZER_API}/track/{deezer_id}/radio")
    if resp.status_code != 200:
        return []
    data = resp.json()
    if "error" in data or "data" not in data:
        return []
    return [_deezer_track_to_schema(t) for t in data["data"][:limit] if "id" in t and "error" not in t]


async def get_deezer_artist_tracks(deezer_id: str, index: int = 0, limit: int = 100) -> list[TrackSchema]:
    """Returns tracks for an artist via Deezer top endpoint with offset pagination."""
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(
            f"{DEEZER_API}/artist/{deezer_id}/top",
            params={"limit": limit, "index": index},
        )
    if resp.status_code != 200:
        return []
    data = resp.json()
    if "error" in data or "data" not in data:
        return []
    return [_deezer_track_to_schema(t) for t in data["data"] if "id" in t and "error" not in t]


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
