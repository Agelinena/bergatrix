"""Cliente HTTP para o sidecar Deemix (Deezer download).

Protocolo:
  1. GET  /api/connect        -> cria sessão express, devolve status login
  2. POST /api/loginArl       -> {"arl": "<token>"} — autentica
  3. POST /api/addToQueue     -> {"url": "https://www.deezer.com/track/<id>",
                                  "bitrate": null}
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path

import httpx

from app.config import settings

logger = logging.getLogger("bergastream.downloads.deemix")

_DEEMIX_DL_DIR = Path(settings.music_dir) / "deemix_dl"
_POLL_INTERVAL = 2.0
_DOWNLOAD_TIMEOUT = 180


async def emit_download(deezer_track_id: str) -> bool:
    """Enfileira um download no Deemix. Retorna True se conseguiu enviar."""
    if not settings.deemix_arl:
        logger.warning("[deemix] DEEMIX_ARL não configurado — pulando")
        return False

    base = settings.deemix_url.rstrip("/")

    async with httpx.AsyncClient(base_url=base, timeout=30) as cli:

        # 1. Connect
        try:
            r = await cli.get("/api/connect")
            r.raise_for_status()
            logger.debug("[deemix] connect OK: %s", r.text[:120])
        except httpx.HTTPError as exc:
            logger.warning("[deemix] connect falhou: %s", exc)
            return False

        # 2. Login com ARL
        try:
            r = await cli.post("/api/loginArl", json={"arl": settings.deemix_arl})
            r.raise_for_status()
            data = r.json()
            login_ok = data.get("status") == 1 or data.get("result") is True
            if not login_ok:
                logger.warning("[deemix] login falhou: %s", data)
                return False
            logger.debug("[deemix] login OK")
        except httpx.HTTPError as exc:
            logger.warning("[deemix] loginArl falhou: %s", exc)
            return False

        # 3. Enfileirar download (sem registros velhos desta faixa na fila)
        await clear_stale(cli, deezer_track_id)
        url = f"https://www.deezer.com/track/{deezer_track_id}"
        try:
            r = await cli.post("/api/addToQueue", json={"url": url, "bitrate": None})
            r.raise_for_status()
            data = r.json()
            if data.get("result") is False:
                logger.warning("[deemix] addToQueue erro: %s", data.get("errid", "??"))
                return False
            logger.info("[deemix] download enfileirado: %s", deezer_track_id)
            return True
        except httpx.HTTPError as exc:
            logger.warning("[deemix] addToQueue falhou: %s", exc)
            return False


def _local_path(remote: str) -> Path:
    """Caminho do Deemix (/downloads/...) no volume do worker."""
    relative = remote.split("/downloads", 1)[-1].lstrip("/")
    return _DEEMIX_DL_DIR / relative


def queue_state(queue: dict, deezer_track_id: str) -> tuple[str, object]:
    """Situação da faixa na fila do Deemix:
    ("concluido", Path) | ("falhou", msg) | ("baixando", None) | ("ausente", None).

    O arquivo vem do próprio item da fila (files[].data.id + path), nunca
    de "o mais novo da pasta": com downloads simultâneos isso trocava os
    áudios entre as faixas.
    """
    wanted = str(deezer_track_id)
    items = [v for v in (queue or {}).values() if str(v.get("id")) == wanted]
    if not items:
        return "ausente", None
    for item in items:
        status = item.get("status")
        if status == "failed":
            errors = item.get("errors") or []
            if isinstance(errors, str):
                errors = _literal(errors) or []
            first = errors[0].get("message") if errors and isinstance(errors[0], dict) else ""
            return "falhou", first or "falha sem mensagem"
        if status == "completed":
            files = item.get("files") or []
            if isinstance(files, str):
                files = _literal(files) or []
            for f in files:
                if str((f.get("data") or {}).get("id")) == wanted and f.get("path"):
                    return "concluido", _local_path(f["path"])
            return "falhou", "concluído sem arquivo desta faixa"
    return "baixando", None


def _literal(text: str):
    import ast
    try:
        return ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return None


async def _get_queue(cli: httpx.AsyncClient) -> dict:
    try:
        r = await cli.get("/api/getQueue")
        return (r.json() or {}).get("queue") or {}
    except (httpx.HTTPError, ValueError):
        return {}


async def clear_stale(cli: httpx.AsyncClient, deezer_track_id: str) -> None:
    """Tira da fila do Deemix os registros antigos desta faixa (concluídos
    ou com falha), para a espera não ler um resultado velho."""
    for uuid, item in (await _get_queue(cli)).items():
        if str(item.get("id")) == str(deezer_track_id) and item.get("status") in ("completed", "failed"):
            try:
                # O Deemix lê o uuid da URL (no corpo, responde result=false).
                r = await cli.post("/api/removeFromQueue", params={"uuid": uuid})
                if not (r.json() or {}).get("result"):
                    logger.warning("[deemix] não removeu %s da fila", uuid)
            except (httpx.HTTPError, ValueError):
                pass


# Motivo da última falha de cada faixa (lido pelo serviço para registrar).
_errors: dict[str, str] = {}


def pop_error(deezer_track_id: str) -> str | None:
    return _errors.pop(str(deezer_track_id), None)


async def clear_failed() -> int:
    """Tira da fila do Deemix todos os itens com falha (ficavam lá para
    sempre: o servidor já baixou a faixa pelo YouTube ou desistiu)."""
    removed = 0
    try:
        async with httpx.AsyncClient(base_url=settings.deemix_url, timeout=10) as cli:
            await cli.get("/api/connect")
            for uuid, item in (await _get_queue(cli)).items():
                if item.get("status") == "failed":
                    r = await cli.post("/api/removeFromQueue", params={"uuid": uuid})
                    if (r.json() or {}).get("result"):
                        removed += 1
    except (httpx.HTTPError, ValueError):
        return removed
    if removed:
        logger.info("[deemix] %d item(ns) com falha removido(s) da fila", removed)
    return removed


async def _wait_for_file(deezer_track_id: str, timeout: float = _DOWNLOAD_TIMEOUT) -> Path | None:
    """Espera o item DESTA faixa concluir na fila do Deemix e devolve o
    arquivo dele. Desiste na hora se falhar."""
    deadline = time.monotonic() + timeout
    absent_since = time.monotonic()
    async with httpx.AsyncClient(base_url=settings.deemix_url, timeout=10) as cli:
        try:
            await cli.get("/api/connect")
        except httpx.HTTPError:
            pass
        while time.monotonic() < deadline:
            state, value = queue_state(await _get_queue(cli), deezer_track_id)
            if state == "concluido":
                path: Path = value  # type: ignore[assignment]
                if path.exists() and path.stat().st_size > 0:
                    logger.info("[deemix] arquivo pronto: %s (%d bytes)", path.name, path.stat().st_size)
                    return path
                logger.warning("[deemix] %s concluído mas o arquivo sumiu: %s", deezer_track_id, path)
                return None
            if state == "falhou":
                logger.warning("[deemix] falhou para %s: %s", deezer_track_id, value)
                _errors[str(deezer_track_id)] = str(value)
                # Não fica na fila do Deemix: o serviço tenta o YouTube.
                await clear_stale(cli, deezer_track_id)
                return None
            if state == "ausente" and time.monotonic() - absent_since > 15:
                logger.warning("[deemix] %s não apareceu na fila", deezer_track_id)
                return None
            if state != "ausente":
                absent_since = time.monotonic()
            await asyncio.sleep(_POLL_INTERVAL)
    logger.warning("[deemix] timeout (%ds) esperando download", _DOWNLOAD_TIMEOUT)
    return None


async def download_track(deezer_track_id: str) -> tuple[bool, Path | None, str | None]:
    """Faz o download completo via Deemix. Retorna (ok, caminho, formato)."""
    ok = await emit_download(deezer_track_id)
    if not ok:
        return False, None, None

    file_path = await _wait_for_file(deezer_track_id)
    if file_path is None:
        return False, None, None

    ext = file_path.suffix.lower()
    fmt_map = {".mp3": "mp3_320" if "320" in str(file_path) else "mp3_128",
               ".flac": "flac", ".m4a": "aac", ".ogg": "vorbis"}
    fmt = fmt_map.get(ext, "mp3_128")
    return True, file_path, fmt
