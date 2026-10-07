"""Teste de ciclo de vida da permanência (Etapa 2).

Uso: docker compose exec -T api python tests/test_permanence.py
"""
from __future__ import annotations
import asyncio
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from app.config import settings
from app.core.db import create_pool, close_pool
from app.core.redis import get_redis, close_redis
from app.tracks import repository as track_repo
from app.tracks.models import PlayRequest
from app.tracks import service as tracks_service
from app.playlists.repository import add_track_to_playlist, remove_track_from_playlist, get_track_playlist_count
from app.users.repository import get_users


async def test():
    print("=== Teste de Permanência ===")
    pool = await create_pool()
    r = await get_redis()

    # 1. Mock de download de faixa
    req = PlayRequest(
        provider="youtube",
        external_id="test_video_id",
        title="Test Song",
        artist="Test Artist",
        duration_seconds=180,
    )
    result = await tracks_service.resolve_and_register(pool, req)
    track_id = result.track_id
    print(f"1. Faixa criada: {track_id} (status={result.status})")

    # Simula download concluído (insere na tabela files)
    await pool.execute(
        "INSERT INTO files (track_id, path, size_bytes, format, kind) VALUES ($1, $2, 1000, 'mp3_192', 'cache')",
        track_id, f"/data/music/cache/{track_id}.mp3",
    )
    print("   Download mockado (kind=cache)")

    # 2. Busca usuarios e playlists
    users = await get_users(pool)
    print(f"   Usuarios: {[u.name for u in users]}")

    # Pega as playlists
    user_a_playlist = await pool.fetchrow(
        "SELECT p.id FROM playlists p JOIN users u ON u.id=p.user_id WHERE u.name='User A'"
    )
    user_b_playlist = await pool.fetchrow(
        "SELECT p.id FROM playlists p JOIN users u ON u.id=p.user_id WHERE u.name='User B'"
    )
    pl_a = user_a_playlist["id"]
    pl_b = user_b_playlist["id"]

    # 3. Adicionar ao User A -> permanent
    await add_track_to_playlist(pool, pl_a, track_id)
    kind = await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_id)
    assert kind == "permanent", f"Esperava permanent, obteve {kind}"
    print(f"2. Adicionado ao User A -> kind={kind} OK")

    # 4. Adicionar ao User B -> continua permanent
    await add_track_to_playlist(pool, pl_b, track_id)
    kind = await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_id)
    assert kind == "permanent", f"Esperava permanent, obteve {kind}"
    print(f"3. Adicionado ao User B -> kind={kind} OK")

    # 5. Remover do User A -> continua permanent (ainda no User B)
    await remove_track_from_playlist(pool, pl_a, track_id)
    kind = await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_id)
    remaining = await get_track_playlist_count(pool, track_id)
    assert kind == "permanent", f"Esperava permanent, obteve {kind}"
    assert remaining == 1
    print(f"4. Removido User A -> kind={kind}, playlists_restantes={remaining} OK")

    # 6. Remover do User B -> vira cache e last_played_at atualizado
    await remove_track_from_playlist(pool, pl_b, track_id)
    kind = await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_id)
    last = await pool.fetchval("SELECT last_played_at FROM files WHERE track_id=$1", track_id)
    remaining = await get_track_playlist_count(pool, track_id)
    assert kind == "cache", f"Esperava cache, obteve {kind}"
    assert last is not None, "last_played_at deveria estar preenchido"
    assert remaining == 0
    print(f"5. Removido User B -> kind={kind}, last_played_at={last}, restantes={remaining} OK")

    # 7. Re-adicionar ao User A -> volta a permanent
    await add_track_to_playlist(pool, pl_a, track_id)
    kind = await pool.fetchval("SELECT kind FROM files WHERE track_id=$1", track_id)
    assert kind == "permanent", f"Esperava permanent, obteve {kind}"
    print(f"6. Re-adicionado User A -> kind={kind} OK")

    # Limpeza
    await pool.execute("DELETE FROM files WHERE track_id=$1", track_id)
    await pool.execute("DELETE FROM playlist_tracks WHERE track_id=$1", track_id)
    await pool.execute("DELETE FROM external_ids WHERE track_id=$1", track_id)
    await pool.execute("DELETE FROM tracks WHERE id=$1", track_id)

    await close_pool()
    await close_redis()
    print("\n=== Todos os testes passaram! ===")


if __name__ == "__main__":
    asyncio.run(test())