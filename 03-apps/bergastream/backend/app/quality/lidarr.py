"""Cliente mínimo da API v1 do Lidarr (FLAC pela Usenet; serviço `lidarr`
do compose do Bergastream).

O Lidarr trabalha por ÁLBUM (lançamentos na Usenet são álbuns ou singles):
para uma faixa de playlist, o Bergastream acha o álbum dela no MusicBrainz
(`album/lookup`), põe o artista no Lidarr monitorando só esse álbum e manda
buscar. O Lidarr baixa pelo SABnzbd, organiza na pasta de música e continua
vigiando a Usenet (RSS) se não achar de primeira.

A busca por texto depende do servidor de metadados do Lidarr, que já ficou
instável (2025, issue #5498): erros viram nova tentativa mais tarde.
"""
from __future__ import annotations

import logging
import re
import unicodedata

import httpx

from app.config import settings

logger = logging.getLogger("bergastream.quality.lidarr")


class LidarrError(Exception):
    pass


def enabled() -> bool:
    return bool(settings.lidarr_url and settings.lidarr_api_key)


def normalize(text: str) -> str:
    """Comparável: sem acentos, parênteses/colchetes ("Deluxe", "feat."),
    sufixos depois de " - " ("Remastered 2011") e pontuação."""
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    text = re.sub(r"[\(\[].*?[\)\]]", " ", text.lower())
    text = text.split(" - ")[0]
    return re.sub(r"[^a-z0-9]+", "", text)


def names_match(a: str, b: str) -> bool:
    x, y = normalize(a), normalize(b)
    return bool(x and y) and (x == y or x in y or y in x)


def _plain(text: str) -> str:
    """Comparável mantendo o que está entre parênteses ("Ao Vivo", "Deluxe")."""
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def pick_album(candidates: list[dict], artist: str, album: str) -> dict | None:
    """O álbum certo entre os resultados do lookup, do artista certo:
    1. título idêntico (com o que está entre parênteses);
    2. igual sem parênteses/sufixos — preferindo o de título mais curto, para
       "Djavan" não virar "Djavan (Ao Vivo)";
    3. um título contém o outro."""
    main = re.split(r",|&| feat\.? | ft\.? ", artist, maxsplit=1, flags=re.IGNORECASE)[0]
    same_artist = [c for c in candidates
                   if names_match(main, (c.get("artist") or {}).get("artistName", ""))]
    identical = [c for c in same_artist if _plain(c.get("title", "")) == _plain(album)]
    if identical:
        return identical[0]
    wanted = normalize(album)
    stripped = [c for c in same_artist if normalize(c.get("title", "")) == wanted]
    if stripped:
        return min(stripped, key=lambda c: len(_plain(c.get("title", ""))))
    loose = [c for c in same_artist if names_match(album, c.get("title", ""))]
    return min(loose, key=lambda c: len(_plain(c.get("title", "")))) if loose else None


def pick_track(tracks: list[dict], title: str, duration_seconds: int) -> dict | None:
    """A faixa no álbum do Lidarr: título igual (normalizado) e duração até
    5 s de diferença (o Lidarr informa em milissegundos)."""
    for t in tracks:
        if not names_match(title, t.get("title", "")):
            continue
        seconds = (t.get("duration") or 0) / 1000
        if duration_seconds and seconds and abs(seconds - duration_seconds) > 5:
            continue
        return t
    return None


def local_path(remote: str) -> str:
    """Caminho do arquivo no container do Lidarr → caminho montado aqui."""
    root = settings.lidarr_remote_root.rstrip("/")
    if remote.startswith(root + "/"):
        return settings.lidarr_local_root.rstrip("/") + remote[len(root):]
    return remote


class Lidarr:
    def __init__(self) -> None:
        self._cli = httpx.AsyncClient(
            base_url=settings.lidarr_url.rstrip("/") + "/api/v1",
            headers={"X-Api-Key": settings.lidarr_api_key}, timeout=30)
        self._defaults: tuple[int, int, str] | None = None

    async def close(self) -> None:
        await self._cli.aclose()

    async def _req(self, method: str, path: str, **kwargs):
        try:
            r = await self._cli.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise LidarrError(f"Lidarr fora do ar: {exc}") from exc
        if r.status_code >= 400:
            raise LidarrError(f"{method} {path}: HTTP {r.status_code} {r.text[:200]}")
        return r.json() if r.content else None

    async def defaults(self) -> tuple[int, int, str]:
        """(perfil de qualidade, perfil de metadados, pasta raiz)."""
        if self._defaults:
            return self._defaults
        quality = await self._req("GET", "/qualityprofile")
        metadata = await self._req("GET", "/metadataprofile")
        roots = await self._req("GET", "/rootfolder")
        if not quality or not metadata or not roots:
            raise LidarrError("configure no Lidarr um perfil de qualidade, um de metadados e a pasta raiz")

        def by_name(items, wanted, hints):
            if wanted:
                for item in items:
                    if item.get("name", "").lower() == wanted.lower():
                        return item
                raise LidarrError(f"perfil {wanted!r} não existe no Lidarr")
            for item in items:
                if any(h in item.get("name", "").lower() for h in hints):
                    return item
            return items[0]

        q = by_name(quality, settings.lidarr_quality_profile, ("lossless", "flac"))
        m = by_name(metadata, settings.lidarr_metadata_profile, ("standard",))
        root = settings.lidarr_root_folder or roots[0]["path"]
        self._defaults = (q["id"], m["id"], root)
        return self._defaults

    async def lookup_album(self, artist: str, album: str) -> list[dict]:
        return await self._req("GET", "/album/lookup", params={"term": f"{artist} {album}"}) or []

    async def artist_by_mbid(self, mbid: str) -> dict | None:
        found = await self._req("GET", "/artist", params={"mbId": mbid}) or []
        return found[0] if found else None

    async def add_artist(self, lookup_artist: dict, foreign_album_id: str) -> dict:
        """Adiciona o artista monitorando SÓ o álbum pedido; o Lidarr busca
        o álbum sozinho quando terminar de carregar a discografia."""
        quality, metadata, root = await self.defaults()
        body = {
            "artistName": lookup_artist.get("artistName"),
            "foreignArtistId": lookup_artist.get("foreignArtistId"),
            "qualityProfileId": quality,
            "metadataProfileId": metadata,
            "rootFolderPath": root,
            "monitored": True,
            "monitorNewItems": "none",
            "addOptions": {"monitor": "none", "albumsToMonitor": [foreign_album_id],
                           "searchForMissingAlbums": True},
        }
        return await self._req("POST", "/artist", json=body)

    async def albums(self, artist_id: int) -> list[dict]:
        return await self._req("GET", "/album", params={"artistId": artist_id}) or []

    async def monitor(self, album_ids: list[int], monitored: bool = True) -> None:
        await self._req("PUT", "/album/monitor", json={"albumIds": album_ids, "monitored": monitored})

    async def search(self, album_ids: list[int]) -> None:
        await self._req("POST", "/command", json={"name": "AlbumSearch", "albumIds": album_ids})

    async def tracks(self, album_id: int) -> list[dict]:
        return await self._req("GET", "/track", params={"albumId": album_id}) or []

    async def trackfile(self, trackfile_id: int) -> dict:
        return await self._req("GET", f"/trackfile/{trackfile_id}")

    async def trackfiles(self, album_id: int) -> list[dict]:
        return await self._req("GET", "/trackfile", params={"albumId": album_id}) or []

    async def delete_trackfiles(self, ids: list[int]) -> None:
        if ids:
            await self._req("DELETE", "/trackfile/bulk", json={"trackFileIds": ids})
