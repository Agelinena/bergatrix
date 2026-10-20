"""Melhoria de qualidade das faixas de playlist (roda no worker).

Sob demanda, a faixa vem do Deezer em MP3 320 (ou do YouTube). Faixa que
entra numa playlist ganha uma linha em `quality_upgrades` (ver
`storage.permanence`). Cada rodada tem três filas, uma não espera a outra:

1. Conferência do Lidarr: todas as faixas com álbum no Lidarr cuja hora
   chegou (a cada CHECK_EVERY). Só consulta o Lidarr (não gasta o
   indexador); quando o arquivo chega, o FLAC é copiado e vira o da faixa.
   Quando nenhuma outra faixa de playlist espera o álbum, ele deixa de ser
   monitorado e os arquivos são apagados (LIDARR_KEEP_ALBUMS=true mantém).
2. Deemix: até DEEMIX_BATCH faixas no melhor formato da conta (FLAC → MP3
   320 → 128). Repete a cada DEEMIX_RETRY (o catálogo muda).
3. Pedidos ao Lidarr: faixas que passaram pelo Deemix sem FLAC, em ordem de
   chegada, enquanto houver vaga (LIDARR_MAX_ACTIVE álbuns na fase de busca
   diária) e orçamento (LIDARR_DAILY_SEARCHES buscas por 24 h). O álbum é o
   de estúdio da gravação (ISRC → MusicBrainz), não a coletânea do Spotify.

O álbum é buscado na Usenet ao ser pedido, todo dia nos primeiros
UPGRADE_DAILY_DAYS e depois toda semana; entre uma busca e outra, o Lidarr
vigia a Usenet sozinho (RSS). O arquivo só é trocado por um de qualidade
maior (audio_info.rank).
"""
from __future__ import annotations

import asyncio
import logging
import shutil
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.config import settings
from app.downloads import deemix
from app.downloads.audio_info import LOSSLESS, probe
from app.downloads.service import _CACHE_DIR, current_rank, deemix_into, deezer_id_for, store_file
from app.downloads.youtube import main_artist
from app.quality import lidarr as lidarr_api
from app.quality import musicbrainz
from app.quality.lidarr import Lidarr, LidarrError
from app.storage.permanence import RELEASE_KEY  # álbuns a deixar de monitorar
from app.tracks import repository as track_repo
from app.tracks.models import PlayRequest

logger = logging.getLogger("bergastream.quality.upgrader")

LOOP_EVERY = 300                       # s entre rodadas
DEEMIX_BATCH = 30                      # faixas pelo Deemix por rodada
NO_FILE_RETRY = timedelta(minutes=10)  # faixa ainda baixando pela 1ª vez
DEEMIX_RETRY = timedelta(days=30)
# Conferir se o Lidarr já baixou: consulta só o Lidarr (não gasta o indexador).
CHECK_EVERY = timedelta(minutes=30)
ARTIST_LOADING = timedelta(minutes=15) # Lidarr carregando a discografia
LIDARR_ERROR_RETRY = timedelta(hours=1)
# Item travado na fila do Lidarr por mais que isto: remove e busca de novo.
STUCK_GRACE = timedelta(hours=1)
STUCK_KEY = "bergastream:lidarr:stuck"       # id na fila → quando travou
# Conferir se artistas/álbuns ainda esperados continuam monitorados.
MONITOR_CHECK_EVERY = timedelta(hours=6)
MONITOR_KEY = "bergastream:lidarr:monitor_checked_at"
ERROR_RETRY = timedelta(days=1)
NOT_FOUND_RETRY = timedelta(days=7)


def now() -> datetime:
    return datetime.now(timezone.utc)


def search_interval(requested_at: datetime, at: datetime) -> timedelta:
    """Todo dia nos primeiros UPGRADE_DAILY_DAYS do álbum no Lidarr; depois,
    toda semana."""
    if at - requested_at < timedelta(days=settings.upgrade_daily_days):
        return timedelta(days=1)
    return timedelta(days=7)


class Budget:
    """O que a rodada ainda pode gastar: buscas no indexador (teto por 24 h)
    e vagas de álbum na fase de busca diária."""

    def __init__(self, searches: int, slots: int, reserve: int = 0) -> None:
        self.searches = searches
        self.slots = slots
        # Buscas guardadas para pedidos novos (as repetidas não as usam).
        self.reserve = reserve
        self._albums: set = set()

    @classmethod
    async def load(cls, pool) -> "Budget":
        row = await pool.fetchrow(
            """SELECT
                 count(DISTINCT coalesce(lidarr_album_id::text, lidarr_foreign_album_id))
                   FILTER (WHERE lidarr_searched_at > now() - interval '1 day') AS searched,
                 count(DISTINCT coalesce(lidarr_album_id::text, lidarr_foreign_album_id))
                   FILTER (WHERE status = 'waiting'
                           AND lidarr_requested_at > now() - make_interval(days => $1)) AS active
               FROM quality_upgrades""", settings.upgrade_daily_days)
        return cls(max(0, settings.lidarr_daily_searches - row["searched"]),
                   max(0, settings.lidarr_max_active - row["active"]),
                   reserve=settings.lidarr_request_reserve)

    def search(self, album, repeat: bool = False) -> bool | None:
        """True: pode buscar (gasta 1). False: o álbum já foi buscado nesta
        rodada (outra faixa dele). None: acabou o orçamento (para busca
        repetida, acaba ao chegar na reserva dos pedidos novos)."""
        if album in self._albums:
            return False
        if self.searches <= (self.reserve if repeat else 0):
            return None
        self.searches -= 1
        self._albums.add(album)
        return True

    def can_request(self) -> bool:
        return self.slots > 0 and self.searches > 0


async def _update(pool, track_id: str, **fields) -> None:
    sets = ", ".join(f"{k} = ${i}" for i, k in enumerate(fields, start=2))
    await pool.execute(
        f"UPDATE quality_upgrades SET {sets}, updated_at = now() WHERE track_id = $1",
        track_id, *fields.values())


async def _current(pool, track_id: str) -> int | None:
    """Qualidade do arquivo da faixa; None se ainda não tem (e reagenda). Já
    sem perda: marca como concluída."""
    if not await pool.fetchval("SELECT 1 FROM files WHERE track_id = $1", track_id):
        await _update(pool, track_id, next_attempt_at=now() + NO_FILE_RETRY)
        return None
    rank = await current_rank(track_id, pool)
    if rank >= LOSSLESS:
        await _update(pool, track_id, status="done", last_error=None)
        return None
    return rank


async def deemix_pass(pool, row, with_lidarr: bool) -> None:
    track_id = str(row["track_id"])
    rank = await _current(pool, track_id)
    if rank is None:
        return
    track = await track_repo.get_track_by_id(pool, track_id)
    req = PlayRequest(provider="spotify", external_id="", title=track.title, artist=track.artist,
                      album=track.album or "", duration_seconds=track.duration_seconds,
                      isrc=track.isrc, cover_url=track.cover_url)
    deezer_id = await deezer_id_for(req, track_id)
    if deezer_id:
        info = await deemix_into(track_id, deezer_id, req, deemix.BEST, min_rank=rank)
        if info:
            rank = info.rank
            logger.info("[upgrade] %s — %s: %s pelo Deemix", track.artist, track.title, info.label)
    fields: dict = {"deemix_checked_at": now()}
    if rank >= LOSSLESS:
        fields.update(status="done", last_error=None)
    elif row["status"] == "pending":
        # Com Lidarr: entra na fila de pedidos. Sem: só o Deemix, daqui a DEEMIX_RETRY.
        fields["next_attempt_at"] = now() if with_lidarr else now() + DEEMIX_RETRY
    await _update(pool, track_id, **fields)


async def check_lidarr(pool, row, lidarr: Lidarr, budget: Budget) -> None:
    """Faixa com álbum pedido ao Lidarr: o arquivo chegou? Busca de novo se
    for a hora (e houver orçamento)."""
    track_id = str(row["track_id"])
    rank = await _current(pool, track_id)
    if rank is None:
        return
    track = await track_repo.get_track_by_id(pool, track_id)
    requested = row["lidarr_requested_at"] or row["created_at"]

    album_id = row["lidarr_album_id"]
    if not album_id:
        albums = await lidarr.albums(row["lidarr_artist_id"])
        found = next((a for a in albums if a.get("foreignAlbumId") == row["lidarr_foreign_album_id"]), None)
        if found is None:
            if now() - requested > timedelta(hours=2):
                # Fora do perfil de metadados: volta à fila de pedidos mais tarde.
                await _update(pool, track_id, status="pending", lidarr_foreign_album_id=None,
                              lidarr_requested_at=None, next_attempt_at=now() + NOT_FOUND_RETRY,
                              last_error="álbum fora do perfil de metadados do Lidarr")
            else:
                await _update(pool, track_id, next_attempt_at=now() + ARTIST_LOADING)
            return
        # Monitorado: o Lidarr também pega sozinho quando aparecer na Usenet (RSS).
        await lidarr.monitor([found["id"]])
        await _update(pool, track_id, lidarr_album_id=found["id"], last_error=None)
        album_id = found["id"]

    tracks = await lidarr.tracks(album_id)
    parts = lidarr_api.pick_parts(tracks, track.title, track.duration_seconds)
    if parts and all(p.get("hasFile") and p.get("trackFileId") for p in parts):
        files = [await lidarr.trackfile(p["trackFileId"]) for p in parts]
        await _import(pool, track_id, track, rank, files)
        await finish_album(pool, lidarr, album_id)
        return
    if not parts and any(t.get("hasFile") for t in tracks):
        await _update(pool, track_id, status="done",
                      last_error="o Lidarr baixou o álbum, mas sem esta faixa (título diferente?)")
        await finish_album(pool, lidarr, album_id)
        return

    fields: dict = {"status": "waiting", "next_attempt_at": now() + CHECK_EVERY}
    searched = row["lidarr_searched_at"]
    if searched is None or now() - searched >= search_interval(requested, now()):
        allowed = budget.search(album_id, repeat=searched is not None)
        if allowed is not None:
            if allowed:
                await lidarr.search([album_id])
                logger.info("[upgrade] %s — %s: busca na Usenet nº %d",
                            track.artist, track.title, row["searches"] + 1)
            fields.update(lidarr_searched_at=now(), searches=row["searches"] + 1)
    await _update(pool, track_id, **fields)


async def request_lidarr(pool, row, lidarr: Lidarr, budget: Budget) -> None:
    """Pede ao Lidarr o álbum de estúdio da faixa."""
    if not budget.can_request():
        return  # continua na fila; entra quando abrir vaga
    track_id = str(row["track_id"])
    if await _current(pool, track_id) is None:
        return
    track = await track_repo.get_track_by_id(pool, track_id)

    picked = None
    studio = await musicbrainz.studio_album(track.isrc)
    if studio:
        picked = await lidarr.album_by_mbid(studio["id"])
    if picked is None:
        if not track.album:
            await _update(pool, track_id, next_attempt_at=now() + NOT_FOUND_RETRY,
                          last_error="faixa sem álbum: o Lidarr só baixa por álbum")
            return
        candidates = await lidarr.lookup_album(main_artist(track.artist), track.album)
        picked = lidarr_api.pick_album(candidates, track.artist, track.album)
    if picked is None:
        await _update(pool, track_id, next_attempt_at=now() + NOT_FOUND_RETRY,
                      last_error=f"álbum {track.album!r} não encontrado no MusicBrainz")
        return
    foreign = picked["foreignAlbumId"]

    # Outra faixa já espera este álbum: entra junto, sem gastar vaga nem busca.
    other = await pool.fetchrow(
        """SELECT lidarr_artist_id, lidarr_album_id, lidarr_requested_at, lidarr_searched_at, searches
           FROM quality_upgrades WHERE lidarr_foreign_album_id = $1 AND status = 'waiting' LIMIT 1""",
        foreign)
    if other:
        await _update(pool, track_id, status="waiting", lidarr_foreign_album_id=foreign,
                      **{k: other[k] for k in other.keys()}, next_attempt_at=now(), last_error=None)
        return

    budget.slots -= 1
    fields: dict = {"status": "waiting", "lidarr_foreign_album_id": foreign,
                    "lidarr_requested_at": now(), "last_error": None}
    artist = await lidarr.artist_by_mbid(picked["artist"]["foreignArtistId"])
    if artist is None:
        # O Lidarr busca o álbum sozinho quando terminar de carregar a discografia.
        budget.search(foreign)
        created = await lidarr.add_artist(picked["artist"], foreign)
        await _update(pool, track_id, lidarr_artist_id=created["id"], lidarr_searched_at=now(),
                      searches=1, next_attempt_at=now() + ARTIST_LOADING, **fields)
        logger.info("[upgrade] %s — %s: artista adicionado ao Lidarr (álbum %r)",
                    track.artist, track.title, picked.get("title"))
        return
    if not artist.get("monitored"):
        # Artista que já estava no Lidarr sem monitorar: o álbum seria ignorado.
        await lidarr.monitor_artists([artist["id"]])
    albums = await lidarr.albums(artist["id"])
    found = next((a for a in albums if a.get("foreignAlbumId") == foreign), None)
    if found is None:
        # Discografia ainda carregando (ou álbum fora do perfil de metadados).
        await _update(pool, track_id, lidarr_artist_id=artist["id"], lidarr_searched_at=None,
                      next_attempt_at=now() + ARTIST_LOADING, **fields)
        return
    await lidarr.monitor([found["id"]])
    searched = {}
    if budget.search(found["id"]):
        await lidarr.search([found["id"]])
        searched = {"lidarr_searched_at": now(), "searches": 1}
    await _update(pool, track_id, lidarr_artist_id=artist["id"], lidarr_album_id=found["id"],
                  next_attempt_at=now() + CHECK_EVERY, **searched, **fields)
    logger.info("[upgrade] %s — %s: álbum %r monitorado no Lidarr", track.artist, track.title, picked.get("title"))


def _join(sources: list[Path], target: Path, codec: str) -> None:
    """Junta as faixas de um medley na ordem (sem perda: FLAC → FLAC)."""
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as lst:
        for src in sources:
            lst.write("file '" + str(src).replace("'", "'\\''") + "'\n")
    try:
        audio = ["-c:a", "flac"] if codec == "flac" else ["-c", "copy"]
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst.name,
                        "-map", "0:a", *audio, str(target)], check=True, timeout=600)
    finally:
        Path(lst.name).unlink(missing_ok=True)


async def _import(pool, track_id: str, track, rank: int, trackfiles: list[dict]) -> None:
    """Copia o arquivo do Lidarr (ou junta as partes, num medley) e o adota
    se for melhor."""
    sources = [Path(lidarr_api.local_path(tf.get("path", ""))) for tf in trackfiles]
    missing = next((s for s in sources if not s.is_file()), None)
    if missing is not None:
        await _update(pool, track_id, next_attempt_at=now() + CHECK_EVERY,
                      last_error=f"arquivo do Lidarr não visível aqui: {missing} (confira o volume)")
        return
    info = await asyncio.to_thread(probe, sources[0])
    if info is None or info.rank <= rank:
        await _update(pool, track_id, status="done",
                      last_error=None if info else "arquivo do Lidarr ilegível")
        return
    copy = _CACHE_DIR / f"{track_id}.lidarr{sources[0].suffix.lower()}"
    if len(sources) == 1:
        await asyncio.to_thread(shutil.copy2, sources[0], copy)
    else:
        await asyncio.to_thread(_join, sources, copy, info.codec)
    stored = await store_file(track_id, copy, "lidarr", pool)
    done = stored is not None and stored.rank >= LOSSLESS
    await _update(pool, track_id, status="done" if done else "waiting", last_error=None,
                  next_attempt_at=now() + CHECK_EVERY)
    joined = f" ({len(sources)} faixas juntas)" if len(sources) > 1 else ""
    logger.info("[upgrade] %s — %s: %s pelo Lidarr%s", track.artist, track.title, info.label, joined)


async def finish_album(pool, lidarr: Lidarr, album_id: int) -> bool:
    """Ninguém mais espera o álbum: deixa de monitorar (senão o Lidarr baixa
    de novo o que faltar) e apaga os arquivos dele, já copiados. Devolve True
    se finalizou."""
    # Também as faixas que entraram junto pelo id do MusicBrainz e ainda não
    # têm o id do Lidarr gravado.
    waiting = await pool.fetchval(
        """SELECT EXISTS (
             SELECT 1 FROM quality_upgrades
             WHERE status <> 'done'
               AND (lidarr_album_id = $1 OR lidarr_foreign_album_id IN (
                     SELECT lidarr_foreign_album_id FROM quality_upgrades
                     WHERE lidarr_album_id = $1 AND lidarr_foreign_album_id IS NOT NULL)))""",
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


async def clear_stuck(pool, redis, lidarr: Lidarr) -> int:
    """Downloads de álbuns que o Bergastream espera, travados na fila do
    Lidarr (importação bloqueada ou falha) há mais de STUCK_GRACE: tira da
    fila e do SABnzbd, põe o release na blocklist e agenda nova busca.
    Devolve quantos removeu."""
    waiting = {r["lidarr_album_id"] for r in await pool.fetch(
        """SELECT DISTINCT lidarr_album_id FROM quality_upgrades
           WHERE status = 'waiting' AND lidarr_album_id IS NOT NULL""")}
    seen: dict = await redis.hgetall(STUCK_KEY) or {}
    stuck_now: set[str] = set()
    removed = 0
    for item in await lidarr.queue():
        reason = lidarr_api.stuck_reason(item)
        album_id = item.get("albumId")
        if reason is None or album_id not in waiting or item.get("id") is None:
            continue
        key = str(item["id"])
        stuck_now.add(key)
        first = seen.get(key) or seen.get(key.encode())
        if first is None:
            await redis.hset(STUCK_KEY, key, now().isoformat())
            continue
        if isinstance(first, bytes):
            first = first.decode()
        if now() - datetime.fromisoformat(first) < STUCK_GRACE:
            continue
        await lidarr.remove_queued(item["id"])
        await redis.hdel(STUCK_KEY, key)
        stuck_now.discard(key)
        await pool.execute(
            """UPDATE quality_upgrades SET lidarr_searched_at = NULL, next_attempt_at = now(),
                      last_error = $2, updated_at = now()
               WHERE lidarr_album_id = $1 AND status = 'waiting'""",
            album_id, f"download travado no Lidarr ({reason}): removido, release na blocklist"[:300])
        logger.info("[upgrade] álbum %s: download travado no Lidarr removido (%s); nova busca", album_id, reason)
        removed += 1
    # Itens que saíram da fila (andaram ou foram removidos à mão).
    gone = [k for k in seen if (k.decode() if isinstance(k, bytes) else k) not in stuck_now]
    if gone:
        await redis.hdel(STUCK_KEY, *gone)
    return removed


async def ensure_monitored(pool, redis, lidarr: Lidarr) -> int:
    """Álbuns que faixas ainda esperam, e seus artistas, voltam a ser
    monitorados se alguém (ou o "só de passagem" de outra faixa) tirou.
    Sem isso o Lidarr ignora o álbum no RSS. A cada MONITOR_CHECK_EVERY.
    Devolve quantos álbuns/artistas remonitorou."""
    last = await redis.get(MONITOR_KEY)
    if last:
        last = last.decode() if isinstance(last, bytes) else last
        if now() - datetime.fromisoformat(last) < MONITOR_CHECK_EVERY:
            return 0
    await redis.set(MONITOR_KEY, now().isoformat())
    ids = [r["lidarr_album_id"] for r in await pool.fetch(
        """SELECT DISTINCT lidarr_album_id FROM quality_upgrades
           WHERE status = 'waiting' AND lidarr_album_id IS NOT NULL""")]
    if not ids:
        return 0
    albums = await lidarr.albums_by_ids(ids)
    off_albums = [a["id"] for a in albums if not a.get("monitored")]
    artist_ids = {a.get("artistId") for a in albums}
    off_artists = [a["id"] for a in await lidarr.artists()
                   if a.get("id") in artist_ids and not a.get("monitored")]
    if off_albums:
        await lidarr.monitor(off_albums)
    if off_artists:
        await lidarr.monitor_artists(off_artists)
    if off_albums or off_artists:
        logger.info("[upgrade] Lidarr: %d álbum(ns) e %d artista(s) voltaram a ser monitorados",
                    len(off_albums), len(off_artists))
    return len(off_albums) + len(off_artists)


async def _each(pool, rows, step) -> None:
    for row in rows:
        try:
            await step(row)
        except LidarrError as exc:
            logger.warning("[upgrade] %s: %s", str(row["track_id"])[:8], exc)
            await _update(pool, str(row["track_id"]), last_error=str(exc)[:300],
                          next_attempt_at=now() + LIDARR_ERROR_RETRY)
        except Exception as exc:
            logger.exception("[upgrade] %s falhou: %s", str(row["track_id"])[:8], exc)
            await _update(pool, str(row["track_id"]), last_error=str(exc)[:300],
                          next_attempt_at=now() + ERROR_RETRY)


async def run_once(pool, redis, lidarr: Lidarr | None) -> int:
    """Uma rodada das três filas; devolve quantas faixas passaram."""
    budget = await Budget.load(pool) if lidarr else None
    checks: list = []
    if lidarr:
        for step in (clear_stuck, ensure_monitored):
            try:
                await step(pool, redis, lidarr)
            except LidarrError as exc:
                logger.warning("[upgrade] %s: %s", step.__name__, exc)
        checks = await pool.fetch(
            """SELECT * FROM quality_upgrades
               WHERE status = 'waiting' AND lidarr_foreign_album_id IS NOT NULL
                 AND next_attempt_at <= now()
               ORDER BY lidarr_searched_at NULLS FIRST""")
        await _each(pool, checks, lambda r: check_lidarr(pool, r, lidarr, budget))

    # Alguém esperando uma música (play/próxima da fila): o Deemix fica para
    # ela; a melhoria das playlists espera a próxima rodada.
    from app.downloads.queue import PRIORITY_QUEUES
    listener_waiting = bool(await redis.llen(PRIORITY_QUEUES[1]))
    deemix_rows = [] if listener_waiting else await pool.fetch(
        """SELECT * FROM quality_upgrades
           WHERE status <> 'done' AND next_attempt_at <= now()
             AND (deemix_checked_at IS NULL OR deemix_checked_at < now() - $2::interval)
           ORDER BY next_attempt_at LIMIT $1""", DEEMIX_BATCH, DEEMIX_RETRY)
    await _each(pool, deemix_rows, lambda r: deemix_pass(pool, r, lidarr is not None))

    requests: list = []
    if lidarr and budget.can_request():
        requests = await pool.fetch(
            """SELECT * FROM quality_upgrades
               WHERE status = 'pending' AND lidarr_foreign_album_id IS NULL
                 AND deemix_checked_at >= now() - $2::interval AND next_attempt_at <= now()
               ORDER BY created_at LIMIT $1""", budget.slots, DEEMIX_RETRY)
        await _each(pool, requests, lambda r: request_lidarr(pool, r, lidarr, budget))

    try:
        await _release_albums(pool, redis, lidarr)
    except LidarrError as exc:
        logger.warning("[upgrade] não liberou álbuns no Lidarr: %s", exc)
    return len(checks) + len(deemix_rows) + len(requests)


async def run_forever(pool, redis) -> None:
    lidarr = Lidarr() if lidarr_api.enabled() else None
    logger.info("[upgrade] iniciado (Lidarr %s)", "ligado" if lidarr else "desligado")
    await backfill_quality(pool)
    from app.downloads import loudness
    while True:
        try:
            await run_once(pool, redis, lidarr)
        except Exception as exc:  # banco/Redis fora: tenta na próxima rodada
            logger.warning("[upgrade] rodada falhou: %s", exc)
        try:
            await loudness.backfill(pool)
        except Exception as exc:
            logger.warning("[loudness] backfill falhou: %s", exc)
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
