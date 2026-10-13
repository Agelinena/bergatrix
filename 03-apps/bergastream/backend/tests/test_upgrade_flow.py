"""Filas da melhoria de qualidade com o banco de verdade e um Lidarr falso:
a conferência não espera a fila do Deemix, o orçamento limita os pedidos e
o medley vira um FLAC só.

Uso: docker compose exec -T api python tests/test_upgrade_flow.py
"""
from __future__ import annotations

import asyncio
import secrets
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.auth import repository as auth_repo
from app.auth.security import hash_password
from app.config import settings
from app.core.db import close_pool, create_pool
from app.downloads.audio_info import probe
from app.downloads.service import store_file
from app.quality import musicbrainz, upgrader
from app.storage.permanence import CACHE_DIR

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def make_audio(path: Path, seconds: int, args: list[str]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
                    *args, str(path)], check=True)
    return path


FLAC = ["-c:a", "flac", "-sample_fmt", "s16"]
MP3 = ["-c:a", "libmp3lame", "-b:a", "128k"]


class FakeLidarr:
    """Álbum 900: Holiday (3) e Boulevard (4) baixados; 901: nada ainda."""

    def __init__(self):
        self.searched: list[int] = []
        self.added: list[str] = []
        self.files = {
            1: {"path": "/music/GD/03 Holiday.flac"},
            2: {"path": "/music/GD/04 Boulevard.flac"},
            3: {"path": "/music/GD/02 Jesus.flac"},
        }

    async def tracks(self, album_id):
        if album_id == 900:
            return [
                {"title": "Jesus of Suburbia", "duration": 3000, "absoluteTrackNumber": 2,
                 "hasFile": True, "trackFileId": 3},
                {"title": "Holiday", "duration": 3000, "absoluteTrackNumber": 3, "hasFile": True, "trackFileId": 1},
                {"title": "Boulevard of Broken Dreams", "duration": 4000, "absoluteTrackNumber": 4,
                 "hasFile": True, "trackFileId": 2},
            ]
        return [{"title": "Outra", "duration": 5000, "hasFile": False}]

    async def trackfile(self, file_id):
        return self.files[file_id]

    async def trackfiles(self, album_id):
        return []

    async def delete_trackfiles(self, ids):
        pass

    async def monitor(self, ids, monitored=True):
        pass

    async def search(self, ids):
        self.searched.extend(ids)

    async def album_by_mbid(self, rg):
        return None

    async def lookup_album(self, artist, album):
        return [{"title": album, "foreignAlbumId": f"rg-{album}",
                 "artist": {"artistName": artist, "foreignArtistId": f"ar-{artist}"}}]

    async def artist_by_mbid(self, mbid):
        return None

    async def add_artist(self, artist, foreign):
        self.added.append(foreign)
        return {"id": 77}

    async def albums(self, artist_id):
        return []

    # Fila do Lidarr e monitoramento.
    queued: list[dict] = []
    removed: list[int] = []
    album_state: dict = {}
    artist_state: list[dict] = []
    monitored_albums: list[int] = []
    monitored_artists: list[int] = []

    async def queue(self):
        return self.queued

    async def remove_queued(self, queue_id):
        self.removed.append(queue_id)

    async def albums_by_ids(self, ids):
        return [self.album_state[i] for i in ids if i in self.album_state]

    async def artists(self):
        return self.artist_state

    async def monitor_artists(self, ids):
        self.monitored_artists.extend(ids)


class FakeRedis:
    def __init__(self):
        self.hashes: dict = {}
        self.values: dict = {}

    async def smembers(self, key):
        return set()

    async def llen(self, key):
        return 0

    async def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    async def hset(self, key, field, value):
        self.hashes.setdefault(key, {})[field] = value

    async def hdel(self, key, *fields):
        for f in fields:
            self.hashes.get(key, {}).pop(f, None)

    async def get(self, key):
        return self.values.get(key)

    async def set(self, key, value):
        self.values[key] = value


async def main():
    pool = await create_pool()
    tag = secrets.token_hex(3)
    music = Path(tempfile.mkdtemp(prefix="lidarr-"))
    old_root, old_batch = settings.lidarr_local_root, upgrader.DEEMIX_BATCH
    old_active, old_searches = settings.lidarr_max_active, settings.lidarr_daily_searches
    settings.lidarr_local_root = str(music)
    upgrader.DEEMIX_BATCH = 0  # sem Deemix de verdade neste teste
    real_mb = musicbrainz.studio_album

    async def no_mb(isrc):
        return None

    musicbrainz.studio_album = no_mb
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ids: list[str] = []
    user = await auth_repo.create_user(pool, f"t_upg_{tag}", hash_password("x" * 12))
    playlist = await pool.fetchval(
        "INSERT INTO playlists (user_id, name) VALUES ($1, 'U') RETURNING id", user["id"])

    async def track(title: str, seconds: int, album: str | None = "Álbum") -> str:
        """Faixa de playlist com MP3 128 (a fila de melhoria cria a linha)."""
        tid = str(await pool.fetchval(
            "INSERT INTO tracks (title, artist, album, duration_seconds) VALUES ($1, $2, $3, $4) RETURNING id",
            title, f"Teste {tag}", album, seconds))
        ids.append(tid)
        await pool.execute("INSERT INTO playlist_tracks (playlist_id, track_id) VALUES ($1, $2)", playlist, tid)
        await store_file(tid, make_audio(CACHE_DIR / f"src-{tid}.mp3", seconds, MP3), "deemix", pool)
        return tid

    async def row(tid):
        return await pool.fetchrow("SELECT * FROM quality_upgrades WHERE track_id = $1", tid)

    try:
        make_audio(music / "GD/03 Holiday.flac", 3, FLAC)
        make_audio(music / "GD/04 Boulevard.flac", 4, FLAC)
        make_audio(music / "GD/02 Jesus.flac", 3, FLAC)

        medley = await track("Holiday / Boulevard of Broken Dreams", 7)
        flood = [await track(f"Pendente {i}", 2, f"Álbum {i}") for i in range(4)]
        await pool.execute(
            """UPDATE quality_upgrades SET status = 'waiting', lidarr_artist_id = 77, lidarr_album_id = 900,
                   lidarr_foreign_album_id = 'rg-idiot', lidarr_requested_at = now(),
                   lidarr_searched_at = now(), searches = 1, deemix_checked_at = now(),
                   next_attempt_at = now() WHERE track_id = $1""", medley)
        # Pendentes "vencidos" há mais tempo que a conferência (antes, a conferência ficava atrás deles).
        for i, t in enumerate(flood):
            await pool.execute(
                """UPDATE quality_upgrades SET deemix_checked_at = now(),
                       next_attempt_at = now() - interval '30 days', created_at = $2 WHERE track_id = $1""",
                t, datetime(2000, 1, i + 1, tzinfo=timezone.utc))

        print("=== conferência não espera a fila; medley vira um FLAC só ===")
        settings.lidarr_max_active, settings.lidarr_daily_searches = 10_000, 10_000
        budget = await upgrader.Budget.load(pool)
        budget.slots = 2  # só 2 pedidos novos nesta rodada
        lidarr = FakeLidarr()
        real_load = upgrader.Budget.load

        async def fixed(pool_):
            return budget

        upgrader.Budget.load = fixed
        try:
            await upgrader.run_once(pool, FakeRedis(), lidarr)
        finally:
            upgrader.Budget.load = real_load
        r = await row(medley)
        f = await pool.fetchrow("SELECT source, codec, path FROM files WHERE track_id = $1", medley)
        ok((r["status"], f["source"], f["codec"]), ("done", "lidarr", "flac"), "medley importado em FLAC")
        info = probe(Path(f["path"]))
        dur = float(subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0",
                                    f["path"]], capture_output=True, text=True).stdout)
        ok((info.label, round(dur)), ("FLAC 16/44.1", 7), "as duas partes juntas (3 s + 4 s)")

        print("=== pedidos: vagas e orçamento ===")
        states = [(await row(t))["status"] for t in flood]
        ok(sorted(states), ["pending", "pending", "waiting", "waiting"], "só 2 álbuns pedidos (vagas)")
        ok(len(lidarr.added), 2, "2 artistas adicionados")
        first = await row(flood[0])
        ok((first["lidarr_requested_at"] is not None, first["searches"]), (True, 1), "pedido registra a data")

        # Mesmo álbum de uma faixa que já espera: entra junto, sem vaga.
        same = await track("Pendente 0", 2, "Álbum 0")
        await pool.execute("UPDATE quality_upgrades SET deemix_checked_at = now() WHERE track_id = $1", same)
        b = upgrader.Budget(searches=5, slots=1)
        await upgrader.request_lidarr(pool, await row(same), lidarr, b)
        joined = await row(same)
        ok((joined["status"], joined["lidarr_foreign_album_id"], b.slots), ("waiting", "rg-Álbum 0", 1),
           "álbum já pedido: junta-se, sem gastar vaga")
        ok(len(lidarr.added), 2, "nada novo no Lidarr")

        b = upgrader.Budget(searches=0, slots=5)
        await upgrader.request_lidarr(pool, await row(flood[3]), lidarr, b)
        ok((await row(flood[3]))["status"], "pending", "sem orçamento de busca: espera")

        print("=== busca repetida respeita o orçamento ===")
        await pool.execute(
            """UPDATE quality_upgrades SET lidarr_album_id = 901, lidarr_searched_at = now() - interval '2 days',
                      next_attempt_at = now() WHERE track_id = $1""", flood[0])
        b = upgrader.Budget(searches=0, slots=0)
        await upgrader.check_lidarr(pool, await row(flood[0]), lidarr, b)
        r = await row(flood[0])
        ok((lidarr.searched, r["searches"]), ([], 1), "sem orçamento: não busca, confere de novo depois")
        b = upgrader.Budget(searches=1, slots=0)
        await upgrader.check_lidarr(pool, await row(flood[0]), lidarr, b)
        ok((lidarr.searched, (await row(flood[0]))["searches"]), ([901], 2), "com orçamento: busca")

        print("=== download travado na fila do Lidarr ===")
        old_grace = upgrader.STUCK_GRACE
        fake, redis = FakeLidarr(), FakeRedis()
        fake.removed, fake.queued = [], [
            {"id": 5, "albumId": 901, "trackedDownloadState": "importBlocked",
             "statusMessages": [{"title": "x", "messages": ["Found executable file .exe"]}]},
            {"id": 6, "albumId": 999, "trackedDownloadState": "importBlocked"},  # álbum de outra pessoa
            {"id": 7, "albumId": 901, "trackedDownloadState": "downloading"},
        ]
        await pool.execute("UPDATE quality_upgrades SET status = 'waiting', lidarr_searched_at = now() "
                           "WHERE track_id = $1", flood[0])
        ok(await upgrader.clear_stuck(pool, redis, fake), 0, "1ª vez travado: só anota (pode destravar)")
        upgrader.STUCK_GRACE = upgrader.timedelta(0)
        try:
            ok(await upgrader.clear_stuck(pool, redis, fake), 1, "passou da carência: remove")
        finally:
            upgrader.STUCK_GRACE = old_grace
        r = await row(flood[0])
        ok((fake.removed, r["lidarr_searched_at"], "blocklist" in (r["last_error"] or "")), ([5], None, True),
           "só o nosso álbum sai da fila; nova busca agendada")
        b = upgrader.Budget(searches=1, slots=0, reserve=1)
        await upgrader.check_lidarr(pool, await row(flood[0]), fake, b)
        ok(fake.searched, [901], "busca de novo mesmo com a reserva (não é repetição)")

        print("=== artista e álbum esperados voltam a ser monitorados ===")
        fake.album_state = {901: {"id": 901, "artistId": 77, "monitored": False}}
        fake.artist_state = [{"id": 77, "monitored": False}, {"id": 78, "monitored": False}]
        fake.monitored_artists = []
        ok(await upgrader.ensure_monitored(pool, redis, fake), 2, "álbum e artista remonitorados")
        ok(fake.monitored_artists, [77], "só o artista do álbum esperado")
        ok(await upgrader.ensure_monitored(pool, redis, fake), 0, "não confere de novo antes de 6 h")
    finally:
        settings.lidarr_local_root, upgrader.DEEMIX_BATCH = old_root, old_batch
        settings.lidarr_max_active, settings.lidarr_daily_searches = old_active, old_searches
        musicbrainz.studio_album = real_mb
        for tid in ids:
            for p in await pool.fetch("SELECT path FROM files WHERE track_id = $1", tid):
                Path(p["path"]).unlink(missing_ok=True)
            await pool.execute("DELETE FROM tracks WHERE id = $1", tid)
        await pool.execute("DELETE FROM users WHERE id = $1", user["id"])
        shutil.rmtree(music, ignore_errors=True)
        await close_pool()
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
