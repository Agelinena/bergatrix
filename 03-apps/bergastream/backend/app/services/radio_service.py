"""
Radio mode: suggests similar tracks using Last.fm similarity data or OpenRouter AI.

Performance notes
-----------------
* `_artist_top_tracks` uses Deezer's `/artist/{id}/top` endpoint directly —
  one HTTP call — instead of walking every album of the artist.  Previously
  a single radio request on a prolific artist (e.g. Metallica, DJ Yuzak)
  triggered ~100 Deezer API calls.
* Last.fm / AI suggestions are resolved with `search_deezer_tracks` (one
  HTTP call to `/search`) instead of `search_deezer` (which also fans out
  to `/search/album` and `/search/artist` — wasted requests because radio
  only consumes the tracks bucket).
* Final results are cached in Redis for 1 h, keyed by `(source, seed_id)`.
  The same seed re-played within an hour is served instantly.
"""
import asyncio
import json
import logging
import re
import httpx
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.config import get_settings
from app.models.track import Track
from app.services.metadata_service import (
    get_deezer_radio, get_deezer_track,
    search_deezer_tracks, get_deezer_artist_top,
)

settings = get_settings()
logger = logging.getLogger(__name__)

LASTFM_API = "https://ws.audioscrobbler.com/2.0"
OPENROUTER_API = "https://openrouter.ai/api/v1/chat/completions"

# Cache TTL for radio results in seconds (1 h).
_RADIO_CACHE_TTL = 3600

# Patterns commonly added by streaming platforms that confuse Last.fm matching
_TITLE_NOISE_RE = re.compile(
    r'\s*[\(\[\-]'                      # opening bracket/dash
    r'(?:'
    r'\d{4}\s+remaster(?:ed)?'          # "2020 Remaster" / "2020 Remastered"
    r'|remaster(?:ed)?(?:\s+\d{4})?'   # "Remastered" / "Remastered 2020"
    r'|live(?:\s+at\s+[^)\]]+)?'       # "Live" / "Live at Wembley"
    r'|acoustic(?:\s+version)?'
    r'|radio\s+edit'
    r'|single(?:\s+version)?'
    r'|album\s+version'
    r'|deluxe(?:\s+edition)?'
    r'|bonus\s+track'
    r'|explicit'
    r'|feat\.?[^)\]]*'                  # "feat. ..."
    r')'
    r'[\)\]]?'                          # optional closing bracket
    ,
    re.IGNORECASE,
)


def _clean_title(title: str) -> str:
    """Strip streaming-platform noise from a track title before Last.fm lookup."""
    cleaned = _TITLE_NOISE_RE.sub('', title).strip(' -–—')
    return cleaned or title  # never return empty string


def _cache_key(source: str, track_id: str, limit: int) -> str:
    return f"bergastream:radio:{source}:{track_id}:{limit}"


async def _cache_get(source: str, track_id: str, limit: int) -> list[dict] | None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        raw = await r.get(_cache_key(source, track_id, limit))
        if raw:
            data = json.loads(raw)
            if isinstance(data, list):
                return data
    except Exception as e:
        logger.debug(f"[radio-cache] get error: {e}")
    return None


async def _cache_set(source: str, track_id: str, limit: int, tracks: list[dict]) -> None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        await r.set(
            _cache_key(source, track_id, limit),
            json.dumps(tracks),
            ex=_RADIO_CACHE_TTL,
        )
    except Exception as e:
        logger.debug(f"[radio-cache] set error: {e}")


class RadioService:
    @staticmethod
    async def get_seeds(
        track_id: str, source: str, limit: int, db: AsyncSession,
        title: str = "", artist: str = "",
    ) -> list[dict]:
        # Cache lookup before any network I/O.
        cached = await _cache_get(source, track_id, limit)
        if cached is not None:
            logger.info(f"[radio-cache] HIT source={source} seed={track_id} → {len(cached)} tracks")
            return cached

        # Use caller-supplied metadata first; fall back to DB lookup if missing
        if not title or not artist:
            result = await db.execute(select(Track).where(Track.id == track_id))
            track = result.scalar_one_or_none()
            title = title or (track.title if track else "")
            artist = artist or (track.artist if track else "")
            deezer_source_id = track.source_id if track and track.source == "deezer" else None
        else:
            # Minimal DB lookup just to get deezer_source_id for fallback methods
            result = await db.execute(select(Track).where(Track.id == track_id))
            track = result.scalar_one_or_none()
            deezer_source_id = track.source_id if track and track.source == "deezer" else None

        tracks: list[dict] = []

        if source == "lastfm":
            # Last.fm only needs title+artist — try it first regardless of source
            if settings.lastfm_api_key and title and artist:
                clean = _clean_title(title)
                if clean != title:
                    logger.info(f"Last.fm: cleaned title '{title}' → '{clean}'")
                tracks = await RadioService._lastfm_similar(clean, artist, limit)
                if tracks:
                    logger.info(f"Last.fm similar: got {len(tracks)} tracks for '{clean}' by '{artist}'")
                    await _cache_set(source, track_id, limit, tracks)
                    return tracks
                logger.info(f"Last.fm returned no results for '{clean}' by '{artist}' — falling back to Deezer")

            # Last.fm unavailable or no results — fall back to Deezer-based methods
            if not deezer_source_id:
                try:
                    from app.services.metadata_service import find_deezer_track_id
                    deezer_source_id = await find_deezer_track_id(title, artist, track.duration_ms if track else None)
                except Exception as e:
                    logger.warning(f"find_deezer_track_id failed: {e}")
            if not deezer_source_id:
                return []
            tracks = await RadioService._deezer_fallbacks(deezer_source_id, limit)
            if tracks:
                await _cache_set(source, track_id, limit, tracks)
            return tracks

        if source == "ai":
            tracks = await RadioService._ai_radio(_clean_title(title), artist, limit)
            if tracks:
                await _cache_set(source, track_id, limit, tracks)
            return tracks

        return []

    @staticmethod
    async def _deezer_fallbacks(deezer_id: str, limit: int) -> list[dict]:
        """Deezer-based fallbacks when Last.fm has no results."""
        # 1. Native Deezer radio (requires user OAuth — usually empty without it)
        deezer_tracks = await get_deezer_radio(deezer_id, limit)
        if deezer_tracks:
            logger.info(f"Deezer native radio: got {len(deezer_tracks)} tracks for id={deezer_id}")
            return [t.model_dump() for t in deezer_tracks]

        # 2. Last resort: artist top tracks (always available, 1 HTTP call)
        logger.info(f"Radio fallback to artist top tracks for id={deezer_id}")
        fallback = await RadioService._artist_top_tracks(deezer_id, limit)
        logger.info(f"Artist top tracks fallback: got {len(fallback)} tracks")
        return [t.model_dump() for t in fallback]

    @staticmethod
    async def _lastfm_similar(title: str, artist: str, limit: int) -> list[dict]:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(LASTFM_API, params={
                    "method": "track.getSimilar",
                    "artist": artist,
                    "track": title,
                    "api_key": settings.lastfm_api_key,
                    "limit": min(limit * 2, 50),
                    "format": "json",
                })
            if resp.status_code != 200:
                logger.warning(f"Last.fm returned {resp.status_code}")
                return []

            data = resp.json()
            similar = data.get("similartracks", {}).get("track", [])
            if not similar:
                return []

            # Resolve each suggestion via Deezer TRACK search only (1 HTTP call each
            # instead of 3 — _lastfm_similar previously fanned out to /search,
            # /search/album and /search/artist for every suggestion).
            tracks: list[dict] = []

            async def resolve(item: dict) -> None:
                t_title = item.get("name", "")
                t_artist = item.get("artist", {}).get("name", "")
                if not t_title or not t_artist:
                    return
                results = await search_deezer_tracks(f"{t_artist} {t_title}", 1)
                if results:
                    tracks.append(results[0].model_dump())

            # Overshoot Last.fm fetch to compensate for Deezer resolution failures
            fetch_count = min(limit * 2, 50)
            await asyncio.gather(*[resolve(s) for s in similar[:fetch_count]])
            return tracks[:limit]
        except Exception as e:
            logger.warning(f"Last.fm similar failed: {e}")
            return []

    @staticmethod
    async def _artist_top_tracks(deezer_id: str, limit: int):
        """Returns the artist's top tracks via Deezer's /top endpoint (1 HTTP call)."""
        seed = await get_deezer_track(deezer_id)
        if not seed or not seed.artist_id:
            return []
        numeric_artist_id = seed.artist_id.replace("deezer_", "")
        top = await get_deezer_artist_top(numeric_artist_id, limit=limit * 2)
        return [t for t in top if t.source_id != deezer_id][:limit]

    @staticmethod
    async def _ai_radio(title: str, artist: str, limit: int) -> list[dict]:
        if not settings.openrouter_api_key:
            logger.warning("AI radio: openrouter_api_key not configured")
            return []
        try:
            prompt = (
                f"Suggest {limit} songs similar to '{title}' by '{artist}'. "
                'Return ONLY a JSON array: [{"title": "...", "artist": "..."}]'
            )
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    OPENROUTER_API,
                    headers={
                        "Authorization": f"Bearer {settings.openrouter_api_key}",
                        "HTTP-Referer": f"https://{settings.web_domain}",
                    },
                    json={
                        "model": settings.openrouter_model,
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
            if resp.status_code != 200:
                logger.warning(f"AI radio: OpenRouter returned {resp.status_code}: {resp.text[:200]}")
                return []

            text = resp.json()["choices"][0]["message"]["content"]
            start = text.find("[")
            end = text.rfind("]") + 1
            suggestions = json.loads(text[start:end])
            logger.info(f"AI radio: {settings.openrouter_model} suggested {len(suggestions)} tracks for '{title}' by '{artist}'")

            tracks: list[dict] = []

            async def resolve(item: dict) -> None:
                query = f"{item.get('artist', '')} {item.get('title', '')}"
                results = await search_deezer_tracks(query, 1)
                if results:
                    tracks.append(results[0].model_dump())

            await asyncio.gather(*[resolve(s) for s in suggestions[:limit]])
            logger.info(f"AI radio: resolved {len(tracks)}/{len(suggestions)} tracks via Deezer")
            return tracks
        except Exception as e:
            logger.warning(f"AI radio failed: {e}")
            return []
