"""ISRC, álbum e capa de uma faixa do Spotify, sem conta.

A busca anônima não traz o ISRC (é ele que acha a mesma gravação no Deezer
para o download). O web player busca os metadados completos da faixa no
endpoint interno `spclient …/metadata/4/track/<gid>`, e o mesmo token anônimo
das páginas públicas de "embed" tem acesso a ele.

É um endpoint não documentado: se parar de responder, `track_details` devolve
None e o download procura a faixa no Deezer por artista + título + duração.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass

import httpx

logger = logging.getLogger("bergastream.search.spotify_meta")

_EMBED_URL = "https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC"
_META_URL = "https://spclient.wg.spotify.com/metadata/4/track/{gid}?market=from_token"
_COVER_URL = "https://i.scdn.co/image/{file_id}"
_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
_BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_TOKEN_RE = re.compile(r'"accessToken":"([^"]+)"')
_EXPIRY_RE = re.compile(r'"accessTokenExpirationTimestampMs":(\d+)')

_token: tuple[str, float] | None = None  # (token, expira em, epoch s)
_token_lock = asyncio.Lock()


@dataclass(frozen=True)
class TrackDetails:
    isrc: str | None
    album: str | None
    album_id: str | None
    year: int | None
    cover_url: str | None


def to_gid(track_id: str) -> str:
    """Id base62 do Spotify → gid hexadecimal de 32 dígitos."""
    number = 0
    for char in track_id:
        number = number * 62 + _BASE62.index(char)
    return f"{number:032x}"


def to_base62(gid: str) -> str:
    """Gid hexadecimal → id base62 de 22 caracteres."""
    number, chars = int(gid, 16), []
    while number:
        number, rest = divmod(number, 62)
        chars.append(_BASE62[rest])
    return "".join(reversed(chars)).rjust(22, "0")


def parse_details(data: dict) -> TrackDetails:
    isrc = next((e.get("id") for e in data.get("external_id") or []
                 if e.get("type") == "isrc" and e.get("id")), None)
    album = data.get("album") or {}
    images = (album.get("cover_group") or {}).get("image") or []
    cover = next((i for i in images if i.get("size") == "LARGE"), images[0] if images else None)
    return TrackDetails(
        isrc=isrc.upper() if isrc else None,
        album=album.get("name") or None,
        album_id=to_base62(album["gid"]) if album.get("gid") else None,
        year=(album.get("date") or {}).get("year"),
        cover_url=_COVER_URL.format(file_id=cover["file_id"]) if cover and cover.get("file_id") else None,
    )


async def _anonymous_token(cli: httpx.AsyncClient, refresh: bool = False) -> str:
    global _token
    async with _token_lock:
        if _token and not refresh and _token[1] - 60 > time.time():
            return _token[0]
        html = (await cli.get(_EMBED_URL)).text
        match = _TOKEN_RE.search(html)
        if not match:
            raise RuntimeError("página de embed do Spotify sem token")
        expiry = _EXPIRY_RE.search(html)
        expires = int(expiry.group(1)) / 1000 if expiry else time.time() + 1800
        _token = (match.group(1), expires)
        return _token[0]


async def track_details(track_id: str) -> TrackDetails | None:
    """Metadados da faixa, ou None se o Spotify não responder."""
    try:
        gid = to_gid(track_id)
    except ValueError:
        return None
    try:
        async with httpx.AsyncClient(headers={"User-Agent": _UA}, timeout=15,
                                     follow_redirects=True) as cli:
            for attempt in (1, 2):
                token = await _anonymous_token(cli, refresh=attempt == 2)
                r = await cli.get(_META_URL.format(gid=gid), headers={
                    "Authorization": f"Bearer {token}", "Accept": "application/json"})
                if r.status_code == 401 and attempt == 1:
                    continue  # token vencido antes da hora: pega outro
                if r.status_code != 200:
                    logger.warning("[spotify-meta] %s: HTTP %s", track_id, r.status_code)
                    return None
                return parse_details(r.json())
    except Exception as exc:
        logger.warning("[spotify-meta] %s falhou: %s", track_id, exc)
    return None
