"""Permanência dos arquivos de áudio no servidor.

Faixa em alguma playlist é *permanente*: `files.kind = 'permanent'` e o
arquivo fica em `music/permanent/`. Faixa fora de todas as playlists é
*cache*: `kind = 'cache'`, arquivo em `music/cache/`, e a limpeza apaga
depois de `CACHE_TTL_HOURS` sem tocar.

A marcação e a pasta mudam juntas, sempre por [sync_permanence]: ao
adicionar/remover de playlist e ao terminar um download (a faixa pode ter
entrado na playlist antes de o arquivo existir).
"""
from __future__ import annotations

import asyncio
import logging
import shutil
from pathlib import Path
from typing import TYPE_CHECKING

from app.config import settings

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.storage.permanence")

CACHE_DIR = Path(settings.music_dir) / "cache"
PERMANENT_DIR = Path(settings.music_dir) / "permanent"


async def in_any_playlist(pool: "asyncpg.Pool", track_id: str) -> bool:
    return bool(await pool.fetchval(
        "SELECT EXISTS (SELECT 1 FROM playlist_tracks WHERE track_id = $1)", track_id))


async def sync_permanence(pool: "asyncpg.Pool", track_id: str) -> str | None:
    """Ajusta marcação e pasta do arquivo da faixa conforme as playlists.
    Devolve o `kind` resultante (nulo se a faixa ainda não tem arquivo)."""
    row = await pool.fetchrow("SELECT path, kind FROM files WHERE track_id = $1", track_id)
    if row is None:
        return None
    permanent = await in_any_playlist(pool, track_id)
    kind = "permanent" if permanent else "cache"
    path = Path(row["path"])
    target = PERMANENT_DIR if permanent else CACHE_DIR
    # Só move o que está nas pastas do app (cache ↔ permanent).
    if path.parent in (CACHE_DIR, PERMANENT_DIR) and path.parent != target and path.exists():
        destination = target / path.name
        try:
            target.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.move, str(path), str(destination))
            path = destination
            logger.info("[permanência] %s → %s/", path.name, target.name)
        except OSError as exc:
            logger.warning("[permanência] não moveu %s: %s", path, exc)
    if kind == row["kind"] and str(path) == row["path"]:
        return kind
    if permanent:
        await pool.execute("UPDATE files SET kind = 'permanent', path = $2 WHERE track_id = $1",
                           track_id, str(path))
    else:
        # Volta a ser cache com o timer zerado (Seção "Ciclo de vida").
        await pool.execute(
            "UPDATE files SET kind = 'cache', path = $2, last_played_at = now() WHERE track_id = $1",
            track_id, str(path))
    return kind


async def reconcile(pool: "asyncpg.Pool") -> int:
    """Conserta marcação e pasta de todos os arquivos (ao subir a API).
    Devolve quantos foram corrigidos."""
    rows = await pool.fetch(
        """SELECT f.track_id, f.kind, f.path,
                  EXISTS (SELECT 1 FROM playlist_tracks pt WHERE pt.track_id = f.track_id) AS listed
           FROM files f""")
    fixed = 0
    for r in rows:
        want_dir = PERMANENT_DIR if r["listed"] else CACHE_DIR
        parent = Path(r["path"]).parent
        wrong_kind = r["kind"] != ("permanent" if r["listed"] else "cache")
        wrong_dir = parent in (CACHE_DIR, PERMANENT_DIR) and parent != want_dir
        if wrong_kind or wrong_dir:
            await sync_permanence(pool, str(r["track_id"]))
            fixed += 1
    if fixed:
        logger.info("[permanência] %d arquivo(s) corrigido(s)", fixed)
    return fixed
