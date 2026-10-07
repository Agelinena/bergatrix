"""Testes da paginação e deduplicação das páginas de artista (sem rede).

Uso: docker compose exec -T api python tests/test_catalog.py
"""
from __future__ import annotations

import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.catalog import service
from app.search.models import SearchResult

P = F = 0


def ok(a, b, m):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def t(n: int, isrc: str | None = None, album: str = "") -> SearchResult:
    return SearchResult(provider="spotify", external_id=f"id{n}", title=f"Faixa {n}",
                        artist="A", album=album, duration_seconds=100 + n, isrc=isrc)


print("=== page_of ===")
items = [t(i) for i in range(120)]
p1 = service.page_of(items, 0, 50)
ok((len(p1.items), p1.next_offset, p1.total), (50, 50, 120), "primeira página")
p3 = service.page_of(items, 100, 50)
ok((len(p3.items), p3.next_offset), (20, None), "última página para")
ok(service.page_of(items, 0, 500).items.__len__(), 50, "limite máximo 50")
ok(service.page_of(items, 200, 50).items, [], "offset além do fim: vazio")

print("=== dedupe ===")
dup = [t(1, "ISRC1"), t(2), t(1, "ISRC1", "Deluxe"), t(2)]
ok([x.external_id for x in service.dedupe(dup)], ["id1", "id2"], "mesma música em vários álbuns aparece uma vez")

print("=== todas as faixas do Spotify (álbum por álbum) ===")
albums = [{"id": f"al{i}", "total_tracks": 30} for i in range(5)]  # 150 faixas
tracks_by_album = {f"al{i}": [t(i * 30 + j, f"I{i * 30 + j}") for j in range(30)] for i in range(5)}
loaded: list[str] = []


def fake_full(album_id):
    loaded.append(album_id)
    return ({}, tracks_by_album[album_id])


with mock.patch.object(service, "_spotify_albums", return_value=albums), \
        mock.patch.object(service, "_spotify_album_full", side_effect=fake_full):
    seen: set[str] = set()
    offset, pages = 0, 0
    while offset is not None and pages < 10:
        loaded.clear()
        page = service.spotify_artist_tracks("art", offset, 50)
        ids = [x.external_id for x in page.items]
        ok(len(seen & set(ids)), 0, f"página {pages + 1} sem repetir faixas")
        seen |= set(ids)
        if pages == 0:
            ok(loaded, ["al0", "al1"], "primeira página só carrega os álbuns necessários")
        offset = page.next_offset
        pages += 1
    ok(len(seen), 150, "todas as 150 faixas vistas")
    ok(pages, 3, "para quando acabam (3 páginas)")

print("=== Deezer: artista, álbum e todas as faixas ===")
from app.search import deezer as dz


def dz_track(n, album=None):
    return {"id": 1000 + n, "title": f"Faixa {n}", "duration": 200, "isrc": f"DZ{n}",
            "artist": {"id": 7, "name": "Scorpions"},
            "album": album or {"id": 100 + n // 20, "title": f"Álbum {n // 20}", "cover_xl": "https://dz/c.jpg"}}


def fake_get(path, **params):
    if path == "/artist/7":
        return {"id": 7, "name": "Scorpions", "picture_xl": "https://dz/p.jpg", "nb_fan": 1000}
    if path == "/artist/7/top":
        return {"data": [dz_track(i) for i in range(3)]}
    if path == "/artist/7/albums":
        return {"data": [{"id": 100 + i, "title": f"Álbum {i}", "nb_tracks": 20,
                          "release_date": "1990-01-01", "artist": {"name": "Scorpions"}} for i in range(4)]}
    if path.startswith("/album/"):
        aid = int(path.split("/")[-1])
        album = {"id": aid, "title": f"Álbum {aid - 100}", "release_date": "1990-01-01",
                 "artist": {"id": 7, "name": "Scorpions"}, "cover_xl": "https://dz/c.jpg"}
        album["tracks"] = {"data": [dz_track((aid - 100) * 20 + j, album) for j in range(20)]}
        return album
    if path == "/artist/404":
        raise dz.DeezerError("no data")
    raise AssertionError(path)


with mock.patch.object(dz, "get", side_effect=fake_get):
    page = service.artist("deezer", "7")
    ok((page.name, page.followers, len(page.top_tracks), len(page.albums)),
       ("Scorpions", 1000, 3, 4), "artista do Deezer")
    ok((page.top_tracks[0].provider, page.top_tracks[0].artist_id), ("deezer", "7"),
       "faixa do Deezer com id do artista")
    album = service.album("deezer", "101")
    ok((album.title, album.year, album.artist_id, len(album.tracks)), ("Álbum 1", "1990", "7", 20),
       "álbum do Deezer")
    first = service.artist_tracks("deezer", "7", 0, 50)
    ok((len(first.items), first.next_offset, first.total), (50, 50, 80), "todas as faixas: 1ª página")
    last = service.artist_tracks("deezer", "7", 50, 50)
    ok((len(last.items), last.next_offset), (30, None), "última página")
    try:
        service.artist("deezer", "404")
        ok(True, False, "artista inexistente")
    except service.NotFound:
        ok(True, True, "artista inexistente vira 404")

print("=== Deezer: busca completa ===")


def fake_search(path, **params):
    if path == "/search":
        return {"data": [dz_track(1), {**dz_track(2), "readable": False}]}
    if path == "/search/artist":
        return {"data": [{"id": 7, "name": "Scorpions", "picture_xl": "https://dz/p.jpg"}]}
    if path == "/search/album":
        return {"data": [{"id": 101, "title": "Crazy World", "artist": {"name": "Scorpions"},
                          "release_date": "1990-11-06"}]}
    raise AssertionError(path)


with mock.patch.object(dz, "get", side_effect=fake_search):
    full = dz.search_full("scorpions")
    ok(([t.title for t in full.tracks], full.artists[0].provider, full.albums[0].year),
       (["Faixa 1"], "deezer", "1990"), "músicas (sem as indisponíveis), artistas e álbuns")

print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
