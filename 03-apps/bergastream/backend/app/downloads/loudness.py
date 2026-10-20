"""Volume percebido de cada arquivo (normalização de volume no app).

Mede com o filtro `loudnorm` do ffmpeg (EBU R128): o volume integrado em
LUFS e o pico real em dBTP. O app usa para abaixar as músicas mais altas até
um alvo comum, como o Spotify faz. Medir decodifica o arquivo inteiro (1–3 s
por música): roda no worker, depois do download, e as antigas são medidas
aos poucos (backfill).
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import subprocess
from pathlib import Path

logger = logging.getLogger("bergastream.downloads.loudness")

_JSON = re.compile(r"\{[^{}]*\"input_i\"[^{}]*\}", re.DOTALL)
_pending: set[asyncio.Task] = set()  # referência às medições em andamento


def measure(path: Path) -> tuple[float, float] | None:
    """(LUFS integrado, pico real em dBTP) ou None se não deu para medir."""
    try:
        run = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-map", "0:a:0",
             "-af", "loudnorm=print_format=json", "-f", "null", "-"],
            capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.warning("[loudness] %s: %s", path.name, exc)
        return None
    match = _JSON.search(run.stderr or "")
    if not match:
        return None
    try:
        data = json.loads(match.group(0))
        lufs, peak = float(data["input_i"]), float(data["input_tp"])
    except (ValueError, KeyError):
        return None
    if lufs == float("-inf") or lufs < -70:  # silêncio
        return None
    return round(lufs, 2), round(peak, 2)


async def measure_and_store(pool, track_id: str, path: Path) -> bool:
    result = await asyncio.to_thread(measure, path)
    if result is None:
        return False
    # Só grava se o arquivo ainda é o mesmo (pode ter sido trocado no meio).
    await pool.execute(
        "UPDATE files SET loudness_lufs = $2, true_peak_db = $3 WHERE track_id = $1 AND path = $4",
        track_id, result[0], result[1], str(path))
    return True


def measure_later(pool, track_id: str, path: Path) -> None:
    """Mede em segundo plano (o download não espera)."""
    task = asyncio.create_task(measure_and_store(pool, track_id, path))
    _pending.add(task)
    task.add_done_callback(_pending.discard)


async def backfill(pool, limit: int = 20) -> int:
    """Mede arquivos baixados antes desta versão (alguns por rodada)."""
    rows = await pool.fetch(
        """SELECT track_id, path FROM files
           WHERE loudness_lufs IS NULL AND quality_rank > 0
           ORDER BY last_played_at DESC NULLS LAST LIMIT $1""", limit)
    measured = 0
    for r in rows:
        path = Path(r["path"])
        if path.is_file() and await measure_and_store(pool, str(r["track_id"]), path):
            measured += 1
        else:
            # Sem como medir (arquivo sumido/silêncio): não tenta de novo.
            await pool.execute(
                "UPDATE files SET loudness_lufs = 0, true_peak_db = 0 WHERE track_id = $1 AND path = $2",
                r["track_id"], r["path"])
    if measured:
        logger.info("[loudness] %d arquivo(s) medido(s)", measured)
    return measured
