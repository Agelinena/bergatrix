"""Worker — processo isolado: fila de downloads, melhoria de qualidade das
faixas de playlist (app.quality.upgrader) e teste diário do Spotify
(app.search.spotify_health), que pode atualizar a biblioteca e reiniciar."""
from __future__ import annotations
import asyncio
import logging
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from app.config import settings
from app.core.redis import get_redis, close_redis
from app.downloads import queue as q
from app.downloads import deemix, youtube as yt_downloader
from app.core.db import create_pool, close_pool
from app.tracks import repository as track_repo

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO), format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("bergastream.worker")
MAX_CONCURRENT = 2; _POLL_TIMEOUT = 3
MAX_LOW = 1                        # downloads de playlist ao mesmo tempo
SPOTIFY_FIRST_CHECK = 120          # s depois de subir
SPOTIFY_CHECK_HOURS = 24
SPOTIFY_RETRY_HOURS = 6            # quando falhou e ainda não há versão nova
_restart = asyncio.Event()         # biblioteca nova ativada: sair e o Docker sobe de novo


async def spotify_watch(redis) -> None:
    from app.search.spotify_health import check_and_heal
    await asyncio.sleep(SPOTIFY_FIRST_CHECK)
    while not _restart.is_set():
        try:
            result = await check_and_heal(redis)
        except Exception as exc:
            logger.exception("[spotify-health] verificação falhou: %s", exc)
            result = {"ok": False}
        if result.get("restart"):
            _restart.set()
            return
        await asyncio.sleep(3600 * (SPOTIFY_CHECK_HOURS if result.get("ok") else SPOTIFY_RETRY_HOURS))


async def process_job(redis, pool, job_id: str) -> None:
    job = await q.get_job(redis, job_id)
    if not job:
        return
    track_id = job["track_id"]; provider = job.get("provider", "spotify")
    if job.get("status") not in (None, "queued"):
        return  # já processado (saiu de duas filas depois de promovido)
    if await track_repo.track_has_file(pool, track_id):
        # Já baixada (outro pedido chegou antes): baixar de novo trocaria o
        # arquivo de quem está ouvindo.
        await q.set_job_status(redis, job_id, "done")
        return
    if not await q.mark_active(redis, track_id):
        return
    await q.set_job_status(redis, job_id, "downloading")
    logger.info("[worker] processando %s (%s)", track_id[:8], provider)
    try:
        metadata = await track_repo.get_track_by_id(pool, track_id)
        if not metadata:
            await q.set_job_status(redis, job_id, "error", error="Track nao encontrada")
            return
        from app.downloads.service import _do_download_deezer, _do_download_spotify, _do_download_youtube_direct
        from app.tracks.models import PlayRequest
        req = PlayRequest(provider=provider, external_id=job.get("external_id", ""),
            title=metadata.title, artist=metadata.artist, album=metadata.album or "",
            duration_seconds=metadata.duration_seconds, isrc=metadata.isrc, cover_url=metadata.cover_url)
        if provider in ("youtube", "ytmusic"):
            success, prov = await _do_download_youtube_direct(job.get("external_id", ""), track_id)
        elif provider == "deezer":
            success, prov = await _do_download_deezer(req, track_id)
        else:
            success, prov = await _do_download_spotify(req, track_id)
        if success:
            await q.set_job_status(redis, job_id, "done", provider_used=prov or "")
        else:
            await q.set_job_status(redis, job_id, "error", error="Falhou")
    except Exception as exc:
        logger.exception("[worker] erro em %s: %s", track_id[:8], exc)
        await q.set_job_status(redis, job_id, "error", error=str(exc))
    finally:
        await q.mark_done(redis, track_id)


async def main_loop() -> None:
    redis = await get_redis()
    pool = await create_pool()
    logger.info("[worker] iniciado (max_concurrent=%d)", MAX_CONCURRENT)
    from app.quality.upgrader import run_forever as upgrade_forever
    background = [asyncio.create_task(upgrade_forever(pool, redis)),
                  asyncio.create_task(spotify_watch(redis))]
    active_tasks = set()
    low_tasks = set()  # downloads de playlist (prioridade 3) em andamento
    def _clean(t): active_tasks.discard(t); low_tasks.discard(t)
    while not _restart.is_set():
        while len(active_tasks) < MAX_CONCURRENT:
            # No máximo MAX_LOW downloads de playlist ao mesmo tempo: sempre
            # sobra vaga para a música que alguém quer ouvir agora.
            job_id = await q.dequeue(redis, timeout=_POLL_TIMEOUT, include_low=len(low_tasks) < MAX_LOW)
            if not job_id:
                break
            job = await q.get_job(redis, job_id) or {}
            t = asyncio.create_task(process_job(redis, pool, job_id))
            active_tasks.add(t); t.add_done_callback(_clean)
            if job.get("priority") == "3":
                low_tasks.add(t)
        await asyncio.sleep(0.1)
    logger.warning("[worker] reiniciando para carregar a biblioteca nova (esperando %d download(s))",
                   len(active_tasks))
    if active_tasks:
        await asyncio.wait(active_tasks, timeout=300)
    for task in background:
        task.cancel()


async def main():
    try:
        await main_loop()
    finally:
        await close_pool()
        await close_redis()

if __name__ == "__main__":
    asyncio.run(main())
