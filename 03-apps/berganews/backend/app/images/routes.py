"""Imagens dos artigos pelo servidor: /api/img?u=<endereço>&s=<assinatura>.

O aparelho nunca fala com o site do veículo (sem rastreador, sem cookie, e
a imagem continua lá quando o site a apaga). Sem login: a <img> do app web
não manda o token; quem protege é a assinatura, feita só para endereços que
o servidor mesmo pôs num artigo, então isto não vira um proxy aberto.
O cache fica em CACHE_PATH (app/images/cache.py).
"""
from __future__ import annotations

import asyncio
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, status
from fastapi.responses import FileResponse, Response

from app.core import keys
from app.images import cache

router = APIRouter(prefix="/api", tags=["images"])

_HEADERS = {
    "Cache-Control": "public, max-age=604800, immutable",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox",
}
_locks: dict[str, asyncio.Lock] = {}


def _file(path: Path) -> FileResponse:
    media = next(t for t, ext in cache.TYPES.items() if ext == path.suffix)
    return FileResponse(path, media_type=media, headers=_HEADERS)


@router.get("/img")
async def image(u: str = Query(..., max_length=2000), s: str = Query(..., max_length=64)):
    if not keys.verify("img", u, s):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Link de imagem inválido")
    found = cache.cached(u)
    if found is not None:
        return _file(found)
    key = cache.digest(u)
    lock = _locks.setdefault(key, asyncio.Lock())
    async with lock:
        found = cache.cached(u)
        downloaded = None if found else await cache.download(u)
    _locks.pop(key, None)
    if found is not None:
        return _file(found)
    if downloaded is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Imagem indisponível")
    media, body = downloaded
    cache.store(u, media, body)
    return Response(body, media_type=media, headers=_HEADERS)
