"""Serviço de resolução e registro de faixas.

Fluxo completo (Etapa 2):
1. Busca exata por (provider, external_id)
2. Se tem ISRC, busca por ISRC
3. Busca heurística (fuzzy): artista + título + duração ±3s
4. Se YouTube, extrai ISRC do vídeo via yt-dlp antes de decidir
5. Se match em qualquer passo: vincula external_id + retorna track existente
6. Se nada: cria nova faixa
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from app.tracks.models import PlayRequest, PlayResponse
from app.tracks import repository as repo

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.tracks.service")


async def resolve_and_register(
    pool: "asyncpg.Pool",
    req: PlayRequest,
) -> PlayResponse:
    """Resolve a faixa com prevenção de download duplicado cross-provider."""
    track = None

    # 1. Busca exata por (provider, external_id)
    track = await repo.get_track_by_external_id(pool, req.provider, req.external_id)
    if track:
        logger.info("[resolve] %s encontrada por (%s, %s)", track.id[:8], req.provider, req.external_id)

    # 2. Se não achou e tem ISRC, busca por ISRC
    if track is None and req.isrc:
        track = await repo.get_track_by_isrc(pool, req.isrc)
        if track:
            logger.info("[resolve] %s encontrada por ISRC %s", track.id[:8], req.isrc)

    # 3. Busca heurística (fuzzy): artista + título + duração ±3s
    if track is None:
        track = await repo.find_track_fuzzy(pool, req.title, req.artist, req.duration_seconds, tolerance=3)
        if track:
            logger.info("[resolve] %s encontrada por fuzzy match (%s - %s)", track.id[:8], req.artist, req.title)

    # 4. Se é YouTube e ainda não achou, tenta extrair ISRC do vídeo
    if track is None and req.provider in ("youtube", "ytmusic"):
        logger.info("[resolve] YouTube sem match — extraindo ISRC do video...")
        isrc = await _extract_isrc(req.external_id)
        if isrc:
            req.isrc = isrc
            track = await repo.get_track_by_isrc(pool, isrc)
            if track:
                logger.info("[resolve] %s encontrada por ISRC via yt-dlp (%s)", track.id[:8], isrc)

    # 5. Se encontrou em algum passo: vincula novo ID e retorna
    if track:
        # Vincula provider+external_id se ainda nao existir
        await repo.link_external_id(pool, track.id, req.provider, req.external_id)
        # Se o ISRC estava faltando no banco mas foi descoberto, atualiza
        if req.isrc and not track.isrc:
            await pool.execute("UPDATE tracks SET isrc = $1 WHERE id = $2", req.isrc, track.id)

        has_file = await repo.track_has_file(pool, track.id)
        status = "ready" if has_file else "registered"
        logger.info("[resolve] %s resolvida — status=%s", track.id[:8], status)
        return PlayResponse(track_id=track.id, status=status)

    # 6. Não achou — criar nova faixa
    track = await repo.create_track(
        pool,
        title=req.title,
        artist=req.artist,
        album=req.album or None,
        duration_seconds=req.duration_seconds,
        isrc=req.isrc or None,
        cover_url=req.cover_url or None,
    )
    await repo.link_external_id(pool, track.id, req.provider, req.external_id)
    logger.info("[resolve] %s criada (%s)", track.id[:8], req.provider)
    return PlayResponse(track_id=track.id, status="registered")


async def _extract_isrc(video_id: str) -> str | None:
    """Extrai ISRC de vídeo YouTube via yt-dlp (sem baixar áudio)."""
    import yt_dlp
    try:
        with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "ignoreerrors": True}) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
            if info:
                return info.get("isrc") or None
    except Exception:
        pass
    return None