"""Imagens dos artigos pelo servidor: /api/img?u=<endereço>&s=<assinatura>.

O aparelho nunca fala com o site do veículo (sem rastreador, sem cookie, e
a imagem continua lá quando o site a apaga). Sem login: a <img> do app web
não manda o token; quem protege é a assinatura, feita só para endereços que
o servidor mesmo pôs num artigo, então isto não vira um proxy aberto.
Cache em CACHE_PATH (recriável), com a pasta limpa pelo worker.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, status
from fastapi.responses import FileResponse

from app.config import settings
from app.core import http, keys

logger = logging.getLogger("berganews.images")
router = APIRouter(prefix="/api", tags=["images"])

# SVG pode ter script e seria servido do nosso domínio: fica de fora.
_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
          "image/avif": ".avif"}
_HEADERS = {
    "Cache-Control": "public, max-age=604800, immutable",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox",
}
_locks: dict[str, asyncio.Lock] = {}


def _path(url: str) -> Path:
    digest = hashlib.sha256(url.encode()).hexdigest()
    return Path(settings.image_cache_dir) / digest[:2] / digest


def _cached(base: Path) -> Path | None:
    for ext in _TYPES.values():
        candidate = base.with_suffix(ext)
        if candidate.exists():
            return candidate
    return None


@router.get("/img")
async def image(u: str = Query(..., max_length=2000), s: str = Query(..., max_length=64)):
    if not keys.verify("img", u, s):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Link de imagem inválido")
    base = _path(u)
    found = _cached(base)
    if found is None:
        lock = _locks.setdefault(base.name, asyncio.Lock())
        async with lock:
            found = _cached(base) or await _download(u, base)
        _locks.pop(base.name, None)
    if found is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="Imagem indisponível")
    media = next(t for t, ext in _TYPES.items() if ext == found.suffix)
    return FileResponse(found, media_type=media, headers=_HEADERS)


async def _download(url: str, base: Path) -> Path | None:
    try:
        async with http.client(timeout=15.0) as client:
            r, body = await http.get(client, url, settings.image_max_mb * 1024 * 1024,
                                     headers={"Accept": "image/avif,image/webp,image/*;q=0.8"})
    except http.FetchError as exc:
        logger.info("[img] %s: %s", url[:120], exc)
        return None
    kind = (r.headers.get("content-type") or "").split(";")[0].strip().lower()
    if r.status_code != 200 or kind not in _TYPES or not body:
        return None
    target = base.with_suffix(_TYPES[kind])
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    tmp.write_bytes(body)
    tmp.replace(target)
    return target
