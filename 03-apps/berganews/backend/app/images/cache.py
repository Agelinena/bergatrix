"""Cache das imagens das matérias, em CACHE_PATH/berganews/images.

Cada imagem é guardada pelo hash do endereço original. Quem usa:
- a API (/api/img), que baixa na primeira vez que alguém abre;
- o worker de coleta, que baixa na hora as imagens de uma matéria salva
  (para não sumirem se o site apagar) e, na limpeza diária, apaga as que
  nenhuma matéria guardada usa mais.
"""
from __future__ import annotations

import hashlib
import logging
import re
from pathlib import Path

from app.config import settings
from app.core import http

logger = logging.getLogger("berganews.images")

# Formatos que o Flutter decodifica em todo lugar (Android, web, computador).
# Sem "avif" no Accept: o CDN da Globo responde AVIF a quem aceita, e o app
# mostraria um quadrado cinza. SVG pode ter script: fica de fora.
ACCEPT = "image/webp,image/jpeg,image/png,image/gif;q=0.9,image/*;q=0.5"
TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp"}

_IMG_SRC = re.compile(r'<img[^>]+src="(https?://[^"]+)"')
_warned = False


def digest(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()


def base_path(url: str) -> Path:
    d = digest(url)
    return Path(settings.image_cache_dir) / d[:2] / d


def cached(url: str) -> Path | None:
    base = base_path(url)
    for ext in TYPES.values():
        candidate = base.with_suffix(ext)
        if candidate.exists():
            return candidate
    return None


def urls_in(html: str | None) -> list[str]:
    """Endereços originais das imagens de um HTML guardado (antes do /api/img)."""
    return [u.replace("&amp;", "&") for u in _IMG_SRC.findall(html or "")]


async def download(url: str, client=None) -> tuple[str, bytes] | None:
    """Baixa pela saída protegida; (tipo, bytes) ou None se não for imagem."""
    try:
        if client is None:
            async with http.client(timeout=15.0) as own:
                r, body = await http.get(own, url, settings.image_max_mb * 1024 * 1024,
                                         headers={"Accept": ACCEPT})
        else:
            r, body = await http.get(client, url, settings.image_max_mb * 1024 * 1024,
                                     headers={"Accept": ACCEPT})
    except http.FetchError as exc:
        logger.info("[img] %s: %s", url[:120], exc)
        return None
    kind = (r.headers.get("content-type") or "").split(";")[0].strip().lower()
    if r.status_code != 200 or kind not in TYPES or not body:
        return None
    return kind, body


def store(url: str, media: str, body: bytes) -> None:
    """Guarda no cache. Se não der (pasta sem permissão, disco cheio), a
    imagem sai do mesmo jeito e o log avisa uma vez."""
    global _warned
    target = base_path(url).with_suffix(TYPES[media])
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(".tmp")
        tmp.write_bytes(body)
        tmp.replace(target)
    except OSError as exc:
        if not _warned:
            _warned = True
            logger.warning("[img] cache de imagens sem gravação (%s): confira o dono de %s "
                           "(precisa ser 1000:1000)", exc, settings.image_cache_dir)


async def keep(url: str, client=None) -> bool:
    """Garante a imagem no cache (para matéria salva). True se ficou guardada."""
    if cached(url):
        return True
    got = await download(url, client)
    if got is None:
        return False
    store(url, *got)
    return cached(url) is not None


def prune(in_use: set[str]) -> int:
    """Apaga os arquivos cujo hash não está em [in_use] (nenhuma matéria
    guardada usa mais). Devolve quantos."""
    root = Path(settings.image_cache_dir)
    if not root.is_dir():
        return 0
    removed = 0
    for file in root.rglob("*"):
        if file.is_file() and file.stem not in in_use:
            file.unlink(missing_ok=True)
            removed += 1
    return removed
