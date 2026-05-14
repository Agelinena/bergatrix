"""
Downloads music from Deezer (via deemix) or YouTube (via yt-dlp).

Resolution pipeline for every track:
  1. Existing cached/permanent file  →  return immediately (no download)
  2. Parallel candidate search       →  find best Deezer ID + best YouTube video ID
                                         simultaneously, both duration-verified
  3. Sequential download             →  Deezer preferred (lossless/320),
                                         YouTube as fallback
  4. Post-download verification      →  mutagen duration check on the saved file
  5. Last resort                     →  YouTube unverified first result

Duration tolerance: ±5% or ±10 s, whichever is larger.
"""
import asyncio
import json
import logging
import shutil
from pathlib import Path

from app.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

# Duration matching constants
_DUR_REL = 0.05       # 5% relative tolerance
_DUR_ABS_MS = 10_000  # 10-second absolute floor


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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


def _duration_ok(actual_ms: int, expected_ms: int | None) -> bool:
    """True when actual is within tolerance of expected, or either is unknown."""
    if not expected_ms or expected_ms <= 0 or actual_ms <= 0:
        return True
    tolerance = max(_DUR_ABS_MS, expected_ms * _DUR_REL)
    return abs(actual_ms - expected_ms) <= tolerance


def _file_duration_ms(path: Path) -> int:
    """Duration of an audio file in ms via mutagen. Returns 0 on failure."""
    try:
        from mutagen import File as MutagenFile
        audio = MutagenFile(path)
        if audio and audio.info:
            return int(audio.info.length * 1000)
    except Exception:
        pass
    return 0


# ---------------------------------------------------------------------------
# Phase 1 — Candidate search (no download)
# ---------------------------------------------------------------------------

async def find_deezer_candidate(
    title: str,
    artist: str,
    duration_ms: int | None,
    deezer_source_id: str | None = None,
) -> str | None:
    """
    Returns a verified Deezer track ID for the given track.

    If deezer_source_id is provided (track came from Deezer search), it is
    confirmed with a quick Deezer API duration check. If the duration doesn't
    match, falls through to a fresh Deezer search.
    Otherwise searches Deezer by title+artist and picks the closest-duration match.
    """
    from app.services.metadata_service import find_deezer_track_id, get_deezer_track

    if deezer_source_id:
        if duration_ms:
            try:
                meta = await get_deezer_track(deezer_source_id)
                if meta and meta.duration_ms and meta.duration_ms > 0:
                    if not _duration_ok(meta.duration_ms, duration_ms):
                        logger.warning(
                            f"[resolve] Deezer {deezer_source_id} duration "
                            f"{meta.duration_ms}ms ≠ expected {duration_ms}ms — searching"
                        )
                        deezer_source_id = None
            except Exception as e:
                logger.debug(f"[resolve] Deezer API check skipped ({e}) — using source_id")
        if deezer_source_id:
            logger.info(f"[resolve] Deezer candidate (direct): {deezer_source_id}")
            return deezer_source_id

    if not title and not artist:
        return None

    deezer_id = await find_deezer_track_id(title, artist, duration_ms)
    if deezer_id:
        logger.info(f"[resolve] Deezer candidate (search): {deezer_id}")
    else:
        logger.info(f"[resolve] No Deezer candidate for '{title}' by '{artist}'")
    return deezer_id


async def find_youtube_candidate(
    title: str,
    artist: str,
    duration_ms: int | None,
) -> str | None:
    """
    Uses `yt-dlp --dump-json ytsearch5:…` to find YouTube candidates WITHOUT
    downloading. Filters by duration and returns the closest-match video ID.
    """
    query = f"{artist} {title}".strip()
    if not query:
        return None

    cmd = [
        "yt-dlp",
        "--dump-json",
        "--no-download",
        f"ytsearch5:{query}",
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
    except asyncio.TimeoutError:
        logger.warning(f"[resolve] yt-dlp candidate search timed out for '{query}'")
        return None
    except Exception as e:
        logger.warning(f"[resolve] yt-dlp candidate search error: {e}")
        return None

    candidates: list[dict] = []
    for line in stdout.decode("utf-8", errors="replace").strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            candidates.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not candidates:
        logger.info(f"[resolve] yt-dlp returned no candidates for '{query}'")
        return None

    if not duration_ms or duration_ms <= 0:
        vid = candidates[0].get("id")
        logger.info(f"[resolve] YouTube candidate (no duration constraint): {vid}")
        return vid

    best_id: str | None = None
    best_diff = float("inf")
    for c in candidates:
        vid_ms = (c.get("duration") or 0) * 1000
        if vid_ms <= 0:
            continue
        diff = abs(vid_ms - duration_ms)
        logger.debug(
            f"[resolve] YT {c.get('id')} '{c.get('title')}': "
            f"{vid_ms}ms vs {duration_ms}ms (Δ{diff}ms)"
        )
        if _duration_ok(vid_ms, duration_ms) and diff < best_diff:
            best_id = c.get("id")
            best_diff = diff

    if best_id:
        logger.info(f"[resolve] YouTube candidate (Δ{best_diff:.0f}ms): {best_id}")
    else:
        avail = ", ".join(f"{(c.get('duration') or 0)*1000:.0f}ms" for c in candidates)
        logger.info(
            f"[resolve] No YouTube candidate matched {duration_ms}ms for '{query}' "
            f"(available: {avail})"
        )
    return best_id


# ---------------------------------------------------------------------------
# Phase 2 — Download
# ---------------------------------------------------------------------------

async def download_deezer(
    track_id: str,
    source_id: str,
    expected_duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Downloads via deemix (Deezer FLAC/MP3 320).
    Post-verifies duration with mutagen. Returns (path, quality) or (None, "").
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
            track_tmp = out_dir / f".dl_{source_id}"
            track_tmp.mkdir(exist_ok=True)
            try:
                dz = Deezer()
                if not dz.login_via_arl(settings.deemix_arl):
                    return None, ""
                deezer_settings = copy.deepcopy(DEFAULTS)
                deezer_settings["downloadLocation"] = str(track_tmp)
                deezer_settings["maxBitrate"] = "9"   # FLAC
                deezer_settings["overwriteFile"] = "y"
                url = f"https://www.deezer.com/track/{source_id}"
                dl_obj = generateDownloadObject(dz, url, deezer_settings["maxBitrate"])
                Downloader(dz, dl_obj, deezer_settings).start()
                for ext in ("flac", "mp3"):
                    files = list(track_tmp.rglob(f"*.{ext}"))
                    if files:
                        staged = out_dir / f".staged_{source_id}.{ext}"
                        shutil.move(str(files[0]), str(staged))
                        return staged, "flac" if ext == "flac" else "mp3_320"
                return None, ""
            finally:
                shutil.rmtree(str(track_tmp), ignore_errors=True)

        result = await loop.run_in_executor(None, _download)
        if not result[0]:
            return None, ""

        ext = "flac" if result[1] == "flac" else "mp3"
        dest = _cache_path(track_id, ext)
        result[0].rename(dest)

        # Post-download duration verification
        if expected_duration_ms and expected_duration_ms > 0:
            actual_ms = _file_duration_ms(dest)
            if actual_ms > 0 and not _duration_ok(actual_ms, expected_duration_ms):
                logger.warning(
                    f"[deemix] Duration mismatch Deezer {source_id}: "
                    f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding"
                )
                dest.unlink(missing_ok=True)
                return None, ""

        logger.info(f"[deemix] Downloaded {source_id} → {dest.name}")
        return dest, result[1]

    except Exception as e:
        logger.warning(f"[deemix] Error for {source_id}: {e}")
        return None, ""


async def _youtube_first_result(query: str) -> str | None:
    """Gets the first yt-dlp search result with no duration constraint (last resort)."""
    cmd = ["yt-dlp", "--dump-json", "--no-download", f"ytsearch1:{query}"]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=20)
        lines = stdout.decode("utf-8", errors="replace").strip().splitlines()
        if lines:
            return json.loads(lines[0]).get("id")
    except Exception:
        pass
    return None


async def download_youtube_by_id(
    track_id: str,
    video_id: str,
    expected_duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Downloads a YouTube video by ID via yt-dlp (best audio → MP3 320).
    Creates a .lock file while downloading so stream_service can tail-follow.
    Post-verifies duration with mutagen.
    """
    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    dest = _cache_path(track_id, "mp3")
    if dest.exists():
        return dest, "mp3_320"

    url = f"https://www.youtube.com/watch?v={video_id}"
    lock = Path(str(dest) + ".lock")
    lock.touch()

    cmd = [
        "yt-dlp",
        "-f", "bestaudio",
        "-x", "--audio-format", "mp3", "--audio-quality", "0",
        "--no-playlist",
        "-o", str(dest.with_suffix("")),   # yt-dlp appends .mp3
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
            logger.warning(f"[yt-dlp] Non-zero exit for {video_id}: {stderr.decode()[:200]}")
            return None, ""

        actual = dest if dest.exists() else dest.with_suffix("").with_suffix(".mp3")
        if actual.exists() and actual != dest:
            actual.rename(dest)

        if not dest.exists():
            return None, ""

        # Post-download duration verification
        if expected_duration_ms and expected_duration_ms > 0:
            actual_ms = _file_duration_ms(dest)
            if actual_ms > 0 and not _duration_ok(actual_ms, expected_duration_ms):
                logger.warning(
                    f"[yt-dlp] Duration mismatch {video_id}: "
                    f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding"
                )
                dest.unlink(missing_ok=True)
                return None, ""

        logger.info(f"[yt-dlp] Downloaded {video_id} → {dest.name}")
        return dest, "mp3_320"

    except asyncio.TimeoutError:
        logger.warning(f"[yt-dlp] Timed out for {video_id}")
        return None, ""
    except Exception as e:
        logger.warning(f"[yt-dlp] Error for {video_id}: {e}")
        return None, ""
    finally:
        lock.unlink(missing_ok=True)


async def download_youtube(
    track_id: str,
    source_id: str,
    title: str = "",
    artist: str = "",
    expected_duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Downloads via yt-dlp using a known video ID (source == 'youtube') or by
    searching. Kept for backward compatibility with queue_service worker.
    """
    if source_id and not source_id.startswith("search:"):
        return await download_youtube_by_id(track_id, source_id, expected_duration_ms)

    # Search → duration-matched candidate → download
    video_id = await find_youtube_candidate(title, artist, expected_duration_ms)
    if video_id:
        return await download_youtube_by_id(track_id, video_id, expected_duration_ms)

    # Last resort: first result, no duration check
    if title or artist:
        video_id = await _youtube_first_result(f"{artist} {title}".strip())
        if video_id:
            logger.warning(f"[yt-dlp] Unverified first result for '{title}' by '{artist}'")
            return await download_youtube_by_id(track_id, video_id, None)

    return None, ""


# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------

async def ensure_track_file(
    track_id: str,
    source: str,
    source_id: str,
    title: str = "",
    artist: str = "",
    duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Resolves the audio file for track_id. Returns (path, quality).

    Pipeline:
      1. Return existing permanent/cache file instantly.
      2. Search Deezer and YouTube in parallel (no download yet), both
         duration-filtered to ±5% / ±10 s of the track's expected length.
      3. Download winner: Deezer (lossless) > YouTube (mp3 320).
      4. Post-download mutagen duration check confirms file is correct.
      5. If all verified candidates fail: YouTube unverified last resort.
    """
    existing = _resolve_existing(track_id)
    if existing:
        return existing, ""

    # YouTube-sourced track: caller already holds the correct video ID.
    # Still try Deezer in parallel for a lossless copy.
    if source == "youtube" and source_id:
        logger.info(f"[resolve] YouTube source — trying Deezer equivalent for {track_id}")
        deezer_cand = await find_deezer_candidate(title, artist, duration_ms)
        if deezer_cand and settings.deemix_arl:
            path, quality = await download_deezer(track_id, deezer_cand, duration_ms)
            if path:
                return path, quality
        return await download_youtube_by_id(track_id, source_id, duration_ms)

    # --- Deezer / Spotify / unknown source ---
    deezer_known = source_id if source == "deezer" else None

    logger.info(
        f"[resolve] '{title}' by '{artist}' [{source}/{source_id}] "
        f"duration={duration_ms}ms — parallel candidate search"
    )

    # Phase 1: parallel candidate search (metadata only, no download)
    deezer_cand, youtube_cand = await asyncio.gather(
        find_deezer_candidate(title, artist, duration_ms, deezer_known),
        find_youtube_candidate(title, artist, duration_ms),
        return_exceptions=True,
    )
    if isinstance(deezer_cand, Exception):
        logger.warning(f"[resolve] Deezer candidate error: {deezer_cand}")
        deezer_cand = None
    if isinstance(youtube_cand, Exception):
        logger.warning(f"[resolve] YouTube candidate error: {youtube_cand}")
        youtube_cand = None

    logger.info(f"[resolve] Candidates — Deezer: {deezer_cand}  YouTube: {youtube_cand}")

    # Phase 2: download preferred source, fall back to alternative
    if deezer_cand and settings.deemix_arl:
        path, quality = await download_deezer(track_id, deezer_cand, duration_ms)
        if path:
            return path, quality
        logger.warning("[resolve] Deezer download failed — trying YouTube candidate")

    if youtube_cand:
        path, quality = await download_youtube_by_id(track_id, youtube_cand, duration_ms)
        if path:
            return path, quality
        logger.warning(f"[resolve] YouTube download failed for candidate {youtube_cand}")

    # Phase 3: last resort — YouTube unverified first result
    if title or artist:
        query = f"{artist} {title}".strip()
        logger.warning(f"[resolve] All verified candidates failed — unverified YouTube search: '{query}'")
        video_id = await _youtube_first_result(query)
        if video_id:
            return await download_youtube_by_id(track_id, video_id, None)

    logger.error(f"[resolve] Could not resolve audio for {track_id} ('{title}' by '{artist}')")
    return None, ""


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

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
