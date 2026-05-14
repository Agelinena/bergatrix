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
import re
import shutil
import unicodedata
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
# Title-match helpers for YouTube candidate scoring
# ---------------------------------------------------------------------------

def _normalize_text(s: str) -> str:
    """Lowercase, strip accents, collapse to alphanumeric words."""
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.lower()
    s = re.sub(r"[^\w\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


# Common words that appear in many YouTube titles but carry no identity signal
_STOP_WORDS = {
    "a", "o", "e", "é", "de", "da", "do", "das", "dos", "em", "um", "uma",
    "the", "a", "an", "of", "in", "on", "at", "to", "ft", "feat", "part",
    "official", "video", "music", "audio", "lyric", "lyrics", "clipe",
    "ao", "vivo", "live", "version", "versao",
}


def _content_words(s: str) -> set[str]:
    """Normalised word set with stop words removed."""
    return {w for w in _normalize_text(s).split() if w not in _STOP_WORDS} or \
           set(_normalize_text(s).split())  # fallback: keep all if everything stripped


def _title_match_score(video_title: str, track_title: str, artist: str) -> float:
    """
    Returns 0.0–1.0 measuring how well a YouTube video title matches the
    expected track title + artist.

    Title words contribute 70 %, artist presence 30 %.
    Short titles (1 word) require exact presence; longer titles allow partial.
    """
    vt_words = _content_words(video_title)
    tt_words = _content_words(track_title)

    # Title score: fraction of track title content-words found in video title
    if tt_words:
        title_score = len(tt_words & vt_words) / len(tt_words)
    else:
        title_score = 0.5  # empty title → neutral

    # Artist score: any individual artist's name (from comma-separated list)
    # fully present in the video title → 1.0, partially → 0.5
    artist_score = 0.0
    if artist:
        for part in re.split(r"[,&/]", artist):
            part_words = _content_words(part)
            if not part_words:
                continue
            if part_words <= vt_words:       # all words of this artist found
                artist_score = 1.0
                break
            elif part_words & vt_words:      # at least one word found
                artist_score = max(artist_score, 0.5)

    return round(title_score * 0.7 + artist_score * 0.3, 3)


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
    Uses `yt-dlp --dump-json ytsearch5:…` to find the best YouTube match WITHOUT
    downloading. Scores by title+artist similarity (primary) and duration (secondary).

    Priority buckets (checked in order):
      1. Title match  ✓  AND  Duration match ✓  →  best combined score
      2. Title match  ✓  AND  Duration match ✗  →  acceptable (different version)
      3. Title match  ✗  AND  Duration match ✓  →  risky (coincidental duration)
      4. Nothing matched                         →  first result (last resort)
    """
    _TITLE_THRESHOLD = 0.4   # minimum _title_match_score to count as a title match

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

    # Score every candidate
    scored: list[tuple[float, bool, int, dict]] = []  # (t_score, dur_ok, dur_diff_ms, c)
    for c in candidates:
        vid_ms = (c.get("duration") or 0) * 1000
        t_score = _title_match_score(c.get("title", ""), title, artist)
        dur_ok = _duration_ok(vid_ms, duration_ms) if (duration_ms and duration_ms > 0) else True
        dur_diff = int(abs(vid_ms - (duration_ms or 0)))
        scored.append((t_score, dur_ok, dur_diff, c))
        logger.debug(
            f"[resolve] YT {c.get('id')} '{c.get('title')}': "
            f"title_score={t_score:.2f} dur={vid_ms}ms dur_ok={dur_ok} Δ{dur_diff}ms"
        )

    # Bucket 1: title ✓ + duration ✓  (best score then smallest dur diff)
    perfect = [(s, d, c) for s, ok, d, c in scored if s >= _TITLE_THRESHOLD and ok]
    if perfect:
        best = max(perfect, key=lambda x: (x[0], -x[1]))
        vid = best[2].get("id")
        logger.info(
            f"[resolve] YouTube candidate (title+duration, score={best[0]:.2f} Δ{best[1]}ms): {vid}"
        )
        return vid

    # Bucket 2: title ✓ + duration ✗  (highest title score)
    title_only = [(s, d, c) for s, ok, d, c in scored if s >= _TITLE_THRESHOLD and not ok]
    if title_only:
        best = max(title_only, key=lambda x: x[0])
        vid = best[2].get("id")
        logger.warning(
            f"[resolve] YouTube candidate (title match, duration mismatch Δ{best[1]}ms, "
            f"score={best[0]:.2f}): {vid}"
        )
        return vid

    # Bucket 3: title ✗ + duration ✓  (only if duration filter requested)
    if duration_ms and duration_ms > 0:
        dur_only = [(s, d, c) for s, ok, d, c in scored if s < _TITLE_THRESHOLD and ok]
        if dur_only:
            best = min(dur_only, key=lambda x: x[1])   # smallest duration diff
            vid = best[2].get("id")
            logger.warning(
                f"[resolve] YouTube candidate (duration only, NO title match, "
                f"score={best[0]:.2f} Δ{best[1]}ms) — may be wrong song: {vid}"
            )
            return vid

    # Bucket 4: nothing matched — first result
    vid = candidates[0].get("id")
    logger.warning(
        f"[resolve] YouTube: no match found for '{title}' by '{artist}' — "
        f"using first result (unverified): {vid}"
    )
    return vid


# ---------------------------------------------------------------------------
# Phase 2 — Download
# ---------------------------------------------------------------------------

_deemix_sidecar_lock: asyncio.Lock | None = None


def _get_deemix_lock() -> asyncio.Lock:
    global _deemix_sidecar_lock
    if _deemix_sidecar_lock is None:
        _deemix_sidecar_lock = asyncio.Lock()
    return _deemix_sidecar_lock


async def _deemix_emit(source_id: str) -> bool:
    """
    Triggers a deemix download by speaking the Socket.IO 2.x / Engine.IO 3
    (EIO=3) protocol directly over WebSocket via aiohttp.

    python-socketio 5.x sends EIO=4 which the deemix Node.js server (Socket.IO
    2.x) rejects with an empty error.  Using aiohttp WebSocket we can force
    EIO=3 without any version mismatch.

    Protocol (EIO=3 direct-WebSocket — no prior polling upgrade needed):
      ← server sends  "0{handshake_json}"    (Engine.IO OPEN)
      → client sends  "40"                   (Socket.IO CONNECT on namespace /)
      ← server sends  "40"                   (Socket.IO CONNECT ack)
      → client sends  '42["addToQueue",{…}]' (Socket.IO EVENT)
    """
    import aiohttp as _aiohttp

    base = settings.deemix_url.rstrip("/")
    # http(s):// → ws(s)://
    ws_url = re.sub(r"^http", "ws", base) + "/socket.io/?EIO=3&transport=websocket"
    deezer_url = f"https://www.deezer.com/track/{source_id}"

    try:
        timeout = _aiohttp.ClientTimeout(total=15)
        async with _aiohttp.ClientSession(timeout=timeout) as _sess:
            async with _sess.ws_connect(ws_url, heartbeat=None) as _ws:

                # ── receive Engine.IO OPEN ────────────────────────────────
                _msg = await asyncio.wait_for(_ws.receive(), timeout=5)
                if _msg.type != _aiohttp.WSMsgType.TEXT or not _msg.data.startswith("0"):
                    raise ValueError(f"Unexpected EIO packet: {_msg.data[:80]!r}")
                logger.debug(f"[deemix] EIO handshake ok (sid fragment: {_msg.data[2:20]}…)")

                # ── Socket.IO CONNECT to default namespace ────────────────
                await _ws.send_str("40")

                # wait for server's namespace-connect ack
                try:
                    _ack = await asyncio.wait_for(_ws.receive(), timeout=3)
                    logger.debug(f"[deemix] namespace ack: {_ack.data[:40]!r}")
                except asyncio.TimeoutError:
                    logger.debug("[deemix] no namespace ack received — proceeding")

                # ── emit addToQueue ───────────────────────────────────────
                event_pkt = f'42{json.dumps(["addToQueue", {"url": deezer_url}])}'
                await _ws.send_str(event_pkt)
                logger.debug(f"[deemix] sent: {event_pkt[:80]}")

                await asyncio.sleep(0.5)  # allow server to enqueue
                await _ws.close()

        logger.info(f"[deemix] Queued {source_id} via Socket.IO 2.x / EIO=3 WebSocket")
        return True

    except Exception as _e:
        logger.warning(f"[deemix] Socket.IO error for {source_id}: {_e}")
        return False


async def download_deezer(
    track_id: str,
    source_id: str,
    expected_duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Downloads from Deezer via the deemix sidecar container (Socket.IO 2.x).

    Triggers download via _deemix_emit(), then polls the shared volume for
    the new audio file.  Serialised with a lock so file identification by
    creation-time is unambiguous.
    """
    if not settings.deemix_url or not settings.deemix_downloads_path:
        logger.debug("[deemix] Skipped — DEEMIX_URL or DEEMIX_DOWNLOADS_PATH not configured")
        return None, ""

    downloads_dir = Path(settings.deemix_downloads_path)
    if not downloads_dir.exists():
        logger.warning(f"[deemix] Shared downloads dir not found: {downloads_dir}")
        return None, ""

    import time as _time

    async with _get_deemix_lock():
        trigger_time = _time.time() - 0.5   # small buffer for clock skew

        if not await _deemix_emit(source_id):
            return None, ""

        # Poll shared volume for the new file (lock guarantees it's ours)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 90
        while loop.time() < deadline:
            for candidate in downloads_dir.rglob("*"):
                if not candidate.is_file():
                    continue
                if candidate.suffix.lower() not in (".mp3", ".flac"):
                    continue
                try:
                    stat = candidate.stat()
                    if stat.st_ctime >= trigger_time and stat.st_size > 50_000:
                        ext = candidate.suffix.lower().lstrip(".")
                        dest = _cache_path(track_id, ext)
                        shutil.move(str(candidate), str(dest))

                        # Post-download duration check
                        if expected_duration_ms and expected_duration_ms > 0:
                            actual_ms = _file_duration_ms(dest)
                            if actual_ms > 0 and not _duration_ok(actual_ms, expected_duration_ms):
                                logger.warning(
                                    f"[deemix] Duration mismatch {source_id}: "
                                    f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding"
                                )
                                dest.unlink(missing_ok=True)
                                return None, ""

                        quality = "flac" if ext == "flac" else "mp3_320"
                        logger.info(f"[deemix] Downloaded {source_id} → {dest.name} ({quality})")
                        return dest, quality
                except Exception:
                    continue

            await asyncio.sleep(0.5)

        logger.warning(f"[deemix] Timed out waiting for {source_id}")
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
        if deezer_cand and settings.deemix_url:
            path, quality = await download_deezer(track_id, deezer_cand, duration_ms)
            if path:
                return path, quality
        return await download_youtube_by_id(track_id, source_id, duration_ms)

    # --- Deezer / Spotify / unknown source ---
    deezer_known = source_id if source == "deezer" else None

    logger.info(
        f"[resolve] '{title}' by '{artist}' [{source}/{source_id}] "
        f"duration={duration_ms}ms — sequential candidate search"
    )

    # Phase 1a: Deezer candidate search + download (no yt-dlp subprocess yet)
    if settings.deemix_url:
        try:
            deezer_cand = await find_deezer_candidate(title, artist, duration_ms, deezer_known)
        except Exception as e:
            logger.warning(f"[resolve] Deezer candidate error: {e}")
            deezer_cand = None

        if deezer_cand:
            path, quality = await download_deezer(track_id, deezer_cand, duration_ms)
            if path:
                return path, quality
            logger.warning("[resolve] Deezer download failed — falling back to YouTube")

    # Phase 1b: YouTube candidate search (only runs if Deezer unavailable or failed)
    try:
        youtube_cand = await find_youtube_candidate(title, artist, duration_ms)
    except Exception as e:
        logger.warning(f"[resolve] YouTube candidate error: {e}")
        youtube_cand = None

    logger.info(f"[resolve] YouTube candidate: {youtube_cand}")

    if youtube_cand:
        path, quality = await download_youtube_by_id(track_id, youtube_cand, duration_ms)
        if path:
            return path, quality
        logger.warning(f"[resolve] YouTube download failed for candidate {youtube_cand}")

    # Phase 2: last resort — YouTube unverified first result
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
