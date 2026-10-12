"""Limpeza de cache. Remove arquivos com last_played_at (ou created_at) + TTL
e as versões convertidas (music/variants) sem uso há alguns dias."""
from __future__ import annotations
import asyncio
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import TYPE_CHECKING
from app.config import settings
from app.downloads import variants

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.storage")
_CLEANUP_INTERVAL = 3600


async def cleanup_once(pool: "asyncpg.Pool") -> int:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=settings.cache_ttl_hours)
    variants_removed = await asyncio.to_thread(variants.cleanup)
    if variants_removed:
        logger.info("[cleanup] %d versão(ões) convertida(s) sem uso removida(s)", variants_removed)
    rows = await pool.fetch(
        """SELECT id, track_id, path FROM files WHERE kind = 'cache' AND (
               (last_played_at IS NOT NULL AND last_played_at < $1)
               OR
               (last_played_at IS NULL AND created_at < $1)
           )""",
        cutoff,
    )
    if not rows:
        logger.info("[cleanup] nenhum expirado")
        return 0
    removed = 0
    for row in rows:
        p = Path(row["path"])
        try:
            if p.exists():
                p.unlink()
                logger.info("[cleanup] removido: %s", p.name)
        except OSError as exc:
            logger.warning("[cleanup] erro ao apagar %s: %s", p, exc)
        await pool.execute("DELETE FROM files WHERE id = $1", row["id"])
        variants.remove_for(str(row["track_id"]))
        removed += 1
    logger.info("[cleanup] %d removido(s)", removed)
    return removed


async def run_forever(pool: "asyncpg.Pool") -> None:
    logger.info("[cleanup] iniciado (intervalo=%ds, ttl=%dh)", _CLEANUP_INTERVAL, settings.cache_ttl_hours)
    while True:
        try:
            await cleanup_once(pool)
        except Exception as exc:
            logger.exception("[cleanup] erro: %s", exc)
        await asyncio.sleep(_CLEANUP_INTERVAL)