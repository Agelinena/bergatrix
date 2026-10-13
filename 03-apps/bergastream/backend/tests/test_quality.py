"""Testes da qualidade de áudio, do Spotify sem conta e da melhoria pelo
Deemix/Lidarr (sem rede).

Uso: docker compose exec -T api python tests/test_quality.py
"""
from __future__ import annotations

import asyncio
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parent.parent))

from app import version_tuple
from app.downloads import audio_info, deemix
from app.quality import lidarr
from app.quality.upgrader import search_interval
from app.search import spotify, spotify_meta

P = F = 0


def ok(a, b, m):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def ff(codec, bit_rate=None, sample_rate="44100", bits=None, fmt_rate=None, sample_fmt="s16"):
    stream = {"codec_type": "audio", "codec_name": codec, "sample_rate": sample_rate, "sample_fmt": sample_fmt}
    if bit_rate:
        stream["bit_rate"] = str(bit_rate)
    if bits:
        stream["bits_per_raw_sample"] = str(bits)
    return {"streams": [stream], "format": {"bit_rate": str(fmt_rate)} if fmt_rate else {}}


print("=== qualidade lida do arquivo ===")
mp3_320 = audio_info.parse_ffprobe(ff("mp3", 320000))
ok((mp3_320.rank, mp3_320.format, mp3_320.label), (audio_info.HIGH, "mp3_320", "MP3 320"), "MP3 320 = alta")
mp3_128 = audio_info.parse_ffprobe(ff("mp3", 128000))
ok((mp3_128.rank, mp3_128.format), (audio_info.LOW, "mp3_128"), "MP3 128 = baixa")
ok(audio_info.parse_ffprobe(ff("mp3", 192000)).rank, audio_info.MEDIUM, "MP3 192 = média")
opus = audio_info.parse_ffprobe(ff("opus", None, "48000", fmt_rate=152000))
ok((opus.rank, opus.format, opus.label), (audio_info.MEDIUM, "opus", "Opus 152"), "Opus do YouTube = média (bitrate do contêiner)")
ok(audio_info.parse_ffprobe(ff("aac", 128000)).rank, audio_info.MEDIUM, "AAC 128 do YouTube = média")
flac = audio_info.parse_ffprobe(ff("flac", None, "44100", bits=16))
ok((flac.rank, flac.format, flac.label), (audio_info.LOSSLESS, "flac", "FLAC 16/44.1"), "FLAC 16 = sem perda")
hires = audio_info.parse_ffprobe(ff("flac", None, "96000", sample_fmt="s32"))
ok((hires.rank, hires.label), (audio_info.HIRES, "FLAC 24/96"), "FLAC s32 sem bits informados = hi-res")
ok(audio_info.parse_ffprobe({"streams": [{"codec_type": "video"}]}), None, "sem trilha de áudio")
ok(mp3_320.rank > opus.rank > mp3_128.rank, True, "ordem: 320 > Opus > 128")

print("=== ids e metadados do Spotify ===")
ok(len(spotify_meta.to_gid("4uLU6hMCjMI75M1A2tKUQC")), 32, "gid com 32 dígitos hexadecimais")
for sid in ("4uLU6hMCjMI75M1A2tKUQC", "3iof6EclqePezHDibBiykI", "0000000000000000000001"):
    ok(spotify_meta.to_base62(spotify_meta.to_gid(sid)), sid, f"ida e volta base62 ↔ gid ({sid[:6]}…)")
details = spotify_meta.parse_details({
    "external_id": [{"type": "isrc", "id": "brsme8900064"}],
    "album": {"name": "Djavan", "gid": spotify_meta.to_gid("3SrW9PsWq7ipPERLgck3tA"),
              "date": {"year": 1989},
              "cover_group": {"image": [{"size": "DEFAULT", "file_id": "aaa"},
                                        {"size": "LARGE", "file_id": "bbb"}]}}})
ok((details.isrc, details.album, details.album_id, details.year, details.cover_url),
   ("BRSME8900064", "Djavan", "3SrW9PsWq7ipPERLgck3tA", 1989, "https://i.scdn.co/image/bbb"),
   "ISRC (maiúsculo), álbum, ano e capa grande")
ok(spotify_meta.parse_details({}).isrc, None, "sem ISRC")

print("=== faixas da SpotifyScraper → SearchResult ===")
Img = lambda url, w=None: SimpleNamespace(url=url, width=w, height=w)
artist = SimpleNamespace(name="Djavan", id="", uri="spotify:artist:5rrmaoBXZ7Jcs4Qb77j0YA")
album = SimpleNamespace(id="3SrW9PsWq7ipPERLgck3tA", name="Djavan",
                        images=(Img("small", 300), Img("big", 640), Img("tiny", 64)))
track = SimpleNamespace(id="3iof6EclqePezHDibBiykI", name="Oceano", artists=(artist,), album=album,
                        duration_ms=296106, images=())
r = spotify.track_from(track)
ok((r.provider, r.external_id, r.title, r.artist, r.album, r.duration_seconds, r.isrc),
   ("spotify", "3iof6EclqePezHDibBiykI", "Oceano", "Djavan", "Djavan", 296, None), "campos básicos (ISRC depois)")
ok((r.cover_url, r.artist_id, r.album_id), ("big", "5rrmaoBXZ7Jcs4Qb77j0YA", "3SrW9PsWq7ipPERLgck3tA"),
   "maior capa; id do artista tirado do uri")
in_album = SimpleNamespace(**{**track.__dict__, "album": None})
ok(spotify.track_from(in_album, album).album, "Djavan", "faixa de álbum recebe o álbum de fora")
unsized = (Img("https://i.scdn.co/image/ab67616d00004851x"), Img("https://i.scdn.co/image/ab67616d0000b273x"))
ok(spotify.best_image(unsized), "https://i.scdn.co/image/ab67616d0000b273x", "sem largura: escolhe a capa de 640 pelo hash")
ok(spotify.best_image(()), None, "sem imagem")

print("=== Lidarr: álbum e faixa certos ===")
cands = [
    {"title": "Djavan (Ao Vivo)", "foreignAlbumId": "x", "artist": {"artistName": "Djavan"}},
    {"title": "Djavan", "foreignAlbumId": "y", "artist": {"artistName": "Djavan"}},
    {"title": "Djavan", "foreignAlbumId": "z", "artist": {"artistName": "Outro"}},
]
ok(lidarr.pick_album(cands, "Djavan", "Djavan")["foreignAlbumId"], "y", "título igual e artista certo")
ok(lidarr.pick_album(cands, "Djavan, Caetano Veloso", "Djavan (Remasterizado)")["foreignAlbumId"], "y",
   "ignora parênteses e convidados")
ok(lidarr.pick_album(cands, "Djavan", "Luz"), None, "álbum inexistente")
tracks = [{"title": "Curumim", "duration": 200000}, {"title": "Oceano", "duration": 297000, "hasFile": True}]
ok(lidarr.pick_track(tracks, "Oceano", 296)["duration"], 297000, "título + duração (ms)")
ok(lidarr.pick_track(tracks, "Oceano", 250), None, "duração muito diferente = outra versão")
arctic = [{"title": "Fluorescent Adolescent", "duration": 173000}, {"title": "Old Yellow Bricks", "duration": 187000}]
ok(lidarr.pick_track(arctic, "Fluorescent Adolescent", 183)["title"], "Fluorescent Adolescent",
   "10 s a mais no Spotify ainda é a mesma faixa")
ok(lidarr.pick_track(arctic, "Old Yellow Bricks", 193)["title"], "Old Yellow Bricks", "6 s de diferença")
fases = [{"title": "Mulher de Fases", "duration": 213000, "id": 1},
         {"title": "Mulher de Fases (A Linda)", "duration": 382000, "id": 2}]
ok(lidarr.pick_track(fases, "Mulher de fases", 213)["id"], 1, "duas com o mesmo nome: a de duração certa")
ok(lidarr.pick_track(fases, "Mulher de Fases (A Linda)", 380)["id"], 2, "e a versão longa pela duração")
idiot = [{"title": "Jesus of Suburbia", "duration": 549000, "absoluteTrackNumber": 2},
         {"title": "Holiday", "duration": 233000, "absoluteTrackNumber": 3},
         {"title": "Boulevard of Broken Dreams", "duration": 261000, "absoluteTrackNumber": 4}]
medley = "Holiday / Boulevard of Broken Dreams"
ok(lidarr.pick_track(idiot, medley, 493), None, "medley não casa com uma faixa só")
ok([t["absoluteTrackNumber"] for t in lidarr.pick_medley(idiot, medley, 493)], [3, 4],
   "medley = as duas faixas em sequência")
ok(lidarr.pick_medley(idiot, "Boulevard of Broken Dreams / Holiday", 493), None, "fora de ordem não junta")
ok(lidarr.pick_medley(idiot, medley, 300), None, "soma das durações não bate")
ok(lidarr.pick_medley(idiot, "Holiday", 233), None, "sem barra não é medley")
ok([t["absoluteTrackNumber"] for t in lidarr.pick_parts(idiot, medley, 493)], [3, 4], "pick_parts prefere o medley")
gabriel = [{"title": "Festa da Música / Bye Bye Tristeza / Devagar, Devagarinho", "duration": 300000,
            "absoluteTrackNumber": 1}, {"title": "Outra", "duration": 200000, "absoluteTrackNumber": 2}]
ok(len(lidarr.pick_parts(gabriel, gabriel[0]["title"], 300)), 1, "álbum com o medley numa faixa só: a própria")
ok(lidarr.pick_parts(arctic, "Brianstorm", 170), [], "faixa que não está no álbum")
ok(lidarr.local_path("/music/Djavan/Djavan (1989)/05 - Oceano.flac"),
   "/data/lidarr/Djavan/Djavan (1989)/05 - Oceano.flac", "caminho do Lidarr → montagem local")

print("=== álbum de estúdio pelo ISRC (MusicBrainz) ===")
from app.quality import musicbrainz


def rel(rg_id, title, primary="Album", secondary=None, date=None, status="Official"):
    return {"title": title, "date": date, "status": status,
            "release-group": {"id": rg_id, "title": title, "primary-type": primary,
                              "secondary-types": secondary}}

recs = [{"releases": [
    rel("hits", "Greatest Hits", secondary=["Compilation"], date="1981"),
    rel("opera", "A Night at the Opera", date="2011-03-14"),
    rel("opera", "A Night at the Opera", date="1975-11-21"),
    rel("single", "Bohemian Rhapsody", primary="Single", date="1975-10-31"),
    rel("live", "Live Killers", secondary=["Live"], date="1979"),
    rel("boot", "Bootleg", date="1970", status="Bootleg"),
]}]
picked = musicbrainz.pick_release_group(recs)
ok((picked["id"], picked["date"]), ("opera", "1975-11-21"), "álbum de estúdio, não coletânea/single/ao vivo")
ok(musicbrainz.pick_release_group([{"releases": [rel("hits", "100% Charlie Brown Jr", secondary=["Compilation"])]}]),
   None, "só coletâneas: fica o álbum do Spotify")
ok(musicbrainz.pick_release_group([{"releases": [rel("s", "Single", primary="Single", date="2020"),
                                                 rel("e", "EP", primary="EP", date="2021")]}])["id"],
   "e", "sem álbum: EP antes de single")
ok(asyncio.run(musicbrainz.studio_album(None)), None, "sem ISRC: nem consulta")

print("=== busca na Usenet: diária, depois semanal ===")
t0 = datetime(2026, 10, 1, tzinfo=timezone.utc)
ok(search_interval(t0, t0 + timedelta(days=1)), timedelta(days=1), "primeiros dias: todo dia")
ok(search_interval(t0, t0 + timedelta(days=30)), timedelta(days=7), "depois: toda semana")

print("=== orçamento do Lidarr ===")
from app.quality.upgrader import Budget
b = Budget(searches=2, slots=1)
ok((b.search(10), b.search(10), b.search(11), b.search(12)), (True, False, True, None),
   "uma busca por álbum por rodada; para no teto")
ok(Budget(5, 0).can_request(), False, "sem vaga: não pede álbum novo")
ok(Budget(0, 5).can_request(), False, "sem busca no orçamento: não pede")
b = Budget(searches=3, slots=1, reserve=2)
ok((b.search(20, repeat=True), b.search(21, repeat=True), b.search(22)), (True, None, True),
   "busca repetida para na reserva; pedido novo usa a reserva")
ok(b.can_request(), True, "reserva sobrando: ainda pede álbum novo")

print("=== Lidarr: fila travada ===")
blocked = {"trackedDownloadState": "importBlocked", "trackedDownloadStatus": "warning",
           "statusMessages": [{"title": "Album.2020.FLAC", "messages": ["Caution: Found executable file with extension: '.exe'"]}]}
ok(lidarr.stuck_reason(blocked), "Caution: Found executable file with extension: '.exe'", "importação bloqueada (.exe)")
ok(lidarr.stuck_reason({"trackedDownloadState": "downloading", "trackedDownloadStatus": "warning"}), None,
   "baixando com aviso: deixa andar")
ok(lidarr.stuck_reason({"trackedDownloadState": "importPending", "trackedDownloadStatus": "ok"}), None,
   "importação pendente sem aviso: deixa andar")
ok(lidarr.stuck_reason({"trackedDownloadState": "importPending", "trackedDownloadStatus": "warning",
                        "statusMessages": [{"title": "Sem faixas que casem"}]}), "Sem faixas que casem",
   "importação pendente com aviso: travou")
ok(lidarr.stuck_reason({"trackedDownloadState": "downloadFailedPending"}), "downloadFailedPending",
   "download falhou")

print("=== Deemix: do melhor formato para o pior ===")
tried = []


async def fake_download(deezer_id, bitrate):
    tried.append(bitrate)
    return (bitrate == deemix.MP3_320, Path("/tmp/x.mp3") if bitrate == deemix.MP3_320 else None)

real = deemix.download_track
deemix.download_track = fake_download
try:
    ok(asyncio.run(deemix.download_best("1", deemix.BEST)), (True, Path("/tmp/x.mp3")), "conta sem FLAC fica no 320")
    ok(tried, [deemix.FLAC, deemix.MP3_320], "tentou FLAC antes")
    tried.clear()
    ok(asyncio.run(deemix.download_best("1", deemix.ON_DEMAND))[0], True, "sob demanda começa no 320")
    ok(tried, [deemix.MP3_320], "não tenta FLAC sob demanda")
finally:
    deemix.download_track = real

from app.downloads import service as dl_service
asked = []


async def fake_best(deezer_id, formats):
    asked.append(list(formats))
    return False, None

real_best = deemix.download_best
deemix.download_best = fake_best
try:
    req = SimpleNamespace(title="x")
    asyncio.run(dl_service.deemix_into("t", "1", req, deemix.BEST, min_rank=audio_info.HIGH))
    ok(asked, [[deemix.FLAC]], "faixa já em 320: o upgrade só tenta FLAC")
    asked.clear()
    ok(asyncio.run(dl_service.deemix_into("t", "1", req, deemix.BEST, min_rank=audio_info.LOSSLESS)), None,
       "faixa já em FLAC: nem tenta")
    ok(asked, [], "nenhum download")
finally:
    deemix.download_best = real_best

print("=== Lidarr: apaga o álbum quando ninguém mais espera ===")
from app.config import settings
from app.quality import upgrader


class FakePool:
    def __init__(self, waiting):
        self.waiting = waiting

    async def fetchval(self, sql, *args):
        return self.waiting


class FakeLidarr:
    def __init__(self):
        self.calls = []

    async def monitor(self, ids, monitored=True):
        self.calls.append(("monitor", ids, monitored))

    async def trackfiles(self, album_id):
        return [{"id": 7}, {"id": 8}]

    async def delete_trackfiles(self, ids):
        self.calls.append(("delete", ids))


fake = FakeLidarr()
ok(asyncio.run(upgrader.finish_album(FakePool(True), fake, 25)), False, "outra faixa ainda espera o álbum")
ok(fake.calls, [], "nada muda no Lidarr")
ok(asyncio.run(upgrader.finish_album(FakePool(False), fake, 25)), True, "ninguém mais espera")
ok(fake.calls, [("monitor", [25], False), ("delete", [7, 8])], "desmonitora ANTES de apagar os arquivos")
keep = settings.lidarr_keep_albums
settings.lidarr_keep_albums = True
try:
    fake.calls.clear()
    asyncio.run(upgrader.finish_album(FakePool(False), fake, 25))
    ok(fake.calls, [("monitor", [25], False)], "LIDARR_KEEP_ALBUMS=true: mantém os arquivos")
finally:
    settings.lidarr_keep_albums = keep

print("=== versões da biblioteca ===")
ok(version_tuple("3.10.0") > version_tuple("3.9.2"), True, "3.10.0 > 3.9.2")
ok(version_tuple("3.9.2") > version_tuple("3.9.2"), False, "mesma versão não atualiza")

print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
