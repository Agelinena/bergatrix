"""
Hourly cleanup: deletes expired cache files and removes orphan DB entries.
"""
import asyncio
import logging
from pathlib import Path
from datetime import datetime, timezone
from sqlalchemy import select, delete, and_
from app.config import get_settings
from app.database import AsyncSessionLocal
from app.models.track import Track
from app.models.playlist import PlaylistTrack
from app.models.offline import OfflineTrack
from app.services.downloader_service import delete_file

settings = get_settings()
logger = logging.getLogger(__name__)


class CleanupService:
    @staticmethod
    async def run_once() -> int:
        """Runs one cleanup pass. Returns count of files deleted."""
        deleted = 0
        now = datetime.now(timezone.utc)

        async with AsyncSessionLocal() as db:
            # Find expired cache tracks
            result = await db.execute(
                select(Track).where(
                    and_(
                        Track.is_permanent == False,
                        Track.cache_expires_at <= now,
                        Track.cache_path != None,
                    )
                )
            )
            expired_tracks = result.scalars().all()

            for track in expired_tracks:
                # Only delete if no playlist_tracks or offline_tracks reference it
                in_playlist = await db.execute(
                    select(PlaylistTrack).where(PlaylistTrack.track_id == track.id).limit(1)
                )
                in_offline = await db.execute(
                    select(OfflineTrack).where(OfflineTrack.track_id == track.id).limit(1)
                )

                if in_playlist.first() is None and in_offline.first() is None:
                    delete_file(track.id)
                    track.cache_path = None
                    track.audio_quality = None
                    track.cache_expires_at = None
                    deleted += 1
                    logger.info(f"Cleanup: removed cached file for {track.id}")

            await db.commit()

        # Also sweep orphan files in cache dir not tracked in DB
        await CleanupService._sweep_orphan_files(db)

        return deleted

    @staticmethod
    async def _sweep_orphan_files(db) -> None:
        cache_dir = Path(settings.music_cache_path)
        if not cache_dir.exists():
            return

        async with AsyncSessionLocal() as db:
            for f in cache_dir.iterdir():
                if not f.is_file():
                    continue
                track_id = f.stem
                result = await db.execute(select(Track).where(Track.id == track_id))
                track = result.scalar_one_or_none()
                if track is None:
                    f.unlink()
                    logger.info(f"Cleanup: removed orphan file {f.name}")

    @staticmethod
    async def run_periodic() -> None:
        while True:
            try:
                await asyncio.sleep(3600)  # run hourly
                deleted = await CleanupService.run_once()
                logger.info(f"Cleanup pass complete: {deleted} files removed")
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Cleanup error: {e}")
