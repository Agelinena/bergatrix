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
from app.downloads import audio_info, deemix, variants, youtube as yt_downloader
from app.downloads.audio_info import AudioInfo
from app.downloads.tags import file_matches, titles_match
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


async def resolve_deezer_id_by_metadata(title: str, artist: str, duration: int) -> str | None:
    """Sem ISRC: a faixa no Deezer pela busca avançada (artista + título),
    conferindo título e duração (até 3 s de diferença)."""
    import httpx

    query = f'artist:"{yt_downloader.main_artist(artist)}" track:"{yt_downloader.clean_title(title)}"'
    try:
        async with httpx.AsyncClient(timeout=15) as cli:
            data = (await cli.get("https://api.deezer.com/search", params={"q": query, "limit": 10})).json()
    except Exception as exc:
        logger.warning("[deezer] busca de %r falhou: %s", query, exc)
        return None
    for item in data.get("data") or []:
        if not item.get("id") or not item.get("readable", True):
            continue
        if not titles_match(title, item.get("title", "")):
            continue
        if duration and abs(int(item.get("duration") or 0) - duration) > 3:
            continue
        logger.info("[deezer] %s — %s → Deezer ID %s (sem ISRC)", artist, title, item["id"])
        return str(item["id"])
    return None


async def store_file(track_id: str, src: Path, source: str, db_pool=None) -> AudioInfo | None:
    """Guarda [src] como o arquivo da faixa (substitui o anterior, se houver)
    com a qualidade lida do arquivo. A pasta final (cache/permanent) vem das
    playlists, por sync_permanence."""
    pool = db_pool or get_pool()
    info = await asyncio.to_thread(audio_info.probe, src)
    dest = _CACHE_DIR / f"{track_id}{src.suffix.lower() or '.bin'}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    old = await pool.fetchval("SELECT path FROM files WHERE track_id = $1", track_id)
    if old and Path(old) != dest:
        Path(old).unlink(missing_ok=True)
    variants.remove_for(track_id)  # versões convertidas do mestre antigo
    try:
        await asyncio.to_thread(shutil.move, str(src), str(dest))
    except OSError as exc:
        logger.error("[storage] erro ao mover %s: %s", src, exc)
        return None
    fmt = info.format if info else src.suffix.lstrip(".").lower()
    await pool.execute(
        """INSERT INTO files (track_id, path, size_bytes, format, kind, codec, bitrate_kbps,
                              sample_rate, bit_depth, quality_rank, source)
           VALUES ($1, $2, $3, $4, 'cache', $5, $6, $7, $8, $9, $10)
           ON CONFLICT (track_id) DO UPDATE
           SET path = EXCLUDED.path, size_bytes = EXCLUDED.size_bytes, format = EXCLUDED.format,
               codec = EXCLUDED.codec, bitrate_kbps = EXCLUDED.bitrate_kbps,
               sample_rate = EXCLUDED.sample_rate, bit_depth = EXCLUDED.bit_depth,
               quality_rank = EXCLUDED.quality_rank, source = EXCLUDED.source""",
        track_id, str(dest), dest.stat().st_size, fmt,
        info.codec if info else None, info.bitrate_kbps if info else None,
        info.sample_rate if info else None, info.bit_depth if info else None,
        info.rank if info else 0, source,
    )
    logger.info("[storage] %s: %s (%s)", track_id[:8], info.label if info else fmt, source)
    # A faixa pode já estar numa playlist (entrou antes de o arquivo existir):
    # aí fica permanente, na pasta permanent/.
    await sync_permanence(pool, track_id)
    return info


async def _is_expected(path: Path, play_req: PlayRequest) -> bool:
    """Segunda barreira: o título nas tags precisa ser o da faixa pedida.
    Se não for, o arquivo é descartado e a faixa vai para o YouTube."""
    if await asyncio.to_thread(file_matches, path, play_req.title):
        return True
    path.unlink(missing_ok=True)
    return False


async def current_rank(track_id: str, db_pool=None) -> int:
    pool = db_pool or get_pool()
    return int(await pool.fetchval(
        "SELECT quality_rank FROM files WHERE track_id = $1", track_id) or 0)


async def deezer_id_for(play_req: PlayRequest, track_id: str) -> str | None:
    """Id do Deezer da faixa: vínculo já salvo, ISRC (completando-o pelos
    metadados do Spotify se faltar) ou busca por artista + título + duração."""
    pool = get_pool()
    linked = await pool.fetchval(
        "SELECT external_id FROM external_ids WHERE track_id=$1 AND provider='deezer' LIMIT 1", track_id)
    if linked:
        return linked
    if not play_req.isrc:
        spotify_id = await pool.fetchval(
            "SELECT external_id FROM external_ids WHERE track_id=$1 AND provider='spotify' LIMIT 1", track_id)
        if spotify_id:
            from app.search.spotify_meta import track_details
            details = await track_details(spotify_id)
            if details and details.isrc:
                play_req.isrc = details.isrc
                taken = await pool.fetchval("SELECT 1 FROM tracks WHERE isrc = $1 AND id <> $2",
                                            details.isrc, track_id)
                if not taken:
                    await pool.execute("UPDATE tracks SET isrc = $1 WHERE id = $2 AND isrc IS NULL",
                                       details.isrc, track_id)
    deezer_id = None
    if play_req.isrc:
        deezer_id = await resolve_deezer_id_by_isrc(play_req.isrc)
    if not deezer_id:
        deezer_id = await resolve_deezer_id_by_metadata(
            play_req.title, play_req.artist, play_req.duration_seconds)
    if deezer_id:
        await track_repo.link_external_id(pool, track_id, "deezer", deezer_id)
    return deezer_id


async def deemix_into(track_id: str, deezer_id: str, play_req: PlayRequest, formats,
                      min_rank: int = 0) -> AudioInfo | None:
    """Baixa pelo Deemix no melhor dos [formats] e guarda só se a qualidade
    passar de [min_rank] (no upgrade, o arquivo atual não é trocado por um
    igual ou pior)."""
    formats = [f for f in formats if deemix.EXPECTED_RANK.get(f, 99) > min_rank]
    if not formats:
        return None
    ok, src = await deemix.download_best(deezer_id, formats)
    if not ok or src is None or not await _is_expected(src, play_req):
        return None
    if min_rank:
        info = await asyncio.to_thread(audio_info.probe, src)
        if info is None or info.rank <= min_rank:
            logger.info("[deemix] %s: %s não melhora a faixa", track_id[:8], info.label if info else "?")
            src.unlink(missing_ok=True)
            return None
    return await store_file(track_id, src, "deemix")


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
    """Sob demanda: Deezer em MP3 320 (128 se a faixa não tiver 320); sem a
    faixa no Deezer ou se o Deemix falhar, YouTube."""
    deezer_id = await deezer_id_for(play_req, track_id)
    if not deezer_id:
        return await _do_download_youtube_fallback(play_req, track_id)
    if await deemix_into(track_id, deezer_id, play_req, deemix.ON_DEMAND):
        return True, "deemix"
    return await _fallback_after_deemix(play_req, track_id, deezer_id)


async def _do_download_deezer(play_req: PlayRequest, track_id: str) -> tuple[bool, str | None]:
    """Faixa vinda do Deezer: o external_id já é o id do Deezer."""
    await track_repo.link_external_id(get_pool(), track_id, "deezer", play_req.external_id)
    if await deemix_into(track_id, play_req.external_id, play_req, deemix.ON_DEMAND):
        return True, "deemix"
    return await _fallback_after_deemix(play_req, track_id, play_req.external_id)


async def _do_download_youtube_fallback(play_req: PlayRequest, track_id: str) -> tuple[bool, str | None]:
    # Os melhores candidatos em ordem: um vídeo bloqueado ou indisponível
    # não impede o próximo.
    candidates = await yt_downloader.find_candidates(
        play_req.title, play_req.artist, play_req.duration_seconds)
    for candidate in candidates:
        ok, src_path, _fmt = await yt_downloader.download_video(candidate["video_id"])
        if ok and src_path and await store_file(track_id, src_path, "youtube"):
            await track_repo.link_external_id(get_pool(), track_id, "youtube", candidate["video_id"])
            return True, "youtube"
    return False, None


async def _do_download_youtube_direct(video_id: str, track_id: str) -> tuple[bool, str | None]:
    ok, src_path, _fmt = await yt_downloader.download_video(video_id)
    if ok and src_path and await store_file(track_id, src_path, "youtube"):
        return True, "youtube"
    return False, None
