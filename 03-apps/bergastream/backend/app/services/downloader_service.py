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


async def download_deezer(track_id: str, source_id: str) -> tuple[Path | None, str]:
    """
    Downloads via deemix using the configured ARL token.
    Returns (file_path, audio_quality).
    Falls back to yt-dlp search if deemix fails.
    """
    if not settings.deemix_arl:
        return None, ""

    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        from deemix import generateDownloadObject
        from deemix.downloader import Downloader
        from deezer import Deezer
        from deemix.settings import read as read_settings

        loop = asyncio.get_event_loop()

        def _download():
            dz = Deezer()
            dz.login_via_arl(settings.deemix_arl)
            deezer_settings = read_settings()
            deezer_settings["downloadLocation"] = str(out_dir)
            deezer_settings["maxBitrate"] = "9"  # FLAC
            url = f"https://www.deezer.com/track/{source_id}"
            dl_obj = generateDownloadObject(dz, url, deezer_settings["maxBitrate"])
            Downloader(dz, dl_obj, deezer_settings).start()

            # Find downloaded file
            for ext in ("flac", "mp3"):
                for f in out_dir.glob(f"*{source_id}*.{ext}"):
                    return f, "flac" if ext == "flac" else "mp3_320"
            return None, ""

        result = await loop.run_in_executor(None, _download)
        if result[0]:
            dest = _cache_path(track_id, "flac" if result[1] == "flac" else "mp3")
            result[0].rename(dest)
            return dest, result[1]
    except Exception:
        pass

    return None, ""


async def download_youtube(track_id: str, source_id: str, title: str = "", artist: str = "") -> tuple[Path | None, str]:
    """Downloads via yt-dlp. Always produces mp3 128kbps."""
    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    dest = _cache_path(track_id, "mp3")
    if dest.exists():
        return dest, "mp3_128"

    # Use video ID if available, otherwise search
    if source_id and not source_id.startswith("search:"):
        url = f"https://www.youtube.com/watch?v={source_id}"
    else:
        query = f"{artist} {title}".strip()
        url = f"ytsearch1:{query}"

    cmd = [
        "yt-dlp",
        "-x", "--audio-format", "mp3", "--audio-quality", "128K",
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

        # yt-dlp may append .mp3 extension
        actual = dest if dest.exists() else dest.with_suffix("").with_suffix(".mp3")
        if actual.exists() and actual != dest:
            actual.rename(dest)

        return dest if dest.exists() else None, "mp3_128"
    except (asyncio.TimeoutError, Exception):
        return None, ""


async def ensure_track_file(track_id: str, source: str, source_id: str, title: str = "", artist: str = "") -> tuple[Path | None, str]:
    """
    Resolves file for a track_id. Returns (path, quality).
    Order: permanent > cache > download.
    """
    existing = _resolve_existing(track_id)
    if existing:
        return existing, ""

    if source == "deezer":
        path, quality = await download_deezer(track_id, source_id)
        if path:
            return path, quality
        # fallback to youtube search
        return await download_youtube(track_id, "", title, artist)

    if source in ("youtube", "spotify"):
        return await download_youtube(track_id, source_id, title, artist)

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
