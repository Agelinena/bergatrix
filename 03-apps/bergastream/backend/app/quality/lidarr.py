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


def _tolerance(seconds: float) -> float:
    """Durações do MusicBrainz e do Spotify diferem uns segundos (silêncio no
    fim, edição): até 15 s ou 10%."""
    return max(15.0, seconds * 0.10)


def pick_track(tracks: list[dict], title: str, duration_seconds: int) -> dict | None:
    """A faixa no álbum do Lidarr: título igual (normalizado) e, entre as que
    casam ("Mulher de Fases" e "Mulher de Fases (A Linda)"), a de duração
    mais próxima, se ficar dentro da tolerância (o Lidarr informa em ms)."""
    same = [t for t in tracks if names_match(title, t.get("title", ""))]
    if not same or not duration_seconds:
        return same[0] if same else None
    exact = [t for t in same if _plain(t.get("title", "")) == _plain(title)]

    def gap(t: dict) -> float:
        seconds = (t.get("duration") or 0) / 1000
        return abs(seconds - duration_seconds) if seconds else 0.0

    best = min(same, key=lambda t: (gap(t), t not in exact))
    return best if gap(best) <= _tolerance(duration_seconds) else None


def pick_medley(tracks: list[dict], title: str, duration_seconds: int) -> list[dict] | None:
    """Faixa do Spotify que junta duas ou mais do álbum ("Holiday / Boulevard
    of Broken Dreams"): as partes, na ordem do álbum, em sequência e com a
    soma das durações batendo."""
    parts = [p for p in re.split(r"\s+/\s+", title or "") if p.strip()]
    if len(parts) < 2:
        return None
    ordered = sorted(tracks, key=lambda t: t.get("absoluteTrackNumber") or 0)
    found: list[dict] = []
    for part in parts:
        hit = next((t for t in ordered if t not in found and names_match(part, t.get("title", ""))), None)
        if hit is None:
            return None
        found.append(hit)
    numbers = [t.get("absoluteTrackNumber") or 0 for t in found]
    if numbers != list(range(numbers[0], numbers[0] + len(numbers))):
        return None
    total = sum((t.get("duration") or 0) for t in found) / 1000
    if duration_seconds and total and abs(total - duration_seconds) > _tolerance(duration_seconds):
        return None
    return found


def pick_parts(tracks: list[dict], title: str, duration_seconds: int) -> list[dict]:
    """As faixas do álbum que formam a do Spotify: o medley ("A / B") quando
    o álbum tem as partes separadas; senão, a faixa de mesmo título."""
    if " / " in (title or ""):
        medley = pick_medley(tracks, title, duration_seconds)
        if medley:
            return medley
    match = pick_track(tracks, title, duration_seconds)
    return [match] if match else []


# Estados da fila do Lidarr (TrackedDownloadState) em que o download não
# anda mais sozinho: importação bloqueada (ex.: release com .exe, faixas que
# não casam) ou falhou, e download que falhou.
STUCK_STATES = {"importBlocked", "importFailed", "downloadFailed", "downloadFailedPending"}


def stuck_reason(item: dict) -> str | None:
    """Motivo, se o item da fila travou; None se está andando. Importação
    "pendente" só conta se o Lidarr marcou aviso ou erro."""
    state = item.get("trackedDownloadState")
    health = (item.get("trackedDownloadStatus") or "").lower()
    if state not in STUCK_STATES and not (state == "importPending" and health in ("warning", "error")):
        return None
    messages = [m for s in item.get("statusMessages") or []
                for m in (s.get("messages") or [s.get("title")]) if m]
    return ("; ".join(messages) or item.get("errorMessage") or state)[:200]


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
            raise LidarrError(f"Lidarr fora do ar: {type(exc).__name__} {exc}".strip()) from exc
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
        term = f"{artist} {album}".strip()
        return await self._req("GET", "/album/lookup", params={"term": term}) or []

    async def album_by_mbid(self, release_group: str) -> dict | None:
        """O álbum (com o artista) pelo id do release group do MusicBrainz."""
        for prefix in ("lidarr:", "mbid:"):
            try:
                found = await self.lookup_album(prefix + release_group, "")
            except LidarrError:
                continue
            match = next((a for a in found if a.get("foreignAlbumId") == release_group), None)
            if match:
                return match
        return None

    async def artist_by_mbid(self, mbid: str) -> dict | None:
        found = await self._req("GET", "/artist", params={"mbId": mbid}) or []
        # Confere no cliente: um Lidarr que ignore o filtro devolveria todos.
        return next((a for a in found if a.get("foreignArtistId") == mbid), None)

    async def artists(self) -> list[dict]:
        return await self._req("GET", "/artist") or []

    async def monitor_artists(self, artist_ids: list[int]) -> None:
        """Artista monitorado: sem isso o Lidarr ignora o álbum no RSS e na
        busca de faltantes, mesmo com o álbum monitorado."""
        if artist_ids:
            await self._req("PUT", "/artist/editor", json={"artistIds": artist_ids, "monitored": True})

    async def albums_by_ids(self, album_ids: list[int]) -> list[dict]:
        found: list[dict] = []
        for i in range(0, len(album_ids), 100):
            chunk = album_ids[i:i + 100]
            found += await self._req("GET", "/album", params={"albumIds": chunk}) or []
        return found

    async def queue(self) -> list[dict]:
        """Itens na fila de download do Lidarr (todas as páginas)."""
        records: list[dict] = []
        page = 1
        while True:
            data = await self._req("GET", "/queue", params={"page": page, "pageSize": 200}) or {}
            records += data.get("records") or []
            if len(records) >= (data.get("totalRecords") or 0) or not data.get("records"):
                return records
            page += 1

    async def remove_queued(self, queue_id: int) -> None:
        """Tira da fila e do SABnzbd e põe o release na blocklist (não vem de
        novo). A nova busca é feita pelo Bergastream, dentro do orçamento."""
        await self._req("DELETE", f"/queue/{queue_id}", params={
            "removeFromClient": "true", "blocklist": "true", "skipRedownload": "true"})

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
