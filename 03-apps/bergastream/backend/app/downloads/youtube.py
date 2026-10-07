"""Download e scoring de candidatos do YouTube/YTMusic via yt-dlp."""
from __future__ import annotations
import asyncio
import logging
import re
import urllib.parse
from pathlib import Path
import yt_dlp
from app.config import settings

logger = logging.getLogger("bergastream.downloads.youtube")
_CACHE_DIR = Path(settings.music_dir) / "cache"

_PENALTY_WORDS = ["live", "cover", "remix", "karaoke", "slowed", "sped up",
                  "reverb", "instrumental", "acapella", "8d", "loop",
                  "trap remix", "bass boosted", "nightcore"]
_DURATION_TOLERANCE = 3

_YDL_DOWNLOAD_OPTS = {
    "format": "bestaudio/best",
    "outtmpl": str(_CACHE_DIR / "%(id)s.%(ext)s"),
    "quiet": True, "no_warnings": True,
    "ignoreerrors": True, "overwrites": True,
    "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}],
}


def _normalize(text: str) -> str:
    import unicodedata
    text = unicodedata.normalize("NFKD", text).encode("ASCII", "ignore").decode("ASCII")
    return re.sub(r"[^a-z0-9\s]", "", text.lower()).strip()

def _words(s: str) -> set[str]:
    return set(_normalize(s).split())


def score_candidate(title: str, uploader: str, duration: int,
                    ref_title: str, ref_artist: str, ref_duration: int) -> float:
    if abs(duration - ref_duration) > _DURATION_TOLERANCE:
        return -1.0
    score = 50.0
    tn = _normalize(title); rtn = _normalize(ref_title); ran = _normalize(ref_artist)
    tw = _words(tn); rw = _words(rtn); common = tw & rw
    if common:
        score += 20.0 * (len(common) / max(len(rw), 1))
    aw = _words(ran)
    if aw and (aw & tw):
        score += 15.0
    un = _normalize(uploader)
    if ran in un or un in ran:
        score += 10.0
    elif any(a in un for a in aw):
        score += 5.0
    for w in _PENALTY_WORDS:
        if w in tn and w not in rtn:
            score -= 30.0
    if rtn in tn:
        score += 10.0
    if tn == rtn:
        score += 25.0
    return score
def _search_yt_sync(query, ref_title, ref_artist, ref_duration, limit=10):
    ydl_opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist",
                "default_search": "ytsearch", "ignoreerrors": True}
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)
    except Exception as exc:
        logger.warning("[yt] ytsearch error: %s", exc)
        return []
    scored = []
    for entry in (info.get("entries") or []):
        if not entry:
            continue
        s = score_candidate(entry.get("title", ""),
                            entry.get("channel") or entry.get("uploader") or "",
                            entry.get("duration") or 0,
                            ref_title, ref_artist, ref_duration)
        if s > 0:
            scored.append({"video_id": entry.get("id", ""), "title": entry.get("title", ""),
                           "uploader": entry.get("channel") or entry.get("uploader") or "",
                           "duration": entry.get("duration") or 0, "score": s, "src": "yt"})
    scored.sort(key=lambda x: x["score"], reverse=True)
    return scored


def _search_ytmusic_sync(query, ref_title, ref_artist, ref_duration, limit=10):
    ydl_opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", "ignoreerrors": True}
    url = "https://music.youtube.com/search?q=" + urllib.parse.quote_plus(query)
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as exc:
        logger.warning("[yt] ytmusic search error: %s", exc)
        return []
    scored = []
    for entry in (info.get("entries") or []):
        if not entry:
            continue
        s = score_candidate(entry.get("title", ""),
                            entry.get("channel") or entry.get("uploader") or "",
                            entry.get("duration") or 0,
                            ref_title, ref_artist, ref_duration)
        if s > 0:
            scored.append({"video_id": entry.get("id", ""), "title": entry.get("title", ""),
                           "uploader": entry.get("channel") or entry.get("uploader") or "",
                           "duration": entry.get("duration") or 0, "score": s, "src": "ytmusic"})
    scored.sort(key=lambda x: x["score"], reverse=True)
    return scored


async def find_best_candidate(title, artist, duration):
    queries = [f"{artist} - {title}", title]
    seen_ids = set()
    best = None
    for q in queries:
        candidates = await asyncio.to_thread(_search_yt_sync, q, title, artist, duration)
        for c in candidates:
            if c["video_id"] in seen_ids:
                continue
            seen_ids.add(c["video_id"])
            if best is None or c["score"] > best["score"]:
                best = c
        candidates = await asyncio.to_thread(_search_ytmusic_sync, q, title, artist, duration)
        for c in candidates:
            if c["video_id"] in seen_ids:
                continue
            seen_ids.add(c["video_id"])
            if best is None or c["score"] > best["score"]:
                best = c
    if best:
        logger.info("[yt] melhor candidato: %s (score=%.1f, src=%s)", best["title"], best["score"], best.get("src","?"))
    else:
        logger.warning("[yt] nenhum candidato para %s - %s", artist, title)
    return best


async def download_video(video_id, output_dir=None):
    dest = output_dir or _CACHE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    opts = dict(_YDL_DOWNLOAD_OPTS)
    opts["outtmpl"] = str(dest / "%(id)s.%(ext)s")
    def _download_sync():
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=True)

    try:
        # Em thread: o yt-dlp (download + ffmpeg) travava o loop do worker e
        # derrubava a conexão com o Redis.
        await asyncio.to_thread(_download_sync)
    except Exception as exc:
        logger.error("[yt] download error for %s: %s", video_id, exc)
        return False, None, None
    mp3 = dest / f"{video_id}.mp3"
    if mp3.exists():
        return True, mp3, "mp3_192"
    for f in dest.iterdir():
        if f.stem == video_id and f.suffix in (".mp3", ".m4a", ".webm", ".opus"):
            fmt = {".mp3": "mp3_192", ".m4a": "aac", ".webm": "opus", ".opus": "opus"}.get(f.suffix, "mp3_192")
            return True, f, fmt
    return False, None, None
    return score