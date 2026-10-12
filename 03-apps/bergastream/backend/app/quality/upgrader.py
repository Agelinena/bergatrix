"""Melhoria de qualidade das faixas de playlist (roda no worker).

Sob demanda, a faixa vem do Deezer em MP3 320 (ou do YouTube). Faixa que
entra numa playlist ganha uma linha em `quality_upgrades` (ver
`storage.permanence`) e este laço tenta, com o tempo:

1. Deemix no melhor formato da conta (FLAC → MP3 320 → 128). O Deezer
   Premium costuma incluir FLAC; se não incluir, fica o 320. Repete a cada
   DEEMIX_RETRY (o catálogo muda).
2. Sem FLAC ainda e com Lidarr configurado: o álbum da faixa no Lidarr, que
   baixa pela Usenet (SABnzbd). Confere os arquivos a cada CHECK_EVERY e
   manda buscar de novo todo dia nos primeiros UPGRADE_DAILY_DAYS, depois
   toda semana (o Lidarr também vigia a Usenet sozinho, por RSS).
3. Quando o Lidarr baixa, o FLAC da faixa é copiado e passa a ser o arquivo
   dela. Quando nenhuma outra faixa de playlist espera aquele álbum, ele deixa
   de ser monitorado e os arquivos são apagados do Lidarr (o Lidarr só baixa
   álbuns inteiros; LIDARR_KEEP_ALBUMS=true mantém).

O arquivo só é trocado por um de qualidade maior (audio_info.rank).
"""
from __future__ import annotations

import asyncio
import logging
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.config import settings
from app.downloads import deemix
from app.downloads.audio_info import LOSSLESS, probe
from app.downloads.service import _CACHE_DIR, current_rank, deemix_into, deezer_id_for, store_file
from app.downloads.youtube import main_artist
from app.quality import lidarr as lidarr_api
from app.quality.lidarr import Lidarr, LidarrError
from app.storage.permanence import RELEASE_KEY  # álbuns a deixar de monitorar
from app.tracks import repository as track_repo
from app.tracks.models import PlayRequest

logger = logging.getLogger("bergastream.quality.upgrader")

LOOP_EVERY = 300                       # s entre rodadas
BATCH = 5                              # faixas por rodada
NO_FILE_RETRY = timedelta(minutes=10)  # faixa ainda baixando pela 1ª vez
DEEMIX_RETRY = timedelta(days=30)
CHECK_EVERY = timedelta(hours=6)       # conferir se o Lidarr já baixou
ARTIST_LOADING = timedelta(minutes=15) # Lidarr carregando a discografia
ERROR_RETRY = timedelta(days=1)
NOT_FOUND_RETRY = timedelta(days=7)


def now() -> datetime:
    return datetime.now(timezone.utc)


def search_interval(created_at: datetime, at: datetime) -> timedelta:
    """Todo dia nos primeiros UPGRADE_DAILY_DAYS da faixa na fila; depois,
    toda semana."""
    if at - created_at < timedelta(days=settings.upgrade_daily_days):
        return timedelta(days=1)
    return timedelta(days=7)


async def _update(pool, track_id: str, **fields) -> None:
    sets = ", ".join(f"{k} = ${i}" for i, k in enumerate(fields, start=2))
    await pool.execute(
        f"UPDATE quality_upgrades SET {sets}, updated_at = now() WHERE track_id = $1",
        track_id, *fields.values())


async def process(pool, row, lidarr: Lidarr | None) -> None:
    track_id = str(row["track_id"])
    if not await pool.fetchval("SELECT 1 FROM files WHERE track_id = $1", track_id):
        await _update(pool, track_id, next_attempt_at=now() + NO_FILE_RETRY)
        return
    rank = await current_rank(track_id, pool)
    if rank >= LOSSLESS:
        await _update(pool, track_id, status="done", last_error=None)
        return
    track = await track_repo.get_track_by_id(pool, track_id)
    req = PlayRequest(provider="spotify", external_id="", title=track.title, artist=track.artist,
                      album=track.album or "", duration_seconds=track.duration_seconds,
                      isrc=track.isrc, cover_url=track.cover_url)

    checked = row["deemix_checked_at"]
    if checked is None or now() - checked > DEEMIX_RETRY:
        deezer_id = await deezer_id_for(req, track_id)
        if deezer_id:
            info = await deemix_into(track_id, deezer_id, req, deemix.BEST, min_rank=rank)
            if info:
                rank = info.rank
                logger.info("[upgrade] %s — %s: %s pelo Deemix", track.artist, track.title, info.label)
        await _update(pool, track_id, deemix_checked_at=now())
        if rank >= LOSSLESS:
            await _update(pool, track_id, status="done", last_error=None)
            return

    if lidarr is None:
        # Sem Lidarr: só o Deemix, de novo daqui a DEEMIX_RETRY.
        await _update(pool, track_id, status="pending", next_attempt_at=now() + DEEMIX_RETRY)
        return
    await _lidarr_step(pool, row, track, rank, lidarr)


async def _lidarr_step(pool, row, track, rank: int, lidarr: Lidarr) -> None:
    track_id = str(row["track_id"])
    if not row["lidarr_foreign_album_id"]:
        await _request_album(pool, row, track, lidarr)
        return
    if not row["lidarr_album_id"]:
        albums = await lidarr.albums(row["lidarr_artist_id"])
        found = next((a for a in albums if a.get("foreignAlbumId") == row["lidarr_foreign_album_id"]), None)
        if found is None:
            requested = row["lidarr_searched_at"] or row["created_at"]
            stale = now() - requested > timedelta(hours=2)
            await _update(pool, track_id, next_attempt_at=now() + (NOT_FOUND_RETRY if stale else ARTIST_LOADING),
                          last_error="álbum fora do perfil de metadados do Lidarr" if stale else None)
            return
        # Monitorado: o Lidarr também pega sozinho quando aparecer na Usenet (RSS).
        await lidarr.monitor([found["id"]])
        await lidarr.search([found["id"]])
        await _update(pool, track_id, status="waiting", lidarr_album_id=found["id"],
                      lidarr_searched_at=now(), searches=row["searches"] + 1,
                      next_attempt_at=now() + CHECK_EVERY, last_error=None)
        return

    album_id = row["lidarr_album_id"]
    tracks = await lidarr.tracks(album_id)
    match = lidarr_api.pick_track(tracks, track.title, track.duration_seconds)
    if match and match.get("hasFile") and match.get("trackFileId"):
        await _import(pool, track_id, track, rank, await lidarr.trackfile(match["trackFileId"]))
        await finish_album(pool, lidarr, album_id)
        return
    if match is None and any(t.get("hasFile") for t in tracks):
        await _update(pool, track_id, status="done",
                      last_error="o Lidarr baixou o álbum, mas sem esta faixa (título diferente?)")
        await finish_album(pool, lidarr, album_id)
        return
    fields = {"status": "waiting", "next_attempt_at": now() + CHECK_EVERY}
    searched = row["lidarr_searched_at"]
    if searched is None or now() - searched >= search_interval(row["created_at"], now()):
        await lidarr.search([album_id])
        fields.update(lidarr_searched_at=now(), searches=row["searches"] + 1)
        logger.info("[upgrade] %s — %s: busca na Usenet nº %d", track.artist, track.title, row["searches"] + 1)
    await _update(pool, track_id, **fields)


async def _request_album(pool, row, track, lidarr: Lidarr) -> None:
    """Acha o álbum da faixa no MusicBrainz e pede ao Lidarr."""
    track_id = str(row["track_id"])
    album = track.album
    if not album:
        await _update(pool, track_id, next_attempt_at=now() + NOT_FOUND_RETRY,
                      last_error="faixa sem álbum: o Lidarr só baixa por álbum")
        return
    candidates = await lidarr.lookup_album(main_artist(track.artist), album)
    picked = lidarr_api.pick_album(candidates, track.artist, album)
    if picked is None:
        await _update(pool, track_id, next_attempt_at=now() + NOT_FOUND_RETRY,
                      last_error=f"álbum {album!r} não encontrado no MusicBrainz")
        return
    foreign = picked["foreignAlbumId"]
    artist = await lidarr.artist_by_mbid(picked["artist"]["foreignArtistId"])
    if artist is None:
        created = await lidarr.add_artist(picked["artist"], foreign)
        await _update(pool, track_id, status="waiting", lidarr_artist_id=created["id"],
                      lidarr_foreign_album_id=foreign, lidarr_searched_at=now(), searches=1,
                      next_attempt_at=now() + ARTIST_LOADING, last_error=None)
        logger.info("[upgrade] %s — %s: artista adicionado ao Lidarr (álbum %r)",
                    track.artist, track.title, picked.get("title"))
        return
    albums = await lidarr.albums(artist["id"])
    found = next((a for a in albums if a.get("foreignAlbumId") == foreign), None)
    if found is None:
        # Discografia ainda carregando (ou álbum fora do perfil de metadados).
        await _update(pool, track_id, status="waiting", lidarr_artist_id=artist["id"],
                      lidarr_foreign_album_id=foreign, lidarr_searched_at=now(),
                      next_attempt_at=now() + ARTIST_LOADING)
        return
    await lidarr.monitor([found["id"]])
    await lidarr.search([found["id"]])
    await _update(pool, track_id, status="waiting", lidarr_artist_id=artist["id"],
                  lidarr_album_id=found["id"], lidarr_foreign_album_id=foreign,
                  lidarr_searched_at=now(), searches=1, next_attempt_at=now() + CHECK_EVERY,
                  last_error=None)
    logger.info("[upgrade] %s — %s: álbum %r monitorado no Lidarr", track.artist, track.title, picked.get("title"))


async def _import(pool, track_id: str, track, rank: int, trackfile: dict) -> None:
    """Copia o arquivo do Lidarr e o adota se for melhor."""
    source = Path(lidarr_api.local_path(trackfile.get("path", "")))
    if not source.is_file():
        await _update(pool, track_id, next_attempt_at=now() + CHECK_EVERY,
                      last_error=f"arquivo do Lidarr não visível aqui: {source} (confira o volume)")
        return
    info = await asyncio.to_thread(probe, source)
    if info is None or info.rank <= rank:
        await _update(pool, track_id, status="done",
                      last_error=None if info else "arquivo do Lidarr ilegível")
        return
    copy = _CACHE_DIR / f"{track_id}.lidarr{source.suffix.lower()}"
    await asyncio.to_thread(shutil.copy2, source, copy)
    stored = await store_file(track_id, copy, "lidarr", pool)
    done = stored is not None and stored.rank >= LOSSLESS
    await _update(pool, track_id, status="done" if done else "waiting", last_error=None,
                  next_attempt_at=now() + CHECK_EVERY)
    logger.info("[upgrade] %s — %s: %s pelo Lidarr", track.artist, track.title, info.label)


async def finish_album(pool, lidarr: Lidarr, album_id: int) -> bool:
    """Ninguém mais espera o álbum: deixa de monitorar (senão o Lidarr baixa
    de novo o que faltar) e apaga os arquivos dele, já copiados. Devolve True
    se finalizou."""
    waiting = await pool.fetchval(
        "SELECT EXISTS (SELECT 1 FROM quality_upgrades WHERE lidarr_album_id = $1 AND status <> 'done')",
        album_id)
    if waiting:
        return False
    await lidarr.monitor([album_id], monitored=False)
    if not settings.lidarr_keep_albums:
        ids = [f["id"] for f in await lidarr.trackfiles(album_id) if f.get("id")]
        await lidarr.delete_trackfiles(ids)
        if ids:
            logger.info("[upgrade] álbum %s: %d arquivo(s) apagado(s) do Lidarr", album_id, len(ids))
    return True


async def _release_albums(pool, redis, lidarr: Lidarr | None) -> None:
    """Álbuns cujas faixas saíram de todas as playlists: o Lidarr para de
    procurar e o que ele já baixou é apagado."""
    ids = [int(i) for i in await redis.smembers(RELEASE_KEY)]
    if not ids or lidarr is None:
        return
    for album_id in ids:
        await finish_album(pool, lidarr, album_id)
        await redis.srem(RELEASE_KEY, album_id)
    logger.info("[upgrade] %d álbum(ns) liberados no Lidarr", len(ids))


async def run_once(pool, redis, lidarr: Lidarr | None) -> int:
    rows = await pool.fetch(
        """SELECT * FROM quality_upgrades
           WHERE status <> 'done' AND next_attempt_at <= now()
           ORDER BY next_attempt_at LIMIT $1""", BATCH)
    for row in rows:
        try:
            await process(pool, row, lidarr)
        except LidarrError as exc:
            logger.warning("[upgrade] %s: %s", str(row["track_id"])[:8], exc)
            await _update(pool, str(row["track_id"]), last_error=str(exc)[:300],
                          next_attempt_at=now() + ERROR_RETRY)
        except Exception as exc:
            logger.exception("[upgrade] %s falhou: %s", str(row["track_id"])[:8], exc)
            await _update(pool, str(row["track_id"]), last_error=str(exc)[:300],
                          next_attempt_at=now() + ERROR_RETRY)
    try:
        await _release_albums(pool, redis, lidarr)
    except LidarrError as exc:
        logger.warning("[upgrade] não liberou álbuns no Lidarr: %s", exc)
    return len(rows)


async def run_forever(pool, redis) -> None:
    lidarr = Lidarr() if lidarr_api.enabled() else None
    logger.info("[upgrade] iniciado (Lidarr %s)", "ligado" if lidarr else "desligado")
    await backfill_quality(pool)
    while True:
        try:
            await run_once(pool, redis, lidarr)
        except Exception as exc:  # banco/Redis fora: tenta na próxima rodada
            logger.warning("[upgrade] rodada falhou: %s", exc)
        await asyncio.sleep(LOOP_EVERY)


async def backfill_quality(pool) -> int:
    """Mede a qualidade dos arquivos baixados antes desta versão."""
    rows = await pool.fetch("SELECT track_id, path FROM files WHERE codec IS NULL")
    measured = 0
    for r in rows:
        info = await asyncio.to_thread(probe, Path(r["path"]))
        if info is None:
            continue
        await pool.execute(
            """UPDATE files SET codec = $2, bitrate_kbps = $3, sample_rate = $4, bit_depth = $5,
                      quality_rank = $6, format = $7 WHERE track_id = $1""",
            r["track_id"], info.codec, info.bitrate_kbps, info.sample_rate, info.bit_depth,
            info.rank, info.format)
        measured += 1
    if measured:
        logger.info("[upgrade] qualidade medida em %d arquivo(s) antigo(s)", measured)
    return measured
