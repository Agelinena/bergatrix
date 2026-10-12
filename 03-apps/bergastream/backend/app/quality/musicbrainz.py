"""Álbum de estúdio de uma faixa pelo ISRC (MusicBrainz).

O álbum que o Spotify informa pode ser uma coletânea ("100% Charlie Brown
Jr", "Greatest Hits"), que quase nunca está na Usenet e fica fora do perfil
de metadados do Lidarr. O ISRC identifica a gravação; o MusicBrainz lista
todos os lançamentos dela, e daí sai o álbum de estúdio original (o
`foreignAlbumId` do Lidarr é o id do release group do MusicBrainz).

O MusicBrainz aceita 1 pedido por segundo, com User-Agent identificado.
"""
from __future__ import annotations

import asyncio
import logging
import time

import httpx

logger = logging.getLogger("bergastream.quality.musicbrainz")

URL = "https://musicbrainz.org/ws/2/recording"
_UA = "Bergastream/0.3 (personal music server)"
_TYPES = {"Album": 0, "EP": 1, "Single": 2}  # preferência, sem tipos secundários
_lock = asyncio.Lock()
_last = 0.0


def pick_release_group(recordings: list[dict]) -> dict | None:
    """O release group de estúdio dos lançamentos oficiais da gravação:
    álbum antes de EP antes de single, sem tipo secundário (coletânea, ao
    vivo, trilha sonora, remix…) e, entre iguais, o lançado primeiro."""
    groups: dict[str, dict] = {}
    for rec in recordings:
        for rel in rec.get("releases") or []:
            if rel.get("status") not in (None, "Official"):
                continue
            rg = rel.get("release-group") or {}
            kind = _TYPES.get(rg.get("primary-type"))
            if not rg.get("id") or kind is None or rg.get("secondary-types"):
                continue
            date = rel.get("date") or "9999"
            seen = groups.get(rg["id"])
            if seen is None or date < seen["date"]:
                groups[rg["id"]] = {"id": rg["id"], "title": rg.get("title") or rel.get("title"),
                                    "kind": kind, "date": date}
    if not groups:
        return None
    return min(groups.values(), key=lambda g: (g["kind"], g["date"]))


async def studio_album(isrc: str | None) -> dict | None:
    """{"id": release group, "title": …} ou None (sem ISRC, sem cadastro, só
    coletâneas ou MusicBrainz fora do ar: aí vale o álbum do Spotify)."""
    global _last
    if not isrc:
        return None
    async with _lock:
        wait = 1.1 - (time.monotonic() - _last)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            async with httpx.AsyncClient(headers={"User-Agent": _UA}, timeout=20) as cli:
                r = await cli.get(URL, params={"query": f"isrc:{isrc}", "fmt": "json", "limit": 100})
            r.raise_for_status()
            recordings = r.json().get("recordings") or []
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("[musicbrainz] ISRC %s: %s %s", isrc, type(exc).__name__, exc)
            return None
        finally:
            _last = time.monotonic()
    return pick_release_group(recordings)
