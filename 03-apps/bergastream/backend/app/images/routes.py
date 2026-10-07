"""Proxy de imagens (capas) para o app web: GET /api/images?url=...

O Flutter web desenha imagens com fetch e precisa de CORS; nem toda origem
de capa manda o cabeçalho. O proxy busca a imagem, guarda em disco e serve
do próprio domínio. Só hosts de capas conhecidos (não é um proxy aberto).
"""
from __future__ import annotations

import hashlib
import logging
from pathlib import Path
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import FileResponse

from app.config import settings

logger = logging.getLogger("bergastream.images")
router = APIRouter(prefix="/api", tags=["images"])

_CACHE = Path(settings.music_dir) / "image_cache"
_MAX_BYTES = 5 * 1024 * 1024
_ALLOWED_SUFFIXES = (
    "scdn.co",              # Spotify (i.scdn.co, mosaic.scdn.co)
    "spotifycdn.com",
    "googleusercontent.com",  # YT Music
    "ytimg.com",            # YouTube
    "dzcdn.net",            # Deezer
)
_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}


def allowed(url: str) -> bool:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and any(
        host == s or host.endswith("." + s) for s in _ALLOWED_SUFFIXES)


@router.get("/images")
async def image(url: str = Query(min_length=10, max_length=2048)):
    """Pública: imagens da web não mandam cabeçalho de login, e capas não são
    dados sensíveis. Limitada a hosts de capas."""
    if not allowed(url):
        raise HTTPException(400, detail="Origem de imagem não permitida")
    key = hashlib.sha256(url.encode()).hexdigest()
    _CACHE.mkdir(parents=True, exist_ok=True)
    cached = next(iter(_CACHE.glob(f"{key}.*")), None)
    if cached is None:
        try:
            async with httpx.AsyncClient(timeout=15, follow_redirects=False) as cli:
                r = await cli.get(url)
        except httpx.HTTPError as exc:
            logger.info("[images] falhou %s: %s", url, exc)
            raise HTTPException(502, detail="Imagem indisponível")
        content_type = (r.headers.get("content-type") or "").split(";")[0].strip()
        if r.status_code != 200 or content_type not in _TYPES:
            raise HTTPException(404, detail="Imagem não encontrada")
        if len(r.content) > _MAX_BYTES:
            raise HTTPException(413, detail="Imagem grande demais")
        cached = _CACHE / f"{key}{_TYPES[content_type]}"
        cached.write_bytes(r.content)
    return FileResponse(cached, headers={"Cache-Control": "public, max-age=2592000"})
