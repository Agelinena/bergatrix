"""Cliente HTTP para endereços que vêm das pessoas (feeds, páginas, imagens).

Tudo passa pelo proxy de saída (smokescreen), que recusa destinos em redes
privadas, inclusive depois de um redirecionamento. Só http e https, com
limite de tamanho: um "feed" de 2 GB não derruba o worker.
"""
from __future__ import annotations

from urllib.parse import urlsplit

import httpx

from app.config import settings


REFUSED = "Endereço recusado: aponta para uma rede privada ou interna"


class FetchError(Exception):
    """Endereço inválido, recusado, grande demais ou fora do ar."""


def check_url(url: str) -> str:
    url = url.strip()
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise FetchError("Use um endereço http:// ou https://")
    if parts.username or parts.password:
        raise FetchError("Endereço com usuário e senha não é aceito")
    return url


def client(timeout: float = 20.0) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        proxy=settings.egress_proxy or None,
        timeout=httpx.Timeout(timeout, connect=10.0),
        follow_redirects=True,
        max_redirects=5,
        headers={"User-Agent": settings.user_agent,
                 "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8"},
        # O proxy é explícito: variáveis HTTP_PROXY do ambiente não mudam nada.
        trust_env=False,
    )


async def get(http: httpx.AsyncClient, url: str, max_bytes: int,
              headers: dict | None = None) -> tuple[httpx.Response, bytes]:
    """GET com teto de tamanho. Devolve a resposta (status, cabeçalhos, URL
    final) e o corpo; 304 vem com corpo vazio."""
    check_url(url)
    try:
        async with http.stream("GET", url, headers=headers or {}) as r:
            # O smokescreen responde 407 quando recusa o destino (http://).
            if r.status_code == 407:
                raise FetchError(REFUSED)
            if r.status_code == 304:
                return r, b""
            declared = r.headers.get("content-length")
            if declared and declared.isdigit() and int(declared) > max_bytes:
                raise FetchError("Arquivo grande demais")
            chunks, size = [], 0
            async for chunk in r.aiter_bytes():
                size += len(chunk)
                if size > max_bytes:
                    raise FetchError("Arquivo grande demais")
                chunks.append(chunk)
            return r, b"".join(chunks)
    except httpx.ProxyError as exc:
        raise FetchError(REFUSED + " (ou o proxy de saída está fora do ar)") from exc
    except httpx.HTTPError as exc:
        raise FetchError(f"Falha ao baixar: {exc.__class__.__name__}") from exc
