"""Rotas da API da Bergastream (Etapa 2).

Todas exigem login (Bearer), exceto o stream, que também aceita `?t=` com
token de stream da faixa (o `<audio>` da web não envia cabeçalhos).
"""
from __future__ import annotations
import asyncio
import logging
from pathlib import Path
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request
from fastapi import Path as Path_
from pydantic import BaseModel, Field
from fastapi.responses import FileResponse, StreamingResponse
from app.search.models import FullSearch, PlaylistResult, SearchResult
from app.search.resolve import LinkNotFound, ResolvedLink, UnsupportedLink, resolve as resolve_link
from app.search import spotify as spotify_search
from app.search import youtube as youtube_search
from app.tracks.models import PlayRequest, PlayResponse
from app.tracks import service as tracks_service
from app.downloads import queue as q
from app.core.db import get_pool
from app.core.redis import get_redis
from app.auth.dependencies import CurrentUser, admin_user, current_user, stream_user
from app.auth.models import StreamToken
from app.auth.security import create_stream_token
from app.config import settings

logger = logging.getLogger("bergastream.api")
router = APIRouter(prefix="/api")

async def _get_pool():
    return get_pool()

# Busca

@router.get("/search", response_model=list[SearchResult])
async def search(q: str = Query(min_length=1), source: str = Query("all", pattern="^(spotify|ytmusic|youtube|all)$"), user: CurrentUser = Depends(current_user)):
    tasks = []
    if source in ("spotify", "all"):
        tasks.append(asyncio.to_thread(spotify_search.search, q))
    if source in ("youtube", "all"):
        tasks.append(asyncio.to_thread(youtube_search.search, q))
    if source in ("ytmusic", "all"):
        from app.search import ytmusic as ytmusic_search
        tasks.append(asyncio.to_thread(ytmusic_search.search, q))
    if not tasks:
        return []
    rl = await asyncio.gather(*tasks)
    combined = []
    for r in rl:
        combined.extend(r)
    return combined

@router.get("/search/full", response_model=FullSearch)
async def search_full(q: str = Query(min_length=1), source: str = Query("spotify", pattern="^(spotify|ytmusic)$"), user: CurrentUser = Depends(current_user)):
    """Faixas, artistas e álbuns de uma origem (Seção 6.3 do app)."""
    if source == "spotify":
        return await asyncio.to_thread(spotify_search.search_full, q)
    from app.search import ytmusic as ytmusic_search
    return await asyncio.to_thread(ytmusic_search.search_full, q)

@router.get("/search/playlists", response_model=list[PlaylistResult])
async def search_playlists(q: str = Query(min_length=1, max_length=200), user: CurrentUser = Depends(current_user)):
    """Playlists do Spotify, Deezer e YouTube Music; "rádio <artista>" traz
    a rádio do artista. Abrir: a `url` vai para /api/resolve."""
    from app.search.playlists import search_playlists as find
    return await find(q)


@router.get("/resolve", response_model=ResolvedLink)
async def resolve(url: str = Query(min_length=8, max_length=2048), user: CurrentUser = Depends(current_user)):
    """Link do Spotify, Deezer ou YouTube → faixa, álbum ou playlist com as faixas."""
    try:
        return await resolve_link(url)
    except UnsupportedLink:
        raise HTTPException(400, detail="Link não reconhecido")
    except LinkNotFound:
        raise HTTPException(404, detail="Não foi possível abrir este link")

# Artista e álbum (Seção 6.7 do app)

_PROVIDER = "^(spotify|ytmusic)$"

async def _catalog(fn, *args):
    from app.catalog.service import NotFound
    try:
        return await asyncio.to_thread(fn, *args)
    except NotFound:
        raise HTTPException(404, detail="Não encontrado")
    except Exception as exc:
        logger.warning("[catalog] %s%s falhou: %s", fn.__name__, args, exc)
        raise HTTPException(502, detail="A origem não respondeu")

@router.get("/artists/{provider}/{artist_id}")
async def artist_page(provider: str = Path_(pattern=_PROVIDER), artist_id: str = Path_(max_length=100), user: CurrentUser = Depends(current_user)):
    from app.catalog import service as catalog
    return await _catalog(catalog.artist, provider, artist_id)

@router.get("/artists/{provider}/{artist_id}/tracks")
async def artist_tracks(provider: str = Path_(pattern=_PROVIDER), artist_id: str = Path_(max_length=100), offset: int = Query(0, ge=0, le=5000), limit: int = Query(50, ge=1, le=50), user: CurrentUser = Depends(current_user)):
    """Todas as músicas do artista, paginadas por offset."""
    from app.catalog import service as catalog
    return await _catalog(catalog.artist_tracks, provider, artist_id, offset, limit)

@router.get("/albums/{provider}/{album_id}")
async def album_page(provider: str = Path_(pattern=_PROVIDER), album_id: str = Path_(max_length=100), user: CurrentUser = Depends(current_user)):
    from app.catalog import service as catalog
    return await _catalog(catalog.album, provider, album_id)

# Play

@router.post("/play", response_model=PlayResponse)
async def play(body: PlayRequest, pool=Depends(_get_pool), user: CurrentUser = Depends(current_user)):
    result = await tracks_service.resolve_and_register(pool, body)
    if result.status != "ready":
        r = await get_redis()
        await q.enqueue(r, result.track_id, body.provider, priority=1, external_id=body.external_id, title=body.title, artist=body.artist)
        result.status = "downloading"
    return result

# Status

@router.get("/tracks/{track_id}/status")
async def track_status(track_id: str, user: CurrentUser = Depends(current_user)):
    r = await get_redis()
    from app.downloads.queue import _ACTIVE_SET
    if await r.sismember(_ACTIVE_SET, track_id):
        return {"track_id": track_id, "status": "downloading"}
    pool = get_pool()
    has = await pool.fetchval("SELECT 1 FROM files WHERE track_id=$1", track_id)
    if has:
        row = await pool.fetchrow("SELECT kind, last_played_at FROM files WHERE track_id=$1", track_id)
        return {"track_id": track_id, "status": "ready", "kind": row["kind"] if row else "cache"}
    keys = await r.keys("bergastream:job:*")
    for k in keys:
        j = await r.hgetall(k)
        if j and j.get("track_id") == track_id:
            return {"track_id": track_id, "status": j.get("status", "unknown")}
    return {"track_id": track_id, "status": "unknown"}

# Stream

_MEDIA_TYPES = {".mp3": "audio/mpeg", ".flac": "audio/flac", ".m4a": "audio/mp4", ".ogg": "audio/ogg", ".opus": "audio/opus", ".webm": "audio/webm"}

_TRACK_ID = r"^[0-9a-fA-F\-]{32,36}$"

@router.post("/tracks/{track_id}/stream-token", response_model=StreamToken)
async def stream_token(track_id: str, user: CurrentUser = Depends(current_user)):
    """Token curto para tocar a faixa na web: `/stream?t=<token>`."""
    import re as _re
    if not _re.match(_TRACK_ID, track_id):
        raise HTTPException(404, detail="ID invalido")
    return StreamToken(token=create_stream_token(user.id, track_id), expires_in=settings.stream_token_hours * 3600)

@router.get("/tracks/{track_id}/stream")
async def stream_track(track_id: str, request: Request, user: CurrentUser = Depends(stream_user)):
    import re as _re
    if not _re.match(_TRACK_ID, track_id):
        raise HTTPException(404, detail="ID invalido")
    pool = get_pool()
    row = await pool.fetchrow("SELECT path, format FROM files WHERE track_id=$1", track_id)
    if not row:
        t = await pool.fetchrow("SELECT 1 FROM tracks WHERE id=$1", track_id)
        if not t:
            raise HTTPException(404, detail="Faixa nao encontrada")
        raise HTTPException(503, detail="Ainda baixando")
    file_path = Path(row["path"])
    if not file_path.exists():
        raise HTTPException(404, detail="Arquivo nao encontrado em disco")
    await pool.execute("UPDATE files SET last_played_at = now() WHERE track_id=$1", track_id)
    ext = file_path.suffix.lower()
    media_type = _MEDIA_TYPES.get(ext, "application/octet-stream")
    file_size = file_path.stat().st_size
    range_hdr = request.headers.get("range")
    if not range_hdr:
        return FileResponse(path=str(file_path), media_type=media_type, filename=file_path.name, headers={"Accept-Ranges": "bytes"})
    m = _re.match(r"bytes=(\d*)-(\d*)", range_hdr)
    if not m:
        raise HTTPException(416, detail="Range mal formatado")
    start_s, end_s = m.groups()
    start = int(start_s) if start_s else 0
    end = int(end_s) if end_s else file_size - 1
    if start >= file_size or end >= file_size:
        raise HTTPException(416, detail="Range fora dos limites", headers={"Content-Range": f"bytes */{file_size}"})
    cl = end - start + 1
    async def _chunk(path, offset, length):
        import aiofiles
        async with aiofiles.open(str(path), "rb") as f:
            await f.seek(offset)
            left = length
            while left > 0:
                bs = min(left, 65536)
                data = await f.read(bs)
                if not data:
                    break
                yield data
                left -= len(data)
    return StreamingResponse(_chunk(file_path, start, cl), status_code=206, media_type=media_type, headers={"Accept-Ranges": "bytes", "Content-Range": f"bytes {start}-{end}/{file_size}", "Content-Length": str(cl)})

@router.get("/tracks/{track_id}/download")
async def download_track(track_id: str, user: CurrentUser = Depends(stream_user)):
    """Arquivo completo para o modo offline (Seção 8 do app). Mesma
    autenticação do stream (Bearer ou ?t=). O tamanho vai em Content-Length
    para o app validar o arquivo baixado."""
    import re as _re
    if not _re.match(_TRACK_ID, track_id):
        raise HTTPException(404, detail="ID invalido")
    pool = get_pool()
    row = await pool.fetchrow("SELECT path, size_bytes FROM files WHERE track_id=$1", track_id)
    if not row:
        if not await pool.fetchval("SELECT 1 FROM tracks WHERE id=$1", track_id):
            raise HTTPException(404, detail="Faixa nao encontrada")
        raise HTTPException(503, detail="Ainda baixando")
    file_path = Path(row["path"])
    if not file_path.exists():
        raise HTTPException(404, detail="Arquivo nao encontrado em disco")
    media_type = _MEDIA_TYPES.get(file_path.suffix.lower(), "application/octet-stream")
    return FileResponse(path=str(file_path), media_type=media_type,
                        filename=f"{track_id}{file_path.suffix.lower()}",
                        headers={"X-Track-Format": file_path.suffix.lower().lstrip(".")})

# Admin

@router.post("/admin/cleanup")
async def admin_cleanup(pool=Depends(_get_pool), user: CurrentUser = Depends(admin_user)):
    from app.storage.service import cleanup_once
    removed = await cleanup_once(pool)
    return {"removed": removed}

# Users / Playlists

async def _own_playlist(pool, playlist_id: str, user: CurrentUser):
    """Só o dono (ou admin) altera. Colaboradores entram com as permissões de
    playlist (pendência do backend). 404 para não revelar playlists alheias."""
    from app.users.repository import get_playlist
    playlist = await get_playlist(pool, playlist_id)
    if not playlist or (playlist.user_id != user.id and not user.is_admin):
        raise HTTPException(404, detail="Playlist nao encontrada")
    return playlist

@router.get("/users")
async def list_users(pool=Depends(_get_pool), user: CurrentUser = Depends(admin_user)):
    from app.users.repository import get_users
    return [{"id": u.id, "name": u.name} for u in await get_users(pool)]

@router.get("/users/{user_id}/playlists")
async def list_playlists(user_id: str, pool=Depends(_get_pool), user: CurrentUser = Depends(current_user)):
    from app.users.repository import get_user_playlists, get_user
    if user_id != user.id and not user.is_admin:
        raise HTTPException(404, detail="Usuario nao encontrado")
    if not await get_user(pool, user_id):
        raise HTTPException(404, detail="Usuario nao encontrado")
    pls = await get_user_playlists(pool, user_id)
    return [{"id": p.id, "user_id": p.user_id, "name": p.name} for p in pls]
