"""
Radio mode: suggests similar tracks using Last.fm similarity data or OpenRouter AI.
"""
import asyncio
import json
import logging
import httpx
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.config import get_settings
from app.models.track import Track
from app.services.metadata_service import (
    search_deezer, get_deezer_radio,
    get_deezer_track, get_deezer_artist_tracks,
)

settings = get_settings()
logger = logging.getLogger(__name__)

LASTFM_API = "https://ws.audioscrobbler.com/2.0"
OPENROUTER_API = "https://openrouter.ai/api/v1/chat/completions"


class RadioService:
    @staticmethod
    async def get_seeds(track_id: str, source: str, limit: int, db: AsyncSession) -> list[dict]:
        result = await db.execute(select(Track).where(Track.id == track_id))
        track = result.scalar_one_or_none()
        title = track.title if track else ""
        artist = track.artist if track else ""
        deezer_source_id = track.source_id if track and track.source == "deezer" else None

        if source == "lastfm":
            # Last.fm only needs title+artist — try it first regardless of source
            if settings.lastfm_api_key and title and artist:
                tracks = await RadioService._lastfm_similar(title, artist, limit)
                if tracks:
                    logger.info(f"Last.fm similar: got {len(tracks)} tracks for '{title}' by '{artist}'")
                    return tracks
                logger.info(f"Last.fm returned no results for '{title}' by '{artist}' — falling back to Deezer")

            # Last.fm unavailable or no results — fall back to Deezer-based methods
            if not deezer_source_id:
                try:
                    from app.services.metadata_service import find_deezer_track_id
                    deezer_source_id = await find_deezer_track_id(title, artist, track.duration_ms if track else None)
                except Exception as e:
                    logger.warning(f"find_deezer_track_id failed: {e}")
            if not deezer_source_id:
                return []
            return await RadioService._deezer_fallbacks(deezer_source_id, limit)
        if source == "ai":
            return await RadioService._ai_radio(title, artist, limit)
        return []

    @staticmethod
    async def _deezer_fallbacks(deezer_id: str, limit: int) -> list[dict]:
        """Deezer-based fallbacks when Last.fm has no results."""
        # 1. Native Deezer radio (requires user OAuth — usually empty without it)
        deezer_tracks = await get_deezer_radio(deezer_id, limit)
        if deezer_tracks:
            logger.info(f"Deezer native radio: got {len(deezer_tracks)} tracks for id={deezer_id}")
            return [t.model_dump() for t in deezer_tracks]

        # 2. Last resort: artist top tracks (always available)
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

            # Resolve each suggestion via Deezer search to get full track metadata
            tracks: list[dict] = []

            async def resolve(item: dict) -> None:
                t_title = item.get("name", "")
                t_artist = item.get("artist", {}).get("name", "")
                if not t_title or not t_artist:
                    return
                results = await search_deezer(f"{t_artist} {t_title}", 1)
                if results.tracks:
                    tracks.append(results.tracks[0].model_dump())

            # Overshoot Last.fm fetch to compensate for Deezer resolution failures
            fetch_count = min(limit * 2, 50)
            await asyncio.gather(*[resolve(s) for s in similar[:fetch_count]])
            return tracks[:limit]
        except Exception as e:
            logger.warning(f"Last.fm similar failed: {e}")
            return []

    @staticmethod
    async def _artist_top_tracks(deezer_id: str, limit: int):
        seed = await get_deezer_track(deezer_id)
        if not seed or not seed.artist_id:
            return []
        numeric_artist_id = seed.artist_id.replace("deezer_", "")
        all_tracks = await get_deezer_artist_tracks(numeric_artist_id, limit=limit * 2)
        return [t for t in all_tracks if t.source_id != deezer_id][:limit]

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
                results = await search_deezer(query, 1)
                if results.tracks:
                    tracks.append(results.tracks[0].model_dump())

            await asyncio.gather(*[resolve(s) for s in suggestions[:limit]])
            logger.info(f"AI radio: resolved {len(tracks)}/{len(suggestions)} tracks via Deezer")
            return tracks
        except Exception as e:
            logger.warning(f"AI radio failed: {e}")
            return []
