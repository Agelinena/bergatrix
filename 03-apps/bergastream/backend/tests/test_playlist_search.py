"""Busca de playlists (sem rede): ordem, rádio primeiro, playlists do
Spotify bloqueadas fora, origem com erro não derruba as outras.

Uso: docker compose exec -T api python tests/test_playlist_search.py
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.search import playlists as pl
from app.search.models import PlaylistResult

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def item(provider, n, kind="playlist"):
    return PlaylistResult(provider=provider, external_id=f"{provider}{n}", title=f"{provider} {n}",
                          url=f"https://x/{provider}{n}", kind=kind)


class FakeSpotify:
    def search(self, q, type, limit):
        return {"playlists": {"items": [
            None,
            {"id": "ed1", "name": "This Is Scorpions", "owner": {"id": "spotify"}, "images": []},
            {"id": "u1", "name": "Rock do Fulano", "owner": {"id": "fulano", "display_name": "Fulano"},
             "tracks": {"total": 50}, "images": [{"url": "https://i.scdn.co/a"}]},
        ]}}


async def main():
    calls = {}

    def yt(query):
        calls["yt"] = query
        return [item("ytmusic", 1), item("ytmusic", 2)]

    async def dz(query):
        return [item("deezer", 1)]

    def sp(query):
        return [item("spotify", 1), item("spotify", 2), item("spotify", 3)]

    def radio(artist):
        calls["radio"] = artist
        return item("ytmusic", "R", kind="radio")

    pl._ytmusic, pl._deezer, pl._spotify, pl._radio = yt, dz, sp, radio

    print("=== ordem intercalada ===")
    res = await pl.search_playlists("rock anos 80")
    ok([r.external_id for r in res],
       ["ytmusic1", "deezer1", "spotify1", "ytmusic2", "spotify2", "spotify3"], "YT, Deezer, Spotify intercalados")
    ok("radio" in calls, False, "sem 'rádio', não busca rádio")

    print("=== rádio de artista ===")
    res = await pl.search_playlists("Rádio Scorpions")
    ok((res[0].kind, res[0].external_id), ("radio", "ytmusicR"), "rádio primeiro")
    ok(calls["radio"], "Scorpions", "rádio do artista certo")
    ok(calls["yt"], "Scorpions", "YouTube Music busca só o artista")
    await pl.search_playlists("radio queen")
    ok(calls["radio"], "queen", "'radio' sem acento também vale")

    print("=== origem com erro ===")
    async def broken(query):
        raise RuntimeError("fora do ar")
    pl._deezer = broken
    res = await pl.search_playlists("rock")
    ok([r.provider for r in res], ["ytmusic", "spotify", "ytmusic", "spotify", "spotify"], "Deezer fora não derruba")

    print("=== Spotify: playlists do próprio Spotify ficam de fora ===")
    from importlib import reload
    import app.search.playlists as fresh
    reload(fresh)
    original = fresh.spotify.client
    fresh.spotify.client = lambda: FakeSpotify()
    try:
        res = fresh._spotify("scorpions")
    finally:
        fresh.spotify.client = original
    ok([r.title for r in res], ["Rock do Fulano"], "editorial (dono spotify) descartada")
    ok((res[0].owner, res[0].track_count, res[0].url),
       ("Fulano", 50, "https://open.spotify.com/playlist/u1"), "dados da playlist")

    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


asyncio.run(main())
