"""Aviso "playlists mudaram" para os aparelhos conectados.

Vai pelo WebSocket dos aparelhos (/api/devices/ws) para o dono e as pessoas
da playlist: o app atualiza a Biblioteca e a playlist aberta na hora, sem
esperar reabrir. Falhar aqui nunca derruba a alteração (o app também
atualiza ao voltar para a tela e no "Sincronizar agora").
"""
from __future__ import annotations

import logging

from app.devices.routes import notify_users

logger = logging.getLogger("bergastream.playlists")


async def audience(pool, playlist_ids) -> set[str]:
    """Dono e pessoas de cada playlist."""
    ids = [p for p in playlist_ids if p]
    if not ids:
        return set()
    rows = await pool.fetch(
        """SELECT user_id FROM playlists WHERE id = ANY($1::uuid[])
           UNION SELECT user_id FROM playlist_members WHERE playlist_id = ANY($1::uuid[])""",
        ids)
    return {str(r["user_id"]) for r in rows}


async def changed(pool, user_id: str, playlist_ids, people: set[str] | None = None) -> None:
    """Avisa quem fez a alteração e quem vê as playlists. [people]: quem
    via antes (playlist apagada já não tem membros para consultar)."""
    try:
        ids = sorted({str(p) for p in playlist_ids if p})
        users = {user_id, *(people or set()), *(await audience(pool, ids))}
        await notify_users(users, {"type": "playlists_changed", "playlists": ids})
    except Exception as exc:  # aviso é melhoria; a alteração já foi salva
        logger.info("[playlists] aviso de mudança não enviado: %s", exc)
