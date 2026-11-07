"""Letras sincronizadas pelo LRCLIB (lrclib.net): banco público e gratuito,
sem chave. Cada faixa é buscada uma vez e guardada na tabela `lyrics`
(inclusive "não achou", que é tentado de novo depois de [RETRY_AFTER]).

Formato LRC: "[mm:ss.xx] texto" — o app destaca a linha atual e rola
sozinho conforme a música toca.

Qualquer pessoa logada pode corrigir a letra de uma faixa (vale para todos):
o atraso/adiantamento (`offset_ms`, já aplicado nos tempos devolvidos) e o
texto. Letra corrigida não é trocada pela do LRCLIB; "buscar de novo"
desfaz a correção.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING

import httpx
from pydantic import BaseModel

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger("bergastream.lyrics")

LRCLIB = "https://lrclib.net/api"
# Cabeçalho HTTP: só ASCII.
_HEADERS = {"User-Agent": "Bergastream (personal music server)"}
RETRY_AFTER = timedelta(days=7)
_DURATION_TOLERANCE = 5  # segundos
_LINE_RE = re.compile(r"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]")
# " - Remastered 2011", "(feat. X)", "[Live]"… atrapalham a busca.
_NOISE_RE = re.compile(
    r"\s*(?:-\s*(?:\d{4}\s+)?(?:remaster(?:ed)?|live|ao vivo|mono|stereo|radio edit|single version)[^\-]*$"
    r"|\((?:feat|ft|with|remaster|live|ao vivo)[^)]*\)|\[(?:feat|ft|remaster|live)[^\]]*\])",
    re.IGNORECASE)


class LyricLine(BaseModel):
    time_ms: int
    text: str


class Lyrics(BaseModel):
    found: bool
    synced: list[LyricLine] = []
    plain: str | None = None
    source: str = "lrclib"
    track_id: str | None = None
    # Já somado aos tempos de [synced]; o app mostra no ajuste.
    offset_ms: int = 0
    # Texto LRC como está guardado (sem o ajuste), para o editor.
    lrc: str | None = None
    edited: bool = False

MAX_OFFSET_MS = 30_000


def parse_lrc(text: str | None) -> list[LyricLine]:
    """"[01:02.30] texto" → linhas em ordem. Linhas com vários tempos
    (refrão repetido) viram uma linha por tempo."""
    lines: list[LyricLine] = []
    for raw in (text or "").splitlines():
        stamps = list(_LINE_RE.finditer(raw))
        if not stamps:
            continue
        content = raw[stamps[-1].end():].strip()
        for m in stamps:
            frac = (m.group(3) or "0").ljust(3, "0")[:3]
            ms = (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + int(frac)
            lines.append(LyricLine(time_ms=ms, text=content))
    lines.sort(key=lambda line: line.time_ms)
    return lines


def clean_title(title: str) -> str:
    return _NOISE_RE.sub("", title).strip() or title


def _pick(items: list[dict], duration: int) -> dict | None:
    """Da busca: a versão com duração mais próxima, preferindo sincronizada."""
    def ok(i):
        return not i.get("instrumental") and (i.get("syncedLyrics") or i.get("plainLyrics"))
    candidates = [i for i in items if ok(i)]
    if duration > 0:
        candidates = [i for i in candidates
                      if abs(float(i.get("duration") or 0) - duration) <= _DURATION_TOLERANCE]
    candidates.sort(key=lambda i: (not i.get("syncedLyrics"),
                                   abs(float(i.get("duration") or 0) - duration)))
    return candidates[0] if candidates else None


async def fetch_lrclib(title: str, artist: str, album: str, duration: int) -> dict | None:
    """Busca exata (artista + título + duração); se não achar, pela busca
    textual com o título limpo. Devolve o item do LRCLIB ou None."""
    first_artist = artist.split(",")[0].strip()
    async with httpx.AsyncClient(base_url=LRCLIB, headers=_HEADERS, timeout=10) as cli:
        for name in dict.fromkeys([title, clean_title(title)]):
            params = {"artist_name": first_artist, "track_name": name}
            if album:
                params["album_name"] = album
            if duration > 0:
                params["duration"] = duration
            r = await cli.get("/get", params=params)
            if r.status_code == 200:
                item = r.json()
                if not item.get("instrumental") and (item.get("syncedLyrics") or item.get("plainLyrics")):
                    return item
        r = await cli.get("/search", params={"track_name": clean_title(title), "artist_name": first_artist})
        if r.status_code == 200 and isinstance(r.json(), list):
            return _pick(r.json(), duration)
    return None


def format_lrc(lines: list[LyricLine]) -> str:
    def stamp(ms: int) -> str:
        ms = max(ms, 0)
        return f"[{ms // 60000:02d}:{ms // 1000 % 60:02d}.{ms % 1000 // 10:02d}]"
    return "\n".join(f"{stamp(line.time_ms)} {line.text}".rstrip() for line in lines)


def _to_lyrics(row) -> Lyrics:
    track_id = str(row["track_id"])
    if not row["found"]:
        return Lyrics(found=False, track_id=track_id)
    offset = row["offset_ms"] or 0
    lines = [LyricLine(time_ms=max(line.time_ms + offset, 0), text=line.text)
             for line in parse_lrc(row["synced"])]
    return Lyrics(found=True, synced=lines, plain=row["plain"], source=row["source"],
                  track_id=track_id, offset_ms=offset, lrc=row["synced"],
                  edited=row["edited_at"] is not None)


async def lyrics_for(pool: "asyncpg.Pool", track_id: str) -> Lyrics:
    row = await pool.fetchrow("SELECT * FROM lyrics WHERE track_id = $1", track_id)
    if row and (row["found"] or datetime.now(timezone.utc) - row["fetched_at"] < RETRY_AFTER):
        return _to_lyrics(row)
    track = await pool.fetchrow(
        "SELECT title, artist, coalesce(album, '') AS album, duration_seconds FROM tracks WHERE id = $1",
        track_id)
    if track is None:
        return Lyrics(found=False, track_id=track_id)
    try:
        item = await fetch_lrclib(track["title"], track["artist"], track["album"],
                                  int(track["duration_seconds"] or 0))
    except httpx.HTTPError as exc:
        # LRCLIB fora do ar: não guarda nada (tenta de novo na próxima vez).
        logger.info("[lyrics] LRCLIB falhou para %s: %s", track["title"], exc)
        return _to_lyrics(row) if row else Lyrics(found=False, track_id=track_id)
    found = item is not None
    await pool.execute(
        """INSERT INTO lyrics (track_id, found, synced, plain, fetched_at)
           VALUES ($1, $2, $3, $4, now())
           ON CONFLICT (track_id) DO UPDATE
           SET found = $2, synced = $3, plain = $4, fetched_at = now()""",
        track_id, found, (item or {}).get("syncedLyrics"), (item or {}).get("plainLyrics"))
    return await lyrics_for(pool, track_id) if found else Lyrics(found=False, track_id=track_id)


class LyricsError(Exception):
    pass


async def edit(pool, track_id: str, user_id: str, *, offset_ms: int | None = None,
               lrc: str | None = None, plain: str | None = None) -> Lyrics:
    """Corrige a letra. [lrc] vazio apaga a sincronizada; [plain] idem."""
    if offset_ms is not None and abs(offset_ms) > MAX_OFFSET_MS:
        raise LyricsError("Ajuste de no máximo 30 s para cada lado.")
    if lrc is not None and lrc.strip() and not parse_lrc(lrc):
        raise LyricsError('Nenhuma linha com tempo. Use o formato "[mm:ss.xx] texto".')
    row = await pool.fetchrow("SELECT * FROM lyrics WHERE track_id = $1", track_id)
    synced = row["synced"] if row else None
    text = row["plain"] if row else None
    offset = row["offset_ms"] if row else 0
    if lrc is not None:
        synced = lrc.strip() or None
    if plain is not None:
        text = plain.strip() or None
    if offset_ms is not None:
        offset = offset_ms
    if not synced and not text:
        raise LyricsError("A letra ficou vazia.")
    source = "manual" if (lrc is not None or plain is not None) else (row["source"] if row else "manual")
    await pool.execute(
        """INSERT INTO lyrics (track_id, found, synced, plain, source, offset_ms, edited_by, edited_at)
           VALUES ($1, true, $2, $3, $4, $5, $6, now())
           ON CONFLICT (track_id) DO UPDATE
           SET found = true, synced = $2, plain = $3, source = $4, offset_ms = $5,
               edited_by = $6, edited_at = now()""",
        track_id, synced, text, source, offset, user_id)
    return _to_lyrics(await pool.fetchrow("SELECT * FROM lyrics WHERE track_id = $1", track_id))


async def reset(pool, track_id: str) -> Lyrics:
    """Desfaz a correção: busca de novo no LRCLIB."""
    await pool.execute("DELETE FROM lyrics WHERE track_id = $1", track_id)
    return await lyrics_for(pool, track_id)
