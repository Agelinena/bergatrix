"""Orquestrador de download."""
from __future__ import annotations
import asyncio
import json
import logging
import shutil
from datetime import datetime, timezone
from pathlib import Path
from app.config import settings
from app.storage.permanence import sync_permanence
from app.core.db import get_pool
from app.core.redis import get_redis
from app.downloads import state as dl_state
from app.downloads import deemix, youtube as yt_downloader
from app.downloads.tags import file_matches
from app.tracks import repository as track_repo
from app.tracks.models import PlayRequest

logger = logging.getLogger("bergastream.downloads.service")
_CACHE_DIR = Path(settings.music_dir) / "cache"


async def resolve_deezer_id_by_isrc(isrc: str) -> str | None:
    import httpx
    url = f"https://api.deezer.com/track/isrc:{isrc}"
    try:
        async with httpx.AsyncClient(timeout=15) as cli:
            r = await cli.get(url)
            r.raise_for_status()
            data = r.json()
            if "error" in data and data["error"]:
                logger.warning("[deezer] ISRC %s nao encontrado: %s", isrc, data["error"])
                return None
            deezer_id = str(data.get("id"))
            if deezer_id:
                logger.info("[deezer] ISRC %s -> Deezer ID %s", isrc, deezer_id)
                return deezer_id
    except Exception as exc:
        logger.warning("[deezer] erro ao resolver ISRC %s: %s", isrc, exc)
    return None


async def _move_to_cache(src: Path, track_id: str, fmt: str) -> Path | None:
    _ext = {"flac": ".flac", "mp3_320": ".mp3", "mp3_192": ".mp3",
            "mp3_128": ".mp3", "aac": ".m4a", "opus": ".opus", "vorbis": ".ogg"}
    ext = _ext.get(fmt, ".mp3")
    dest = _CACHE_DIR / f"{track_id}{ext}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(src), str(dest))
        logger.info("[storage] %s -> %s", src.name, dest)
        return dest
    except OSError as exc:
        logger.error("[storage] erro ao mover %s: %s", src, exc)
        return None


async def _is_expected(path: Path, play_req: PlayRequest) -> bool:
    """Segunda barreira: o título nas tags precisa ser o da faixa pedida.
    Se não for, o arquivo é descartado e a faixa vai para o YouTube."""
    if await asyncio.to_thread(file_matches, path, play_req.title):
        return True
    path.unlink(missing_ok=True)
    return False


async def _register_in_db(track_id: str, file_path: Path, fmt: str, db_pool=None) -> None:
    pool = db_pool or get_pool()
    size = file_path.stat().st_size
    await pool.execute(
        """INSERT INTO files (track_id, path, size_bytes, format, kind)
           VALUES ($1, $2, $3, $4, 'cache')
           ON CONFLICT (track_id) DO UPDATE
           SET path = EXCLUDED.path, size_bytes = EXCLUDED.size_bytes,
               format = EXCLUDED.format""",
        track_id, str(file_path), size, fmt,
    )
    # A faixa pode já estar numa playlist (entrou antes de o arquivo existir):
    # aí nasce permanente, na pasta permanent/.
    await sync_permanence(pool, track_id)


_FAILURES_KEY = "bergastream:deemix:failures"
_FAILURES_KEEP = 100


async def _note_deemix_failure(play_req: PlayRequest, deezer_id: str, recovered: bool) -> None:
    """Falhas recentes do Deemix (Ajustes → No servidor): motivo e se o
    YouTube conseguiu baixar a faixa no lugar."""
    entry = {
        "title": play_req.title, "artist": play_req.artist,
        "error": deemix.pop_error(deezer_id) or "não baixou",
        "recovered": recovered, "at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        r = await get_redis()
        await r.lpush(_FAILURES_KEY, json.dumps(entry))
        await r.ltrim(_FAILURES_KEY, 0, _FAILURES_KEEP - 1)
    except Exception as exc:  # Redis fora não pode atrapalhar o download.
        logger.warning("[deemix] não registrou a falha: %s", exc)


async def _fallback_after_deemix(play_req: PlayRequest, track_id: str, deezer_id: str) -> tuple[bool, str | None]:
    ok, provider = await _do_download_youtube_fallback(play_req, track_id)
    await _note_deemix_failure(play_req, deezer_id, recovered=ok)
    return ok, provider


async def _do_download_spotify(play_req: PlayRequest, track_id: str) -> tuple[bool, str | None]:
    if not play_req.isrc:
        return await _do_download_youtube_fallback(play_req, track_id)
    pool = get_pool()
    deezer_id = None
    rows = await pool.fetch("SELECT external_id FROM external_ids WHERE track_id=$1 AND provider='deezer'", track_id)
    for r in rows:
        deezer_id = r["external_id"]
        break
    if not deezer_id:
        deezer_id = await resolve_deezer_id_by_isrc(play_req.isrc)
    if deezer_id:
        ok, src_path, fmt = await deemix.download_track(deezer_id)
        if ok and src_path and fmt and await _is_expected(src_path, play_req):
            dest = await _move_to_cache(src_path, track_id, fmt)
            if dest:
                await _register_in_db(track_id, dest, fmt)
                return True, "deemix"
        return await _fallback_after_deemix(play_req, track_id, deezer_id)
    return await _do_download_youtube_fallback(play_req, track_id)


async def _do_download_deezer(play_req: PlayRequest, track_id: str) -> tuple[bool, str | None]:
    """Faixa vinda de link do Deezer: o external_id já é o id do Deezer."""
    ok, src_path, fmt = await deemix.download_track(play_req.external_id)
    if ok and src_path and fmt and await _is_expected(src_path, play_req):
        dest = await _move_to_cache(src_path, track_id, fmt)
        if dest:
            await _register_in_db(track_id, dest, fmt)
            return True, "deemix"
    return await _fallback_after_deemix(play_req, track_id, play_req.external_id)


async def _do_download_youtube_fallback(play_req: PlayRequest, track_id: str) -> tuple[bool, str | None]:
    candidate = await yt_downloader.find_best_candidate(play_req.title, play_req.artist, play_req.duration_seconds)
    if not candidate:
        return False, None
    ok, src_path, fmt = await yt_downloader.download_video(candidate["video_id"])
    if ok and src_path and fmt:
        dest = await _move_to_cache(src_path, track_id, fmt)
        if dest:
            pool = get_pool()
            await track_repo.link_external_id(pool, track_id, "youtube", candidate["video_id"])
            await _register_in_db(track_id, dest, fmt)
            return True, "youtube"
    return False, None


async def _do_download_youtube_direct(video_id: str, track_id: str) -> tuple[bool, str | None]:
    ok, src_path, fmt = await yt_downloader.download_video(video_id)
    if ok and src_path and fmt:
        dest = await _move_to_cache(src_path, track_id, fmt)
        if dest:
            await _register_in_db(track_id, dest, fmt)
            return True, "youtube"
    return False, None


async def start_download(play_req: PlayRequest, track_id: str) -> None:
    if dl_state.is_active(track_id):
        return
    dl_state.set_status(track_id, dl_state.DownloadStatus.DOWNLOADING)
    try:
        if play_req.provider == "youtube":
            success, provider = await _do_download_youtube_direct(play_req.external_id, track_id)
        else:
            success, provider = await _do_download_spotify(play_req, track_id)
        if success:
            dl_state.set_status(track_id, dl_state.DownloadStatus.READY, provider=provider)
        else:
            dl_state.set_status(track_id, dl_state.DownloadStatus.ERROR, error="Todos os providers falharam")
    except Exception as exc:
        logger.exception("[%s] download error: %s", track_id[:8], exc)
        dl_state.set_status(track_id, dl_state.DownloadStatus.ERROR, error=str(exc))
