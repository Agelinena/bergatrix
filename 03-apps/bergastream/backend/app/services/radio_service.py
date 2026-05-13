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
from app.services.metadata_service import search_deezer, get_deezer_radio

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
                # Track is Spotify-sourced; find its Deezer equivalent
                from app.services.metadata_service import find_deezer_track_id
                deezer_source_id = await find_deezer_track_id(title, artist, track.duration_ms if track else None)
            if not deezer_source_id:
                return []
            return await RadioService._deezer_radio(deezer_source_id, limit)
        if source == "spotify":
            # Spotify /recommendations deprecated Nov 2024 — fall back to Deezer radio
            if not deezer_source_id:
                from app.services.metadata_service import find_deezer_track_id
                deezer_source_id = await find_deezer_track_id(title, artist, track.duration_ms if track else None)
            if deezer_source_id:
                return await RadioService._deezer_radio(deezer_source_id, limit)
            return []
        if source == "ai":
            return await RadioService._ai_radio(title, artist, limit)
        return []

    @staticmethod
    async def _deezer_radio(deezer_id: str, limit: int) -> list[dict]:
        tracks = await get_deezer_radio(deezer_id, limit)
        logger.info(f"Deezer radio for id={deezer_id}: got {len(tracks)} tracks")
        return [t.model_dump() for t in tracks]

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
