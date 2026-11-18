"""GET /api/me/playlists/containing: em quais playlists da pessoa a música
está (indicador do player), inclusive por outra fonte ou versão.

Uso: docker compose exec -T api python tests/test_containing.py
"""
from __future__ import annotations

import asyncio
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import asyncpg
from starlette.testclient import TestClient

from app.config import settings
from app.main import app

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


async def setup(tag):
    from app.auth.security import hash_password
    conn = await asyncpg.connect(settings.database_url)
    try:
        me = await conn.fetchval(
            "INSERT INTO users (username, name, password_hash) VALUES ($1, 'Eu', $2) RETURNING id",
            f"t_cont_me_{tag}", hash_password("senha-eu"))
        other = await conn.fetchval(
            "INSERT INTO users (username, name, password_hash) VALUES ($1, 'Outra', $2) RETURNING id",
            f"t_cont_ot_{tag}", hash_password("senha-ot"))
        song = await conn.fetchval(
            "INSERT INTO tracks (title, artist, duration_seconds, isrc) "
            "VALUES ('Lonely Day', 'System Of A Down', 167, $1) RETURNING id", f"TEST{tag}")
        await conn.execute(
            "INSERT INTO external_ids (provider, external_id, track_id) VALUES ('deezer', $1, $2)",
            f"dz{tag}", song)
        mine = await conn.fetchval(
            "INSERT INTO playlists (user_id, name) VALUES ($1, 'Rock in Metal') RETURNING id", me)
        shared = await conn.fetchval(
            "INSERT INTO playlists (user_id, name) VALUES ($1, 'Da Outra') RETURNING id", other)
        hidden = await conn.fetchval(
            "INSERT INTO playlists (user_id, name) VALUES ($1, 'Não é minha') RETURNING id", other)
        await conn.execute(
            "INSERT INTO playlist_members (playlist_id, user_id, role) VALUES ($1, $2, 'viewer')",
            shared, me)
        for p in (mine, shared, hidden):
            await conn.execute(
                "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES ($1, $2, 1)", p, song)
    finally:
        await conn.close()
    return str(song)


async def cleanup(tag, song):
    conn = await asyncpg.connect(settings.database_url)
    try:
        await conn.execute("DELETE FROM tracks WHERE id = $1", song)
        await conn.execute("DELETE FROM users WHERE username LIKE $1", f"t_cont_%_{tag}")
    finally:
        await conn.close()


def main():
    tag = secrets.token_hex(3)
    song = asyncio.run(setup(tag))
    try:
        with TestClient(app) as c:
            settings.password_login = "true"
            r = c.post("/api/auth/login", json={"username": f"t_cont_me_{tag}", "password": "senha-eu"})
            h = {"Authorization": "Bearer " + r.json()["access_token"]}

            def names(**q):
                r = c.get("/api/me/playlists/containing", headers=h, params=q)
                return [p["name"] for p in r.json()]

            print("=== em quais playlists ===")
            ok(names(title="Lonely Day", artist="System Of A Down", provider="deezer",
                     external_id=f"dz{tag}"),
               ["Da Outra", "Rock in Metal"], "minha e a que sou membro (não a dos outros)")
            ok(names(title="Lonely Day - 2005 Remaster", artist="System of a Down",
                     provider="ytmusic", external_id="outro"),
               ["Da Outra", "Rock in Metal"], "outra fonte e outra versão: mesma música")
            ok(names(title="Algo", artist="Ninguém", isrc=f"TEST{tag}"),
               ["Da Outra", "Rock in Metal"], "pelo ISRC")
            ok(names(title="Aerials", artist="System Of A Down"), [], "outra música: nenhuma")
            ok(c.get("/api/me/playlists/containing", params={"title": "x", "artist": "y"}).status_code,
               401, "exige login")
    finally:
        asyncio.run(cleanup(tag, song))
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
