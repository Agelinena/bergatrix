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

Candidate caching
-----------------
Successful candidate lookups (Deezer ID, YouTube video ID) are cached in Redis
with a 24 h TTL keyed by `(title, artist, duration_bucket)`.  This lets retried
or re-played tracks skip the search phase entirely.

Deemix follow-mode
------------------
When a deemix download starts producing a file in the shared volume, we create
a hardlink at the cache destination immediately and place a `.lock` file
beside it.  Both inodes share the same data — as deemix writes more bytes, the
hardlink grows in lockstep.  stream_service's follow-mode then serves the
partial file to the client, so streaming starts within ~1 s of the download
beginning instead of ~30–60 s after it completes.
"""
import asyncio
import hashlib
import json
import logging
import os
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

# Candidate cache TTL — 7 days.  Resolved Deezer/YouTube IDs for a given
# (title, artist, duration) are extremely stable, so a long TTL keeps the
# hit-rate high and lets repeated/re-imported tracks skip the search phase
# entirely (the single biggest avoidable latency on a cache miss).
_CANDIDATE_TTL = 7 * 24 * 3600

# ---------------------------------------------------------------------------
# YouTube concurrency limiters
# ---------------------------------------------------------------------------
# Two separate semaphores so quick searches (~1–2 s) don't compete with
# heavy downloads (~20–60 s).  Sharing a single semaphore caused the
# scenario where a third stream request had to wait for two parallel
# downloads to finish before its search could even start.
#   * _yt_semaphore:        background downloads (max_yt_concurrent slots)
#   * _yt_stream_semaphore: on-demand stream downloads (max_yt_stream_concurrent)
#   * _yt_search_semaphore: searches  (max_yt_search_concurrent slots)
#
# Stream downloads use a DEDICATED pool so a bulk playlist/prefetch download
# can never hold every slot and make a user's click wait ~60 s behind it.

_yt_semaphore: asyncio.Semaphore | None = None
_yt_stream_semaphore: asyncio.Semaphore | None = None
_yt_search_semaphore: asyncio.Semaphore | None = None

# Serialises cancel + emit calls so concurrent deemix workers don't
# stomp on each other's submissions.  The expensive part (polling +
# moving the file) runs in parallel.
_deemix_submit_lock: asyncio.Lock | None = None


def _get_deemix_submit_lock() -> asyncio.Lock:
    global _deemix_submit_lock
    if _deemix_submit_lock is None:
        _deemix_submit_lock = asyncio.Lock()
    return _deemix_submit_lock


# Redis set used to atomically claim a deemix output file so two
# parallel workers don't try to move the same MP3.  Keyed by full
# absolute path.
_DEEMIX_CLAIMED_FILES_SET = "bergastream:deemix:claimed_files"


async def _claim_deemix_file(path: Path) -> bool:
    """Atomically reserve the given deemix output file for the current
    worker.  Returns True if we got it; False if another worker already
    claimed it.  Uses SADD's "newly-added" return value."""
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        added = await r.sadd(_DEEMIX_CLAIMED_FILES_SET, str(path))
        if added:
            # Expire the claim after 5 minutes — long enough for any
            # download + move, short enough that a crash doesn't leak
            # the lock forever.
            await r.expire(_DEEMIX_CLAIMED_FILES_SET, 300)
        return bool(added)
    except Exception as e:
        logger.debug(f"[deemix] claim error (proceeding optimistically): {e}")
        return True


async def _release_deemix_file(path: Path) -> None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        await r.srem(_DEEMIX_CLAIMED_FILES_SET, str(path))
    except Exception:
        pass


def _get_yt_semaphore() -> asyncio.Semaphore:
    """Semaphore for BACKGROUND yt-dlp downloads (heavy, long-running)."""
    global _yt_semaphore
    if _yt_semaphore is None:
        _yt_semaphore = asyncio.Semaphore(settings.max_yt_concurrent)
    return _yt_semaphore


def _get_yt_stream_semaphore() -> asyncio.Semaphore:
    """Dedicated semaphore for ON-DEMAND stream yt-dlp downloads (priority).

    Kept separate from the background pool so a user's play click never
    queues behind a bulk playlist download."""
    global _yt_stream_semaphore
    if _yt_stream_semaphore is None:
        _yt_stream_semaphore = asyncio.Semaphore(settings.max_yt_stream_concurrent)
    return _yt_stream_semaphore


def _get_yt_search_semaphore() -> asyncio.Semaphore:
    """Semaphore for yt-dlp SEARCHES (light, sub-second to a few seconds)."""
    global _yt_search_semaphore
    if _yt_search_semaphore is None:
        _yt_search_semaphore = asyncio.Semaphore(settings.max_yt_search_concurrent)
    return _yt_search_semaphore


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
# Candidate cache (Redis)
# ---------------------------------------------------------------------------

def _candidate_cache_key(prefix: str, title: str, artist: str, duration_ms: int | None) -> str:
    # Bucket duration by 10 s so similar timings hit the same cache entry.
    bucket = (duration_ms or 0) // 10_000
    raw = f"{title}|{artist}|{bucket}".lower().strip()
    digest = hashlib.sha1(raw.encode("utf-8", errors="replace")).hexdigest()[:16]
    return f"bergastream:candidate:{prefix}:{digest}"


async def _candidate_cache_get(prefix: str, title: str, artist: str, duration_ms: int | None) -> str | None:
    try:
        # Lazy import to avoid circular dependency at module-load time.
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        key = _candidate_cache_key(prefix, title, artist, duration_ms)
        value = await r.get(key)
        if value:
            logger.debug(f"[candidate-cache] HIT {prefix} key={key[:30]}… → {value}")
        return value
    except Exception as e:
        logger.debug(f"[candidate-cache] get error: {e}")
        return None


async def _candidate_cache_set(prefix: str, title: str, artist: str, duration_ms: int | None, value: str) -> None:
    try:
        from app.services.queue_service import DownloadQueueService
        r = DownloadQueueService._get_redis()
        key = _candidate_cache_key(prefix, title, artist, duration_ms)
        await r.set(key, value, ex=_CANDIDATE_TTL)
    except Exception as e:
        logger.debug(f"[candidate-cache] set error: {e}")


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

    # Candidate cache hit?
    cached = await _candidate_cache_get("deezer", title, artist, duration_ms)
    if cached:
        logger.info(f"[resolve] Deezer candidate (cache): {cached}")
        return cached

    # Retry on transient DNS / network failures (common with Deezer API)
    import httpx as _httpx
    deezer_id: str | None = None
    for attempt in range(3):
        try:
            deezer_id = await find_deezer_track_id(title, artist, duration_ms)
            break
        except (_httpx.ConnectError, _httpx.TimeoutException) as exc:
            if attempt < 2:
                wait = 3 * (attempt + 1)
                logger.warning(
                    f"[resolve] Deezer DNS/network error (attempt {attempt + 1}/3), "
                    f"retrying in {wait}s: {exc}"
                )
                await asyncio.sleep(wait)
            else:
                logger.warning(f"[resolve] Deezer DNS/network error, giving up: {exc}")

    if deezer_id:
        logger.info(f"[resolve] Deezer candidate (search): {deezer_id}")
        await _candidate_cache_set("deezer", title, artist, duration_ms, deezer_id)
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

    Cached for 24 h to avoid re-searching the same query.
    The search subprocess runs inside `_get_yt_search_semaphore()` (a
    separate pool from downloads) so a busy download queue doesn't block
    new searches from kicking off.

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

    # Candidate cache hit?
    cached = await _candidate_cache_get("yt", title, artist, duration_ms)
    if cached:
        logger.info(f"[resolve] YouTube candidate (cache): {cached}")
        return cached

    cmd = [
        "yt-dlp",
        "--dump-json",
        "--no-download",
        f"ytsearch5:{query}",
    ]
    try:
        async with _get_yt_search_semaphore():
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
    except asyncio.TimeoutError:
        logger.warning(f"[resolve] yt-dlp candidate search timed out for '{query}'")
        return None
    except Exception as e:
        logger.warning(f"[resolve] yt-dlp candidate search error: {e}")
        return None

    if stderr:
        stderr_text = stderr.decode("utf-8", errors="replace")
        if "429" in stderr_text:
            logger.warning(f"[resolve] yt-dlp search rate-limited (429) for '{query}'")
        elif stderr_text.strip():
            logger.debug(f"[resolve] yt-dlp search stderr for '{query}': {stderr_text[:300]}")

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
    logger.info(
        f"[resolve] yt-dlp returned {len(candidates)} candidate(s) for query='{query}'"
    )
    scored: list[tuple[float, bool, int, dict]] = []  # (t_score, dur_ok, dur_diff_ms, c)
    for c in candidates:
        vid_ms = (c.get("duration") or 0) * 1000
        t_score = _title_match_score(c.get("title", ""), title, artist)
        dur_ok = _duration_ok(vid_ms, duration_ms) if (duration_ms and duration_ms > 0) else True
        dur_diff = int(abs(vid_ms - (duration_ms or 0)))
        scored.append((t_score, dur_ok, dur_diff, c))
        logger.info(
            f"[resolve]   YT {c.get('id')} '{c.get('title')}': "
            f"title_score={t_score:.2f} dur={vid_ms}ms dur_ok={dur_ok} Δ{dur_diff}ms"
        )

    chosen: str | None = None

    # Bucket 1: title ✓ + duration ✓  (best score then smallest dur diff)
    perfect = [(s, d, c) for s, ok, d, c in scored if s >= _TITLE_THRESHOLD and ok]
    if perfect:
        best = max(perfect, key=lambda x: (x[0], -x[1]))
        chosen = best[2].get("id")
        logger.info(
            f"[resolve] YouTube candidate (title+duration, score={best[0]:.2f} Δ{best[1]}ms): {chosen}"
        )

    # Bucket 2: title ✓ + duration ✗  (highest title score)
    if not chosen:
        title_only = [(s, d, c) for s, ok, d, c in scored if s >= _TITLE_THRESHOLD and not ok]
        if title_only:
            best = max(title_only, key=lambda x: x[0])
            chosen = best[2].get("id")
            logger.warning(
                f"[resolve] YouTube candidate (title match, duration mismatch Δ{best[1]}ms, "
                f"score={best[0]:.2f}): {chosen}"
            )

    # Bucket 3: title ✗ + duration ✓  (only if duration filter requested)
    if not chosen and duration_ms and duration_ms > 0:
        dur_only = [(s, d, c) for s, ok, d, c in scored if s < _TITLE_THRESHOLD and ok]
        if dur_only:
            best = min(dur_only, key=lambda x: x[1])   # smallest duration diff
            chosen = best[2].get("id")
            logger.warning(
                f"[resolve] YouTube candidate (duration only, NO title match, "
                f"score={best[0]:.2f} Δ{best[1]}ms) — may be wrong song: {chosen}"
            )

    # Bucket 4: nothing matched — first result (unverified, NOT cached)
    if not chosen:
        chosen = candidates[0].get("id")
        logger.warning(
            f"[resolve] YouTube: no match found for '{title}' by '{artist}' — "
            f"using first result (unverified): {chosen}"
        )
        return chosen  # don't cache unverified picks

    if chosen:
        await _candidate_cache_set("yt", title, artist, duration_ms, chosen)
    return chosen


# ---------------------------------------------------------------------------
# Phase 2 — Download
# ---------------------------------------------------------------------------

async def _deemix_cancel_pending() -> None:
    """Best-effort: cancel any queued/in-progress deemix downloads before starting a new one."""
    if not settings.deemix_url:
        return
    import aiohttp as _aiohttp
    base = settings.deemix_url.rstrip("/")
    try:
        async with _aiohttp.ClientSession(
            timeout=_aiohttp.ClientTimeout(total=5)
        ) as sess:
            # Try POST first (correct method for most deemix versions), then GET as fallback
            for method in ("post", "get"):
                for endpoint in ("/api/cancelAllDownloads", "/api/clearQueue"):
                    try:
                        call = getattr(sess, method)
                        async with call(f"{base}{endpoint}") as resp:
                            if resp.status == 200:
                                logger.debug(f"[deemix] Cleared queue via {method.upper()} {endpoint}")
                                return
                    except Exception:
                        continue
    except Exception as e:
        logger.debug(f"[deemix] cancel-pending failed (non-fatal): {e}")


async def _deemix_emit(source_id: str) -> bool:
    """
    Trigger a Deezer download via the deemix sidecar REST API.

    Protocol (confirmed from bambanah/deemix source):
      1. GET  /api/connect       → creates express-session, returns login status
      2. POST /api/loginArl      → {"arl": "<token>"} — authenticates the session
      3. POST /api/addToQueue    → {"url": "https://www.deezer.com/track/<id>",
                                    "bitrate": null}
                                 → returns {"result": true, "data": {...}}
                                    or      {"result": false, "errid": "..."}

    Retries the whole sequence twice on network-level failures
    (ClientConnectorError, ServerDisconnectedError, TimeoutError) with
    1 s / 3 s backoff.  Application-level failures (HTTP 200 with result:false,
    or auth failures) are NOT retried — those are deterministic.
    """
    import aiohttp as _aiohttp

    last_error: Exception | None = None
    for attempt in range(3):
        try:
            return await _deemix_emit_once(source_id)
        except (_aiohttp.ClientConnectorError, _aiohttp.ServerDisconnectedError,
                asyncio.TimeoutError) as exc:
            last_error = exc
            if attempt < 2:
                wait = 1 if attempt == 0 else 3
                logger.warning(
                    f"[deemix] Network error in emit (attempt {attempt + 1}/3), "
                    f"retrying in {wait}s: {type(exc).__name__}: {exc}"
                )
                await asyncio.sleep(wait)
            else:
                logger.warning(
                    f"[deemix] Network error in emit, giving up after 3 attempts: "
                    f"{type(exc).__name__}: {exc}"
                )
    if last_error is not None:
        logger.warning(f"[deemix] _deemix_emit ultimately failed: {last_error}")
    return False


async def _deemix_emit_once(source_id: str) -> bool:
    """One attempt at the deemix /connect → /loginArl → /addToQueue sequence."""
    import aiohttp as _aiohttp

    base = settings.deemix_url.rstrip("/")   # e.g. http://bergastream-deemix:6595
    deezer_url = f"https://www.deezer.com/track/{source_id}"

    if not settings.deemix_arl:
        logger.warning("[deemix] DEEMIX_ARL not configured — cannot authenticate")
        return False

    _timeout = _aiohttp.ClientTimeout(total=30)
    # CookieJar keeps the express-session cookie across all three requests
    jar = _aiohttp.CookieJar(unsafe=True)
    async with _aiohttp.ClientSession(timeout=_timeout, cookie_jar=jar) as sess:

        # Step 1: create session
        try:
            async with sess.get(f"{base}/api/connect") as resp:
                body = await resp.text()
                logger.debug(f"[deemix] connect HTTP {resp.status}: {body[:200]}")
        except (_aiohttp.ClientConnectorError, _aiohttp.ServerDisconnectedError,
                asyncio.TimeoutError):
            raise  # propagate to retry layer
        except Exception as e:
            logger.warning(f"[deemix] connect call failed: {type(e).__name__}: {e}")

        # Step 2: authenticate with ARL
        _bitrate = 1  # default: MP3_128 (safest for all account tiers)
        try:
            async with sess.post(
                f"{base}/api/loginArl",
                json={"arl": settings.deemix_arl},
            ) as resp:
                login_data = await resp.json(content_type=None)
                logger.debug(f"[deemix] loginArl HTTP {resp.status}: {login_data}")
                # bockiii/deemix-docker returns {"status": 1, "user": {...}}
                # bambanah/deemix returns {"result": true, "data": {...}}
                login_ok = (
                    login_data.get("status") == 1          # bockiii format
                    or login_data.get("result") is True    # bambanah format
                )
                if not login_ok:
                    logger.warning(
                        f"[deemix] loginArl failed: {login_data.get('errid', login_data)}"
                    )
                    return False
                user = login_data.get("user", {})
                logger.info(
                    f"[deemix] Logged in as {user.get('name', '?')} "
                    f"(hq={user.get('can_stream_hq')} lossless={user.get('can_stream_lossless')})"
                )
                # Pick highest bitrate the account can actually stream
                # 9=FLAC  3=MP3_320  1=MP3_128
                if user.get("can_stream_lossless"):
                    _bitrate = 9
                elif user.get("can_stream_hq"):
                    _bitrate = 3
                else:
                    _bitrate = 1
        except (_aiohttp.ClientConnectorError, _aiohttp.ServerDisconnectedError,
                asyncio.TimeoutError):
            raise
        except Exception as e:
            logger.warning(f"[deemix] loginArl request failed: {type(e).__name__}: {e}")
            return False

        # Step 3: queue the download
        try:
            async with sess.post(
                f"{base}/api/addToQueue",
                json={"url": deezer_url, "bitrate": _bitrate},
            ) as resp:
                try:
                    data = await resp.json(content_type=None)
                except Exception:
                    text = await resp.text()
                    logger.warning(
                        f"[deemix] addToQueue non-JSON HTTP {resp.status}: {text[:200]}"
                    )
                    return False

                logger.debug(f"[deemix] addToQueue HTTP {resp.status}: {data}")

                if resp.status == 200 and data.get("result") is True:
                    logger.info(f"[deemix] Queued {source_id} via REST /api/addToQueue")
                    return True

                errid = data.get("errid", "")
                if errid == "alreadyInQueue":
                    # Track is already in deemix's queue (from a previous attempt).
                    # Treat as success — keep polling the shared volume; deemix will download it.
                    logger.info(f"[deemix] {source_id} already in deemix queue — continuing to poll")
                    return True

                logger.warning(
                    f"[deemix] addToQueue failed for {source_id}: "
                    f"errid={errid!r} data={data}"
                )
                return False

        except (_aiohttp.ClientConnectorError, _aiohttp.ServerDisconnectedError,
                asyncio.TimeoutError):
            raise
        except Exception as e:
            logger.warning(
                f"[deemix] addToQueue request failed: {type(e).__name__}: {e}"
            )
            return False


def _try_hardlink_or_copy(src: Path, dest: Path) -> bool:
    """
    Make `dest` resolve to the same data as `src`, with follow-mode support
    if at all possible.

    Strategy (in order of preference):
      1. **Hardlink** — best: both paths share an inode, so as deemix
         writes more bytes to `src`, `dest.stat().st_size` reflects it
         immediately and follow-mode serves the partial file.  Only works
         within the same filesystem.
      2. **Symlink** — works across filesystems (Errno 18 case).  `dest`
         is a path that resolves to `src`, so `open(dest)` reads from the
         live, growing file.  Slightly more fragile than hardlink: if
         someone replaces `dest` we lose the link, but in practice we
         atomically replace it at the very end of the download.
      3. **One-shot copy** — last resort.  Only the initial bytes get
         copied; follow-mode will only serve those.  Streaming effectively
         waits for the final move at the end of download.

    Returns True if the dest exists and is usable for streaming.
    """
    try:
        if dest.exists() or dest.is_symlink():
            return True
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dest)
            logger.info(f"[deemix] Hardlinked {src.name} → {dest}")
            return True
        except OSError as e_link:
            # Errno 18 = EXDEV (cross-device link).  Try a symlink — those
            # work across filesystems and let stream_service tail-follow
            # the live deemix output.
            try:
                os.symlink(src, dest)
                logger.info(
                    f"[deemix] Hardlink failed ({e_link.errno}); using symlink "
                    f"{dest} → {src.name} for live streaming"
                )
                return True
            except OSError as e_sym:
                logger.warning(
                    f"[deemix] Hardlink AND symlink failed "
                    f"(link errno={e_link.errno}, symlink errno={e_sym.errno}) — "
                    f"falling back to one-shot copy.  Streaming will only "
                    f"start after download completes."
                )
                try:
                    shutil.copy2(src, dest)
                    return True
                except Exception as ce:
                    logger.warning(f"[deemix] Copy fallback also failed: {ce}")
                    return False
    except Exception as e:
        logger.warning(f"[deemix] _try_hardlink_or_copy unexpected error: {e}")
        return False


async def download_deezer(
    track_id: str,
    source_id: str,
    expected_duration_ms: int | None = None,
) -> tuple[Path | None, str]:
    """
    Downloads from Deezer via the deemix sidecar REST API.

    Triggers download via _deemix_emit(), then polls the shared volume for
    the new audio file.  With a single deemix worker, only one download is
    ever in flight, so file identification by creation-time is unambiguous.

    Follow-mode acceleration: as soon as deemix's intermediate file is
    detected (size > 50 KB), we hardlink it to the cache destination and
    create a `.lock` file.  stream_service's follow-file generator then
    serves the partial file to the client immediately, instead of waiting
    for deemix to finish + shutil.move.
    """
    if not settings.deemix_url or not settings.deemix_downloads_path:
        logger.debug("[deemix] Skipped — DEEMIX_URL or DEEMIX_DOWNLOADS_PATH not configured")
        return None, ""

    downloads_dir = Path(settings.deemix_downloads_path)
    if not downloads_dir.exists():
        logger.warning(f"[deemix] Shared downloads dir not found: {downloads_dir}")
        return None, ""

    import time as _time

    # Submission (cancel + emit) must be serialised — two workers calling
    # cancelAllDownloads in parallel would each clobber the other's
    # submission.  The polling/move below runs in parallel for free.
    async with _get_deemix_submit_lock():
        trigger_time = _time.time() - 0.5   # small buffer for clock skew
        if not await _deemix_emit(source_id):
            return None, ""

    loop = asyncio.get_running_loop()
    deadline = loop.time() + 120
    # If after 30s there's still no file activity, deemix silently dropped
    # the request (common on cold start or after internal errors).  Re-emit
    # once to recover; deemix ignores duplicate adds (returns alreadyInQueue).
    no_activity_reemit_at = loop.time() + 30
    reemitted = False

    # State during follow-mode
    linked_dest: Path | None = None
    lock_file: Path | None = None
    source_path: Path | None = None

    try:
        while loop.time() < deadline:
            found_candidate = False
            for candidate in downloads_dir.rglob("*"):
                if not candidate.is_file():
                    continue
                if candidate.suffix.lower() not in (".mp3", ".flac"):
                    continue
                try:
                    stat = candidate.stat()
                    if not (stat.st_ctime >= trigger_time and stat.st_size > 50_000):
                        continue

                    # Atomic claim — only one worker can own a given
                    # deemix output file.  If another worker beat us
                    # to it, skip and look at the next file.  Without
                    # this, parallel deemix_bg_workers would race on
                    # the same MP3 and both try to move it.
                    if not await _claim_deemix_file(candidate):
                        continue

                    found_candidate = True
                    source_path = candidate
                    ext = candidate.suffix.lower().lstrip(".")

                    # Establish the hardlink on first detection so stream
                    # service can start serving immediately.
                    if linked_dest is None:
                        linked_dest = _cache_path(track_id, ext)
                        lock_file = Path(str(linked_dest) + ".lock")
                        lock_file.touch()
                        if not _try_hardlink_or_copy(candidate, linked_dest):
                            logger.warning(
                                f"[deemix] Could not link/copy {candidate} — "
                                f"will fall back to move at the end"
                            )
                            linked_dest = None
                            if lock_file:
                                lock_file.unlink(missing_ok=True)
                                lock_file = None
                            continue
                        logger.info(
                            f"[deemix] follow-mode active for {track_id}: "
                            f"client can stream while deemix finishes writing"
                        )

                    # Wait for the file size to stabilize (deemix finished tagging).
                    await asyncio.sleep(1.0)
                    try:
                        stat2 = candidate.stat()
                    except FileNotFoundError:
                        continue  # deemix moved/deleted it; loop again
                    if stat2.st_size != stat.st_size:
                        continue  # still being written

                    # Stable — finalize: ensure `final_dest` is a real,
                    # standalone file (not a symlink) before deemix cleans
                    # up the shared volume.
                    final_dest = linked_dest or _cache_path(track_id, ext)
                    if linked_dest is not None and linked_dest.is_symlink():
                        # Replace the symlink with a real copy of the file's
                        # current contents.  Use a .tmp file + os.replace for
                        # atomicity: a stream reading via final_dest never
                        # sees a half-written file.
                        tmp_dest = final_dest.with_suffix(final_dest.suffix + ".tmp")
                        try:
                            shutil.copy2(candidate, tmp_dest)
                            # Remove the symlink and atomically swap in the real file.
                            final_dest.unlink(missing_ok=True)
                            os.replace(tmp_dest, final_dest)
                            # deemix's original copy can now go away.
                            candidate.unlink(missing_ok=True)
                            logger.info(
                                f"[deemix] Promoted symlink to standalone file: {final_dest}"
                            )
                        except Exception as e:
                            logger.warning(
                                f"[deemix] Failed to promote symlink to real file: {e}. "
                                f"Leaving symlink in place."
                            )
                    elif linked_dest is not None and linked_dest.exists():
                        # Hardlink succeeded — both paths share an inode.
                        # deemix's original is redundant; drop it.
                        try:
                            candidate.unlink(missing_ok=True)
                        except Exception:
                            pass
                    else:
                        # Neither hardlink nor symlink worked; do a regular move.
                        shutil.move(str(candidate), str(final_dest))

                    # Post-download duration check
                    if expected_duration_ms and expected_duration_ms > 0:
                        actual_ms = _file_duration_ms(final_dest)
                        if actual_ms > 0 and not _duration_ok(actual_ms, expected_duration_ms):
                            logger.warning(
                                f"[deemix] Duration mismatch {source_id}: "
                                f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding"
                            )
                            final_dest.unlink(missing_ok=True)
                            return None, ""

                    quality = "flac" if ext == "flac" else "mp3_320"
                    logger.info(f"[deemix] Downloaded {source_id} → {final_dest.name} ({quality})")
                    return final_dest, quality
                except Exception:
                    continue

            if not found_candidate and not reemitted and loop.time() >= no_activity_reemit_at:
                reemitted = True
                logger.warning(
                    f"[deemix] No download activity after 30s for {source_id} — re-emitting"
                )
                await _deemix_emit(source_id)
                trigger_time = _time.time() - 0.5  # reset detection window

            await asyncio.sleep(0.5)

        logger.warning(f"[deemix] Timed out waiting for {source_id}")
        return None, ""
    finally:
        # Always release the lock file if we placed one but couldn't finish.
        if lock_file is not None and lock_file.exists():
            lock_file.unlink(missing_ok=True)


async def _youtube_first_result(query: str) -> str | None:
    """Gets the first yt-dlp search result with no duration constraint (last resort).
    Runs inside _get_yt_search_semaphore — separate from downloads so it doesn't
    block on long-running downloads.
    """
    cmd = ["yt-dlp", "--dump-json", "--no-download", f"ytsearch1:{query}"]
    try:
        async with _get_yt_search_semaphore():
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=20)
        if stderr:
            stderr_text = stderr.decode("utf-8", errors="replace")
            if "429" in stderr_text:
                logger.warning(f"[resolve] yt-dlp last-resort search rate-limited (429) for '{query}'")
            elif stderr_text.strip():
                logger.debug(f"[resolve] yt-dlp last-resort stderr: {stderr_text[:200]}")
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
    priority: bool = False,
) -> tuple[Path | None, str]:
    """
    Downloads a YouTube video by ID via yt-dlp (best audio → MP3 320).

    Concurrency-limited by a semaphore so background bulk-downloads cannot
    exhaust the YouTube rate limit for all workers.  When `priority` is True
    (on-demand stream), uses the dedicated stream pool so the user's click is
    never blocked behind background downloads.

    Creates a .lock file while downloading so stream_service can tail-follow.
    Retries up to 2 times on HTTP 429, with 30 s / 60 s backoff.
    Post-verifies duration with mutagen.
    """
    # No retries on 429.  Sleeping 30 s + 60 s before giving up only makes
    # the rate-limit worse (each retry is another hit) AND keeps the
    # stream-worker reserved for 90+ seconds — meanwhile a deemix fallback
    # would have finished in <10 s.  Other transient failures are also
    # not retried at this layer; the queue_service forward-to-deemix
    # path is faster and more reliable.
    _MAX_YT_RETRIES = 0

    out_dir = Path(settings.music_cache_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    dest = _cache_path(track_id, "mp3")
    if dest.exists():
        return dest, "mp3_320"

    url = f"https://www.youtube.com/watch?v={video_id}"
    lock = Path(str(dest) + ".lock")
    lock.touch()   # signals to stream_service that download is pending/in-progress

    cmd = [
        "yt-dlp",
        "-f", "bestaudio",
        "-x", "--audio-format", "mp3", "--audio-quality", "0",
        "--no-playlist",
        "-o", str(dest.with_suffix("")),   # yt-dlp appends .mp3
        url,
    ]
    semaphore = _get_yt_stream_semaphore() if priority else _get_yt_semaphore()
    try:
        async with semaphore:
            try:
                proc = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                _, stderr = await asyncio.wait_for(proc.communicate(), timeout=120)
            except asyncio.TimeoutError:
                logger.warning(f"[yt-dlp] Timed out for {video_id}")
                return None, ""

            stderr_text = stderr.decode("utf-8", errors="replace")

            if proc.returncode != 0:
                if "429" in stderr_text:
                    # Don't retry — let queue_service forward to deemix immediately.
                    logger.warning(
                        f"[yt-dlp] HTTP 429 rate-limit for {video_id} — "
                        f"aborting yt-dlp (forwarding to deemix)"
                    )
                    return None, ""
                logger.error(
                    f"[yt-dlp] NON-ZERO EXIT (rc={proc.returncode}) for {video_id}: "
                    f"{stderr_text[:600]}"
                )
                return None, ""
            logger.info(f"[yt-dlp] Download process finished OK for {video_id}")

        actual = dest if dest.exists() else dest.with_suffix("").with_suffix(".mp3")
        if actual.exists() and actual != dest:
            actual.rename(dest)

        if not dest.exists():
            logger.error(
                f"[yt-dlp] File not found after download for {video_id} "
                f"(expected at {dest})"
            )
            return None, ""

        # Post-download duration verification
        if expected_duration_ms and expected_duration_ms > 0:
            actual_ms = _file_duration_ms(dest)
            logger.info(
                f"[yt-dlp] Duration check for {video_id}: "
                f"file={actual_ms}ms expected={expected_duration_ms}ms"
            )
            if actual_ms > 0 and not _duration_ok(actual_ms, expected_duration_ms):
                logger.error(
                    f"[yt-dlp] Duration MISMATCH {video_id}: "
                    f"expected {expected_duration_ms}ms got {actual_ms}ms — discarding file"
                )
                dest.unlink(missing_ok=True)
                return None, ""

        logger.info(f"[yt-dlp] Downloaded {video_id} → {dest.name} (size={dest.stat().st_size} bytes)")
        return dest, "mp3_320"

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
    priority: bool = False,
) -> tuple[Path | None, str]:
    """
    Downloads via yt-dlp using a known video ID (source == 'youtube') or by
    searching. Kept for backward compatibility with queue_service worker.

    `priority=True` routes the actual download through the dedicated stream
    semaphore (on-demand playback) instead of the background pool.
    """
    if source_id and not source_id.startswith("search:"):
        logger.info(
            f"[yt-dlp] download_youtube: by ID={source_id!r} for {track_id}"
        )
        return await download_youtube_by_id(track_id, source_id, expected_duration_ms, priority=priority)

    logger.info(
        f"[yt-dlp] download_youtube: search mode for {track_id} "
        f"title={title!r} artist={artist!r} duration_ms={expected_duration_ms}"
    )
    # Search → duration-matched candidate → download
    video_id = await find_youtube_candidate(title, artist, expected_duration_ms)
    if video_id:
        logger.info(f"[yt-dlp] Using candidate {video_id} for {track_id}")
        return await download_youtube_by_id(track_id, video_id, expected_duration_ms, priority=priority)

    # Last resort: first result, no duration check
    if title or artist:
        query = f"{artist} {title}".strip()
        logger.warning(
            f"[yt-dlp] find_youtube_candidate returned nothing for {track_id} "
            f"— trying last-resort first result for '{query}'"
        )
        video_id = await _youtube_first_result(query)
        if video_id:
            logger.warning(
                f"[yt-dlp] Last-resort unverified first result {video_id} for "
                f"'{title}' by '{artist}'"
            )
            return await download_youtube_by_id(track_id, video_id, None, priority=priority)

    logger.error(
        f"[yt-dlp] download_youtube: no candidate found at all for {track_id} "
        f"('{title}' by '{artist}')"
    )
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
