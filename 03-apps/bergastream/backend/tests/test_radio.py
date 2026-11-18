"""Rádio: cruzamento das fontes, filtros, ordem, controle de chamadas.
Sem rede: as fontes são trocadas por respostas fixas.

Uso: docker compose exec -T api python tests/test_radio.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import asyncpg
from starlette.testclient import TestClient

from app.config import settings
from app.core.redis import get_redis
from app.main import app
from app.radio import guard, match, sources

P = F = 0


def arun(coro):
    """asyncio.run e solta a conexão do Redis (ela fica presa ao loop)."""
    import app.core.redis as r
    try:
        return asyncio.run(coro)
    finally:
        r._pool = None


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def t(artist, title, provider="ytmusic", ext=None, album=""):
    return {"provider": provider, "external_id": ext or f"{artist[:3]}{title[:5]}".replace(" ", "_"),
            "title": title, "artist": artist, "album": album, "duration_seconds": 200}


SEED = t("System Of A Down", "Lonely Day", ext="seedvid0001")
CALLS: dict[str, int] = {}


def fake_yt(seed):
    CALLS["yt"] = CALLS.get("yt", 0) + 1
    if seed.title == "Aerials":  # a recente traz músicas próprias
        return {"tracks": [t("Deftones", "Change"), t("Korn", "Freak On a Leash")]}
    return {"tracks": [
        t("Linkin Park", "Numb (Live at Milton Keynes)"),     # versão: a normal vem do Deezer
        t("Linkin Park", "Numb - 2014 Remaster"),
        t("Linkin Park", "In the End"),
        t("Papa Roach", "Last Resort"),
        t("Disturbed", "Down with the Sickness (Live)"),   # versão ao vivo: fora
        t("Anitta", "Envolver"),                            # ninguém confirma: fora
        t("Slipknot", "Duality"),                           # já ouvida no histórico
        t("Korn", "Blind"),                                 # na lista exclude
        t("Breaking Benjamin", "Diary of Jane"),
        t("Deftones", "My Own Summer"),
    ]}


def fake_lf_tracks(artist, title):
    if title == "Aerials":
        return {"tracks": []}
    return {"tracks": [
        {"artist": "Papa Roach", "title": "Last Resort", "match": 0.9, "duration": 199},
        {"artist": "Linkin Park", "title": "Numb", "match": 0.8, "duration": 185},
        {"artist": "Chevelle", "title": "The Red", "match": 0.7, "duration": 238},  # só nome: resolver
    ]}


def fake_lf_artist(artist):
    return {"artists": [{"name": n, "match": m, "mbid": ""} for n, m in [
        ("Linkin Park", 0.9), ("Papa Roach", 0.8), ("Disturbed", 0.8), ("Chevelle", 0.6),
        ("Breaking Benjamin", 0.6), ("Deftones", 0.5), ("Korn", 0.6), ("Slipknot", 0.7)]],
        "tags": ["nu metal", "alternative metal", "metal"], "mbid": ""}


def fake_dz(seed):
    return {"artists": ["Linkin Park", "Deftones"], "tracks": [t("Linkin Park", "Numb", "deezer", "999")]}


RESOLVED: list[str] = []


def fake_resolve(artist, title, duration=0):
    RESOLVED.append(title)
    return t(artist, title, ext="chevelle001")


async def flush(pattern="radio:*"):
    """Limpa com uma conexão própria (a do app é do loop do TestClient)."""
    import redis.asyncio as aioredis
    redis = aioredis.from_url(settings.redis_url, decode_responses=True)
    try:
        keys = await redis.keys(pattern)
        if keys:
            await redis.delete(*keys)
    finally:
        await redis.aclose()


async def setup(tag):
    from app.auth.security import hash_password
    conn = await asyncpg.connect(settings.database_url)
    try:
        uid = await conn.fetchval(
            "INSERT INTO users (username, name, password_hash) VALUES ($1, $2, $3) RETURNING id",
            f"t_radio_{tag}", "Rádio", hash_password("senha-radio"))
        track = await conn.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds) VALUES ('Duality', 'Slipknot', 250) RETURNING id")
        await conn.execute(
            "INSERT INTO play_history (user_id, track_id, client_id, played_at) VALUES ($1, $2, gen_random_uuid(), now())",
            uid, track)
    finally:
        await conn.close()
    return str(uid), str(track)


async def cleanup(tag, track):
    conn = await asyncpg.connect(settings.database_url)
    try:
        await conn.execute("DELETE FROM tracks WHERE id = $1", track)
        await conn.execute("DELETE FROM users WHERE username = $1", f"t_radio_{tag}")
    finally:
        await conn.close()


def unit():
    print("=== normalização ===")
    ok(match.key("System of a Down", "Chop Suey! - 2015 Remaster"), match.key("System Of A Down", "Chop Suey!"),
       "remaster é a mesma música")
    ok(match.key("The Offspring, Someone", "Self Esteem (feat. X)"), "offspring|selfesteem", "sem 'the', feat e convidados")
    ok(match.versions("Down with the Sickness (Live)"), {"live"}, "ao vivo detectado")
    ok(match.versions("Numb"), set(), "versão normal")

    print("=== ordem sorteada, mesmo artista espalhado ===")
    import random
    from app.radio import service
    cands = [service.Candidate("Armandinho", f"A{i}", score=5.0) for i in range(6)] + \
            [service.Candidate(f"Outro {i}", f"O{i}", score=2.0) for i in range(8)]
    patterns = set()
    for seed in range(30):
        service._rng = random.Random(seed)
        order = service._spread(cands, None)
        arts = [c.artist_key for c in order]
        if any(a == b for a, b in zip(arts, arts[1:])):
            patterns.add("seguido")
        patterns.add(tuple(i for i, a in enumerate(arts) if a == "armandinho"))
    ok("seguido" in patterns, False, "nunca o mesmo artista seguido")
    ok(len(patterns) > 10, True, "as posições do artista variam (sem padrão fixo)")
    service._rng = random.Random()

    print("=== disjuntor ===")

    async def breaker():
        src = guard.Source("teste", failures_to_open=2, open_seconds=60)

        def boom():
            raise RuntimeError("caiu")
        for _ in range(2):
            try:
                await src.call(boom)
            except RuntimeError:
                pass
        try:
            await src.call(lambda: 1)
            return "chamou"
        except guard.SourceDown:
            return "fora"
    ok(arun(breaker()), "fora", "fonte com 2 falhas fica fora")

    print("=== pedido novo cancela o anterior ===")

    async def latest():
        async def slow():
            await asyncio.sleep(2)
            return "velho"

        async def fast():
            return "novo"
        first = asyncio.ensure_future(guard.run_latest("u1", slow()))
        await asyncio.sleep(0.05)
        second = await guard.run_latest("u1", fast())
        try:
            await first
            return ("velho terminou", second)
        except asyncio.CancelledError:
            return ("velho cancelado", second)
    ok(arun(latest()), ("velho cancelado", "novo"), "o anterior é cancelado")

    print("=== mesma semente em paralelo: uma chamada só ===")

    async def single_flight():
        await flush()
        calls = 0

        async def produce():
            nonlocal calls
            calls += 1
            await asyncio.sleep(0.2)
            return {"v": 1}
        results = await asyncio.gather(*(guard.cached("radio:test:sf", 60, produce) for _ in range(5)))
        return calls, results[0]
    ok(arun(single_flight()), (1, {"v": 1}), "5 pedidos, 1 chamada")


def main():
    unit()
    sources.ytmusic_radio = fake_yt
    sources.lastfm_similar_tracks = fake_lf_tracks
    sources.lastfm_artist = fake_lf_artist
    sources.deezer_radio = fake_dz
    sources.listenbrainz_similar = lambda mbid: {"artists": []}
    sources.resolve = fake_resolve
    sources.lastfm_tags = lambda artist: ["nu metal"] if artist != "Anitta" else ["pop", "funk"]
    settings.lastfm_api_key = "teste"
    for s in guard.SOURCES.values():
        s.reset()
    arun(flush())

    tag = secrets.token_hex(3)
    _, track = arun(setup(tag))
    try:
        with TestClient(app) as c:
            settings.password_login = "true"
            r = c.post("/api/auth/login", json={"username": f"t_radio_{tag}", "password": "senha-radio"})
            h = {"Authorization": "Bearer " + r.json()["access_token"]}

            print("=== cruzamento ===")
            body = {"seed": SEED, "exclude": [{"artist": "Korn", "title": "Blind"}], "count": 10}
            r = c.post("/api/radio", headers=h, json=body)
            ok(r.status_code, 200, "rádio responde")
            got = r.json()
            names = [x["title"] for x in got["tracks"]]
            print("    leva:", [(x["artist"], x["title"]) for x in got["tracks"]])
            ok({"Numb", "Last Resort"} <= set(names), True, "as que aparecem em várias fontes entram")
            ok(names.count("Numb"), 1, "Numb ao vivo e Numb normal contam como uma só")
            ok("Envolver" in names, False, "artista que nenhuma fonte confirma fica fora")
            ok(any("Live" in n for n in names), False, "versão ao vivo fica fora")
            ok("Duality" in names, False, "já ouvida no histórico fica fora")
            ok("Blind" in names, False, "o que o app mandou excluir fica fora")
            ok("The Red" in names, True, "música só do Last.fm é resolvida e entra")
            ok(RESOLVED, ["The Red"], "só a que vai entrar é procurada")
            arts = [match.norm_artist(x["artist"]) for x in got["tracks"]]
            ok(any(a == b for a, b in zip(arts, arts[1:])), False, "nunca o mesmo artista seguido")
            ok(sorted(arts).count("linkinpark") >= 2, True, "o mesmo artista pode voltar (sem limite)")
            ok(got["sources"].get("ytmusic"), "ok", "status das fontes")

            print("=== cache ===")
            before = CALLS.get("yt", 0)
            c.post("/api/radio", headers=h, json=body)
            ok(CALLS.get("yt", 0), before, "segunda leva da mesma semente vem do cache")

            print("=== recentes e pulos ===")
            body2 = {"seed": SEED, "recent": [t("System Of A Down", "Aerials")],
                     "skipped": {"Papa Roach": 2}, "last_artist": "Linkin Park", "count": 10}
            got = c.post("/api/radio", headers=h, json=body2).json()
            names = [x["title"] for x in got["tracks"]]
            ok("Change" in names, True, "a recente traz músicas novas")
            ok("Last Resort" in names, False, "artista pulado 2 vezes sai")
            ok(match.norm_artist(got["tracks"][0]["artist"]) != "linkinpark", True,
               "a leva não começa pelo último artista da fila")

            print("=== limite por pessoa ===")
            settings.radio_per_minute = 2
            codes = [c.post("/api/radio", headers=h, json=body).status_code for _ in range(3)]
            ok(codes[-1], 429, "passou do limite: 429")
            ok(c.post("/api/radio", headers=h, json=body).json()["detail"],
               "Muitas rádios seguidas. Espere um pouco.", "mensagem amigável")
            settings.radio_per_minute = 20

            print("=== fonte fora não derruba a rádio ===")
            arun(flush())
            guard.SOURCES["lastfm"].open_until = time.monotonic() + 60
            arun(flush("radio:rate:*"))
            got = c.post("/api/radio", headers=h, json=body).json()
            ok(got["sources"].get("lastfm"), "fora", "Last.fm marcado como fora")
            ok(len(got["tracks"]) > 0, True, "a rádio segue com as outras fontes")
            guard.SOURCES["lastfm"].reset()
    finally:
        arun(cleanup(tag, track))
        arun(flush())
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
