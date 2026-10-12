"""Versões de uma faixa na qualidade pedida pelo app (streaming e offline).

O servidor guarda UM arquivo mestre por faixa (o melhor que conseguiu). O app
pede um nível e recebe:

    original  o mestre como está (FLAC quando houver)
    high      MP3 320
    normal    AAC 160
    low       AAC 96

Nunca inventa qualidade: se o mestre já é igual ou pior que o nível pedido
(ex.: pediu FLAC e só há MP3 320; pediu 160 e o mestre é Opus 140), vai o
mestre. Senão, a versão é convertida UMA vez (ffmpeg, 1–2 s) e guardada em
music/variants — arquivo inteiro, para o player poder avançar no meio e o
download offline saber o tamanho. Versões sem uso há VARIANT_TTL_DAYS são
apagadas pela limpeza; trocar o mestre (melhoria de qualidade) apaga as
versões antigas.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path

from app.config import settings
from app.downloads.audio_info import _EFFICIENCY, AudioInfo

logger = logging.getLogger("bergastream.downloads.variants")

VARIANTS_DIR = Path(settings.music_dir) / "variants"
VARIANT_TTL_DAYS = 7
LEVELS = ("original", "high", "normal", "low")
# Só converte se o mestre render bem mais que o alvo (equivalência por codec).
_MARGIN = 1.25


@dataclass(frozen=True)
class Target:
    codec: str
    kbps: int
    ext: str
    args: tuple[str, ...]


TARGETS = {
    "high": Target("mp3", 320, ".mp3", ("-c:a", "libmp3lame", "-b:a", "320k")),
    "normal": Target("aac", 160, ".m4a", ("-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart")),
    "low": Target("aac", 96, ".m4a", ("-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart")),
}


@dataclass(frozen=True)
class Delivery:
    """O que o app recebe num nível."""
    label: str          # "FLAC 16/44.1", "MP3 320", "AAC 160"
    rank: int           # audio_info.rank
    target: Target | None = None  # None = o mestre como está

    def as_dict(self) -> dict:
        return {"label": self.label, "rank": self.rank}


def master_info(row) -> AudioInfo | None:
    """AudioInfo do mestre a partir da linha de `files` (None se não medido)."""
    if not row or not row["codec"]:
        return None
    return AudioInfo(codec=row["codec"], bitrate_kbps=row["bitrate_kbps"],
                     sample_rate=row["sample_rate"], bit_depth=row["bit_depth"])


def _equivalent(info: AudioInfo) -> float:
    if info.lossless:
        return float("inf")
    return (info.bitrate_kbps or 0) * _EFFICIENCY.get(info.codec, 1.0)


def delivered(master: AudioInfo | None, level: str) -> Delivery:
    """O que vai para o app no [level], dado o mestre."""
    target = TARGETS.get(level)
    if master is None:
        return Delivery(label="", rank=0)
    if target is None or _equivalent(master) <= target.kbps * _EFFICIENCY.get(target.codec, 1.0) * _MARGIN:
        return Delivery(label=master.label, rank=master.rank)
    out = AudioInfo(codec=target.codec, bitrate_kbps=target.kbps, sample_rate=None, bit_depth=None)
    return Delivery(label=out.label, rank=out.rank, target=target)


def qualities(row) -> dict[str, dict]:
    """Para a API: o que cada nível entrega desta faixa ({} sem arquivo)."""
    if not row or not row["codec"]:
        return {}
    master = master_info(row)
    return {level: delivered(master, level).as_dict() for level in LEVELS}


_locks: dict[str, asyncio.Lock] = {}


async def path_for(track_id: str, master_path: Path, master: AudioInfo | None,
                   level: str) -> tuple[Path, Delivery]:
    """Arquivo a servir no [level] (o mestre ou a versão convertida)."""
    delivery = delivered(master, level)
    if delivery.target is None:
        return master_path, delivery
    target = delivery.target
    # O tamanho do mestre entra no nome: mestre trocado = versão nova.
    name = f"{track_id}.{level}.{master_path.stat().st_size}{target.ext}"
    path = VARIANTS_DIR / name
    lock = _locks.setdefault(name, asyncio.Lock())
    async with lock:
        if path.exists() and path.stat().st_size > 0:
            os.utime(path)  # usado agora: a limpeza conta a partir daqui
            return path, delivery
        VARIANTS_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{name}.part{target.ext}")
        started = time.monotonic()
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-v", "error", "-y", "-i", str(master_path), "-map", "0:a:0", "-vn",
            "-map_metadata", "0", *target.args, str(tmp),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        try:
            _, err = await asyncio.wait_for(proc.communicate(), timeout=180)
        except asyncio.TimeoutError:
            proc.kill()
            tmp.unlink(missing_ok=True)
            raise RuntimeError("conversão demorou demais")
        if proc.returncode != 0 or not tmp.exists():
            tmp.unlink(missing_ok=True)
            raise RuntimeError(f"ffmpeg falhou: {err.decode(errors='replace')[-200:]}")
        os.replace(tmp, path)
        logger.info("[variants] %s %s → %s (%.1fs)", track_id[:8], master.label if master else "?",
                    delivery.label, time.monotonic() - started)
    _locks.pop(name, None)
    return path, delivery


def remove_for(track_id: str) -> int:
    """Apaga as versões da faixa (mestre trocado ou apagado)."""
    removed = 0
    if VARIANTS_DIR.is_dir():
        for f in VARIANTS_DIR.glob(f"{track_id}.*"):
            f.unlink(missing_ok=True)
            removed += 1
    return removed


def cleanup(days: int = VARIANT_TTL_DAYS) -> int:
    """Apaga versões sem uso há [days] dias (e restos de conversões)."""
    if not VARIANTS_DIR.is_dir():
        return 0
    limit = time.time() - days * 86400
    removed = 0
    for f in VARIANTS_DIR.iterdir():
        try:
            if f.stat().st_mtime < limit or (f.name.startswith(".") and f.stat().st_mtime < time.time() - 3600):
                f.unlink()
                removed += 1
        except OSError:
            continue
    return removed
