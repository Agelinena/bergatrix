"""
Downloads music from Deezer (via deemix) or YouTube (via yt-dlp).
Saves to cache path and optionally moves to permanent.
"""
import asyncio
import os
import shutil
from pathlib import Path
from app.config import get_settings

settings = get_settings()


def _cache_path(track_id: str, ext: str = "mp3") -> Path:
    return Path(settings.music_cache_path) / f"{track_id}.{ext}"


def _permanent_path(track_id: str, ext: str = "mp3") -> Path:
    return Path(settings.music_permanent_path) / f"{track_id}.{ext}"


def _resolve_existing(track_id: str) -> Path | None:
    for base in (settings.music_permanent_path, settings.music_cache_path):
        for ext in ("flac", "mp3"):
            p = Path(base) / f"{track_id}.{ext}"
            if p.exists():
                return p
    return None


async def download_deezer(track_id: str, source_id: str, expected_duration_ms: int | None = None) -> tuple[Path | None, str]:
    """
    Downloads via deemix using the configured ARL token.
    Returns (file_path, audio_quality).
    Verifies downloaded file duration against expected_duration_ms (10% tolerance).
    Returns (None, "") on failure so caller can fall back to yt-dlp.
    """
    if not settings.deemix_arl:
        return None, ""

    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        from deemix import generateDownloadObject
        from deemix.downloader import Downloader
        from deezer import Deezer
        from deemix.settings import DEFAULTS
        import copy

        loop = asyncio.get_event_loop()

        def _download():
            # Snapshot existing files before download so we only pick NEW ones
            pre_existing: set[Path] = set()
            for ext in ("flac", "mp3"):
                pre_existing.update(out_dir.glob(f"**/*.{ext}"))

            dz = Deezer()
            logged = dz.login_via_arl(settings.deemix_arl)
            if not logged:
                return None, ""

            deezer_settings = copy.deepcopy(DEFAULTS)
            deezer_settings["downloadLocation"] = str(out_dir)
            deezer_settings["maxBitrate"] = "9"  # FLAC
            deezer_settings["overwriteFile"] = "y"

            url = f"https://www.deezer.com/track/{source_id}"
            dl_obj = generateDownloadObject(dz, url, deezer_settings["maxBitrate"])
            Downloader(dz, dl_obj, deezer_settings).start()

            # Only consider files that didn't exist before download
            for ext in ("flac", "mp3"):
                new_files = [
                    f for f in out_dir.glob(f"**/*.{ext}")
                    if f not in pre_existing
                ]
                if new_files:
                    new_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
                    return new_files[0], "flac" if ext == "flac" else "mp3_320"
            return None, ""

        result = await loop.run_in_executor(None, _download)
        if result[0]:
            ext = "flac" if result[1] == "flac" else "mp3"
            dest = _cache_path(track_id, ext)
            result[0].rename(dest)

            # Verify duration if expected is provided (10% tolerance)
            if expected_duration_ms and expected_duration_ms > 0:
                try:
                    from mutagen import File as MutagenFile
                    audio = MutagenFile(dest)
                    if audio and audio.info:
                        actual_ms = int(audio.info.length * 1000)
                        if actual_ms == 0:
                            pass  # mutagen couldn't read duration; keep the file
                        else:
                            tolerance = expected_duration_ms * 0.10
                            if abs(actual_ms - expected_duration_ms) > tolerance:
                                import logging
                                logging.getLogger(__name__).warning(
                                    f"deemix duration mismatch for {source_id}: "
                                    f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding"
                                )
                                dest.unlink(missing_ok=True)
                                return None, ""
                except Exception:
                    pass  # mutagen failure is non-fatal; keep the file

            return dest, result[1]
    except Exception as e:
        import logging
        logging.getLogger(__name__).warning(f"deemix error for {source_id}: {e}")

    return None, ""


async def download_youtube(track_id: str, source_id: str, title: str = "", artist: str = "") -> tuple[Path | None, str]:
    """Downloads via yt-dlp. Best available audio converted to MP3 320kbps."""
    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    dest = _cache_path(track_id, "mp3")
    if dest.exists():
        return dest, "mp3_320"

    # Use video ID if available, otherwise search
    if source_id and not source_id.startswith("search:"):
        url = f"https://www.youtube.com/watch?v={source_id}"
    else:
        query = f"{artist} {title}".strip()
        url = f"ytsearch1:{query}"

    # Create a lock file so stream_service knows the file is still being written.
    lock = Path(str(dest) + ".lock")
    lock.touch()

    cmd = [
        "yt-dlp",
        "-f", "bestaudio",
        "-x", "--audio-format", "mp3", "--audio-quality", "0",
        "--no-playlist",
        "-o", str(dest.with_suffix("")),  # yt-dlp appends .mp3
        url,
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=120)
        if proc.returncode != 0:
            return None, ""

        actual = dest if dest.exists() else dest.with_suffix("").with_suffix(".mp3")
        if actual.exists() and actual != dest:
            actual.rename(dest)

        return dest if dest.exists() else None, "mp3_320"
    except (asyncio.TimeoutError, Exception):
        return None, ""
    finally:
        lock.unlink(missing_ok=True)


async def ensure_track_file(track_id: str, source: str, source_id: str, title: str = "", artist: str = "", duration_ms: int | None = None) -> tuple[Path | None, str]:
    """
    Resolves file for a track_id. Returns (path, quality).
    Order: permanent > cache > download.
    """
    existing = _resolve_existing(track_id)
    if existing:
        return existing, ""

    if source == "deezer":
        path, quality = await download_deezer(track_id, source_id, expected_duration_ms=duration_ms)
        if path:
            return path, quality
        # fallback to youtube search (deemix failed or duration mismatch)
        return await download_youtube(track_id, "", title, artist)

    if source == "youtube":
        return await download_youtube(track_id, source_id, title, artist)

    if source == "spotify":
        # Try Deezer first (duration-matched search) for lossless quality
        if settings.deemix_arl and (title or artist):
            from app.services.metadata_service import find_deezer_track_id
            deezer_id = await find_deezer_track_id(title, artist, duration_ms)
            if deezer_id:
                path, quality = await download_deezer(track_id, deezer_id, expected_duration_ms=duration_ms)
                if path:
                    return path, quality
        # Fall back to YouTube search
        return await download_youtube(track_id, "", title, artist)

    return None, ""


async def stream_generator(file_path: Path, chunk_size: int = 65536):
    """Async generator that yields file chunks."""
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            yield chunk


def move_to_permanent(track_id: str) -> Path | None:
    """Moves a cached file to permanent storage."""
    for ext in ("flac", "mp3"):
        src = _cache_path(track_id, ext)
        if src.exists():
            dest = _permanent_path(track_id, ext)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dest))
            return dest
    return None


def delete_file(track_id: str) -> None:
    """Deletes all local files for a track_id."""
    for base in (settings.music_cache_path, settings.music_permanent_path):
        for ext in ("flac", "mp3"):
            p = Path(base) / f"{track_id}.{ext}"
            if p.exists():
                p.unlink()
