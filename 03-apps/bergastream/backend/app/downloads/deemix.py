"""Cliente HTTP para o sidecar Deemix (Deezer download).

Protocolo:
  1. GET  /api/connect        -> cria sessão express, devolve status login
  2. POST /api/loginArl       -> {"arl": "<token>"} — autentica
  3. POST /api/addToQueue     -> {"url": "https://www.deezer.com/track/<id>",
                                  "bitrate": <formato>}

Formato por pedido (sobrepõe o maxBitrate do config do Deemix): 9 = FLAC,
3 = MP3 320, 1 = MP3 128. Se a conta não tem o formato, o Deemix recusa na
hora (`errid: CantStream`); se a faixa não existe nele, o item falha com
"wrongBitrate". `download_best` tenta os formatos em ordem, do melhor para o
pior.
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

FLAC, MP3_320, MP3_128 = 9, 3, 1
FORMAT_NAMES = {FLAC: "FLAC", MP3_320: "MP3 320", MP3_128: "MP3 128"}
# Sob demanda: MP3 320 (Premium); faixas de playlist tentam FLAC primeiro.
ON_DEMAND = (MP3_320, MP3_128)
BEST = (FLAC, MP3_320, MP3_128)
# Qualidade que cada formato entrega (audio_info.rank), para o upgrade não
# baixar o que não pode ser melhor que o arquivo atual.
EXPECTED_RANK = {FLAC: 40, MP3_320: 30, MP3_128: 10}
_POLL_INTERVAL = 2.0
_DOWNLOAD_TIMEOUT = 180


async def emit_download(deezer_track_id: str, bitrate: int = MP3_320) -> bool:
    """Enfileira um download no Deemix no formato [bitrate]. Retorna True se
    conseguiu enviar (False também quando a conta não tem o formato)."""
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
            r = await cli.post("/api/addToQueue", json={"url": url, "bitrate": bitrate})
            r.raise_for_status()
            data = r.json()
            if data.get("result") is False:
                errid = data.get("errid", "??")
                _errors[str(deezer_track_id)] = (
                    f"a conta do ARL não tem {FORMAT_NAMES.get(bitrate, bitrate)}"
                    if errid == "CantStream" else f"addToQueue: {errid}")
                logger.warning("[deemix] addToQueue %s em %s: %s", deezer_track_id,
                               FORMAT_NAMES.get(bitrate, bitrate), errid)
                return False
            logger.info("[deemix] download enfileirado: %s (%s)", deezer_track_id,
                        FORMAT_NAMES.get(bitrate, bitrate))
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


async def download_track(deezer_track_id: str, bitrate: int = MP3_320) -> tuple[bool, Path | None]:
    """Faz o download completo via Deemix num formato. Retorna (ok, caminho);
    a qualidade real é lida do arquivo (audio_info), não do nome."""
    if not await emit_download(deezer_track_id, bitrate):
        return False, None
    file_path = await _wait_for_file(deezer_track_id)
    return (True, file_path) if file_path else (False, None)


async def download_best(deezer_track_id: str, formats=ON_DEMAND) -> tuple[bool, Path | None]:
    """Tenta os [formats] em ordem (o melhor primeiro) até um baixar."""
    for bitrate in formats:
        ok, path = await download_track(deezer_track_id, bitrate)
        if ok:
            return True, path
        logger.info("[deemix] %s sem %s; tentando o próximo formato", deezer_track_id,
                    FORMAT_NAMES.get(bitrate, bitrate))
    return False, None
