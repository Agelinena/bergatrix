"""
Radio mode: suggests similar tracks using Deezer radio, Spotify recommendations, or Gemini AI.
"""
import asyncio
import json
import logging
import httpx
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.config import get_settings
from app.models.track import Track
from app.services.metadata_service import search_deezer, get_deezer_radio, get_deezer_track, get_deezer_artist_tracks

settings = get_settings()
logger = logging.getLogger(__name__)


class RadioService:
    @staticmethod
    async def get_seeds(track_id: str, source: str, limit: int, db: AsyncSession) -> list[dict]:
        # Get track metadata for title/artist
        result = await db.execute(select(Track).where(Track.id == track_id))
        track = result.scalar_one_or_none()
        title = track.title if track else ""
        artist = track.artist if track else ""
        deezer_source_id = track.source_id if track and track.source == "deezer" else None

        if source == "deezer":
            if not deezer_source_id:
                from app.services.metadata_service import find_deezer_track_id
                deezer_source_id = await find_deezer_track_id(title, artist, track.duration_ms if track else None)
            if not deezer_source_id:
                return []
            return await RadioService._deezer_radio(deezer_source_id, limit)
        if source == "ai":
            return await RadioService._ai_radio(title, artist, limit)
        return []

    @staticmethod
    async def _deezer_radio(deezer_id: str, limit: int) -> list[dict]:
        # Native Deezer radio requires user OAuth — usually returns empty without it.
        # Use it if it works, otherwise fall back to artist top tracks (public endpoint).
        tracks = await get_deezer_radio(deezer_id, limit)
        if tracks:
            logger.info(f"Deezer radio for id={deezer_id}: got {len(tracks)} tracks (native)")
            return [t.model_dump() for t in tracks]

        logger.info(f"Deezer native radio empty for id={deezer_id}, falling back to artist top tracks")
        tracks = await RadioService._artist_top_tracks(deezer_id, limit)
        logger.info(f"Deezer radio fallback: got {len(tracks)} tracks")
        return [t.model_dump() for t in tracks]

    @staticmethod
    async def _artist_top_tracks(deezer_id: str, limit: int):
        """Fetches top tracks for the same artist as the seed track (public endpoint)."""
        seed = await get_deezer_track(deezer_id)
        if not seed or not seed.artist_id:
            return []
        # artist_id is stored as "deezer_<numeric_id>"
        numeric_artist_id = seed.artist_id.replace("deezer_", "")
        all_tracks = await get_deezer_artist_tracks(numeric_artist_id, limit=limit * 2)
        # Exclude the seed track itself
        return [t for t in all_tracks if t.source_id != deezer_id][:limit]

    @staticmethod
    async def _ai_radio(title: str, artist: str, limit: int) -> list[dict]:
        if not settings.gemini_api_key:
            logger.warning("AI radio: gemini_api_key not configured")
            return []
        try:
            prompt = (
                f"Suggest {limit} songs similar to '{title}' by '{artist}'. "
                'Return ONLY a JSON array: [{"title": ..., "artist": ...}]'
            )
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={settings.gemini_api_key}",
                    json={"contents": [{"parts": [{"text": prompt}]}]},
                )
            if resp.status_code != 200:
                logger.warning(f"AI radio: Gemini returned {resp.status_code}: {resp.text[:200]}")
                return []

            text = resp.json()["candidates"][0]["content"]["parts"][0]["text"]
            start = text.find("[")
            end = text.rfind("]") + 1
            suggestions = json.loads(text[start:end])
            logger.info(f"AI radio: Gemini suggested {len(suggestions)} tracks for '{title}' by '{artist}'")

            tracks = []
            async def resolve(item):
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
