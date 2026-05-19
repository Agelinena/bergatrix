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


def _norm_artist(name: str) -> str:
    """Lowercase + collapse whitespace.  Used to detect "same artist" across
    minor formatting differences ("Jota.pê" vs "jota.pê", "MC RN Original"
    vs "Mc RN Original")."""
    return re.sub(r"\s+", " ", (name or "").strip().lower())


def _artist_search_variants(artist: str) -> list[str]:
    """
    Return a list of artist strings to try against Last.fm, in priority order.

    Last.fm doesn't recognise comma-joined collaborator strings as a single
    artist — sending "Halestorm, I Prevail" returns 0 matches, but
    "Halestorm" alone returns 50.  When the input contains separators,
    yield the full string first (in case it IS a known act), then each
    component artist in order.

    Examples:
      "Halestorm, I Prevail"        → ["Halestorm, I Prevail", "Halestorm", "I Prevail"]
      "DJ YUZAK, MC BN, Mc RN Original"
                                    → [full, "DJ YUZAK", "MC BN", "Mc RN Original"]
      "Jota.pê"                     → ["Jota.pê"]
    """
    artist = (artist or "").strip()
    if not artist:
        return []
    variants: list[str] = [artist]
    parts = [p.strip() for p in re.split(r"[,&/]| feat\.? | ft\.? ", artist) if p.strip()]
    for p in parts:
        if p not in variants:
            variants.append(p)
    return variants


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
        """
        Build a diversified radio queue using Last.fm.

        Algorithm:
          1. Call track.getSimilar for global track suggestions.  When the
             artist field has multiple comma-separated names (e.g.
             "Halestorm, I Prevail"), we also try the FIRST name alone —
             Last.fm doesn't index combined-artist strings.
          2. For tracks with little data, Last.fm tends to return many tracks
             by the SAME seed artist.  We cap that at MAX_SAME_ARTIST.
          3. If the result is still too homogeneous (too many seed-artist
             tracks, or too few unique artists), supplement with
             artist.getSimilar → top track of each similar artist.

        All sub-tasks use `return_exceptions=True` so one failing resolve
        doesn't blow up the whole radio response.
        """
        MAX_SAME_ARTIST = 2          # at most 2 tracks by seed artist
        MAX_PER_OTHER_ARTIST = 2     # at most 2 tracks by any single other artist
        MIN_UNIQUE_ARTISTS = max(3, limit // 3)  # require some artist diversity

        # Last.fm doesn't recognise comma-joined collaborator strings as a
        # single artist.  Try each variant in order and use whichever gives
        # results.  This is the difference between getting 0 vs 50 similar
        # tracks for "Halestorm, I Prevail" — Last.fm only knows "Halestorm".
        artist_variants = _artist_search_variants(artist)
        seed_artist_norm = _norm_artist(artist)

        try:
            similar: list[dict] = []
            similar_artist_used = artist
            for variant in artist_variants:
                similar = await RadioService._lastfm_track_similar(title, variant, limit * 3)
                if similar:
                    similar_artist_used = variant
                    break

            # For the supplement pool, also try variants.
            artist_similar_pool: list[str] = []
            for variant in artist_variants:
                artist_similar_pool = await RadioService._lastfm_artist_similar_pool(variant)
                if artist_similar_pool:
                    break

            logger.info(
                f"[radio] Last.fm track.getSimilar returned {len(similar)} suggestions "
                f"for '{title}' by '{similar_artist_used}' "
                f"(variants tried: {artist_variants})"
            )

            # First pass: track.getSimilar suggestions, diversity-filtered
            tracks_by_artist: dict[str, list[dict]] = {}
            seed_artist_count = 0

            async def resolve(item: dict) -> dict | None:
                try:
                    t_title = item.get("name", "")
                    t_artist = item.get("artist", {}).get("name", "")
                    if not t_title or not t_artist:
                        return None
                    results = await search_deezer_tracks(f"{t_artist} {t_title}", 1)
                    if not results:
                        return None
                    return results[0].model_dump()
                except Exception as e:
                    logger.debug(f"[radio] resolve failed for {item.get('name')}: {e}")
                    return None

            resolved_results = await asyncio.gather(
                *[resolve(s) for s in similar[:min(len(similar), 50)]],
                return_exceptions=True,
            )

            picked: list[dict] = []
            for t in resolved_results:
                if t is None or isinstance(t, Exception):
                    continue
                a_norm = _norm_artist(t.get("artist", ""))
                if not a_norm:
                    continue

                # Diversity gates
                if a_norm == seed_artist_norm:
                    if seed_artist_count >= MAX_SAME_ARTIST:
                        continue
                    seed_artist_count += 1
                else:
                    bucket = tracks_by_artist.setdefault(a_norm, [])
                    if len(bucket) >= MAX_PER_OTHER_ARTIST:
                        continue
                    bucket.append(t)

                picked.append(t)
                if len(picked) >= limit:
                    break

            unique_artists = len(tracks_by_artist) + (1 if seed_artist_count else 0)
            logger.info(
                f"[radio] After diversity filter: {len(picked)} tracks, "
                f"{unique_artists} unique artists "
                f"(seed_artist_used={seed_artist_count}/{MAX_SAME_ARTIST})"
            )

            need_more = (
                len(picked) < limit
                or unique_artists < MIN_UNIQUE_ARTISTS
            )

            if need_more and artist_similar_pool:
                logger.info(
                    f"[radio] Supplementing with artist.getSimilar "
                    f"({len(artist_similar_pool)} similar artists available)"
                )
                # For each similar artist, pull their TOP track via Deezer search.
                used_artists = set(tracks_by_artist.keys())
                if seed_artist_count:
                    used_artists.add(seed_artist_norm)

                async def resolve_artist(artist_name: str) -> dict | None:
                    try:
                        if _norm_artist(artist_name) in used_artists:
                            return None
                        results = await search_deezer_tracks(artist_name, 1)
                        if not results:
                            return None
                        return results[0].model_dump()
                    except Exception as e:
                        logger.debug(f"[radio] resolve_artist failed for {artist_name}: {e}")
                        return None

                supplement_results = await asyncio.gather(
                    *[resolve_artist(a) for a in artist_similar_pool[:limit * 2]],
                    return_exceptions=True,
                )
                for t in supplement_results:
                    if t is None or isinstance(t, Exception):
                        continue
                    a_norm = _norm_artist(t.get("artist", ""))
                    if not a_norm or a_norm in used_artists:
                        continue
                    used_artists.add(a_norm)
                    picked.append(t)
                    if len(picked) >= limit:
                        break

                logger.info(
                    f"[radio] After artist.getSimilar supplement: {len(picked)} tracks"
                )

            return picked[:limit]
        except Exception as e:
            logger.warning(
                f"Last.fm similar failed: {type(e).__name__}: {e}",
                exc_info=True,
            )
            return []

    @staticmethod
    async def _lastfm_track_similar(title: str, artist: str, limit: int) -> list[dict]:
        """One call to Last.fm track.getSimilar.  Returns the raw similar-track list."""
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(LASTFM_API, params={
                "method": "track.getSimilar",
                "artist": artist,
                "track": title,
                "api_key": settings.lastfm_api_key,
                "limit": min(limit, 50),
                "format": "json",
            })
        if resp.status_code != 200:
            logger.warning(f"Last.fm track.getSimilar returned {resp.status_code}")
            return []
        return resp.json().get("similartracks", {}).get("track", []) or []

    @staticmethod
    async def _lastfm_artist_similar_pool(artist: str) -> list[str]:
        """Names of similar artists via Last.fm artist.getSimilar (used as supplement)."""
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(LASTFM_API, params={
                    "method": "artist.getSimilar",
                    "artist": artist,
                    "api_key": settings.lastfm_api_key,
                    "limit": 30,
                    "format": "json",
                })
            if resp.status_code != 200:
                return []
            data = resp.json().get("similarartists", {}).get("artist", []) or []
            return [a.get("name", "") for a in data if a.get("name")]
        except Exception as e:
            logger.debug(f"artist.getSimilar failed: {e}")
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
