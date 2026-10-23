"""Transcrição na GPU com faster-whisper (CTranslate2).

Um modelo carregado por vez; ele sai da VRAM depois de alguns minutos sem
uso, para o Jellyfin e o Ollama terem a GPU de volta. A transcrição usa o
pipeline em lotes do faster-whisper (com VAD): o áudio é cortado nos
silêncios, e não a cada N minutos, então nenhuma palavra é partida.
"""

from __future__ import annotations

import gc
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path
from time import monotonic
from typing import Callable

from app.catalog import ModelSpec
from app.formats import Segment

logger = logging.getLogger("transcriptor.engine")

# Pascal (GTX 1060): int8 é rápido; float16 não.
COMPUTE_TYPE = "int8"


class OutOfMemory(Exception):
    pass


@dataclass(frozen=True)
class Result:
    duration: float
    language: str


def gpu_info() -> dict:
    try:
        output = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used,driver_version", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10, check=True).stdout.strip().splitlines()
        name, total, used, driver = [part.strip() for part in output[0].split(",")]
        return {"name": name, "memory_total": total, "memory_used": used, "driver": driver}
    except Exception as error:
        return {"error": str(error)[:200]}


class Engine:
    def __init__(self):
        self.spec: ModelSpec | None = None
        self.model = None
        self.last_used = monotonic()

    def load(self, spec: ModelSpec, path: Path):
        from faster_whisper import WhisperModel

        if self.spec is not None and self.spec.id == spec.id:
            return self.model
        self.unload()
        logger.info("[engine] carregando %s", spec.id)
        self.model = WhisperModel(str(path), device="cuda", compute_type=COMPUTE_TYPE, cpu_threads=2,
                                  num_workers=1, local_files_only=True)
        self.spec = spec
        return self.model

    def unload(self) -> None:
        if self.model is not None:
            logger.info("[engine] tirando %s da VRAM", self.spec.id if self.spec else "?")
        self.model = None
        self.spec = None
        gc.collect()

    def unload_if_idle(self, idle_seconds: float) -> None:
        if self.model is not None and monotonic() - self.last_used > idle_seconds:
            self.unload()

    def transcribe(self, audio: Path, spec: ModelSpec, path: Path, *, language: str | None, prompt: str,
                   batch_size: int, emit: Callable[[list[Segment], float], bool]) -> Result:
        """Roda numa thread. `emit` recebe os trechos novos e o progresso
        (0..1) e devolve False para cancelar."""
        from faster_whisper import BatchedInferencePipeline

        model = self.load(spec, path)
        self.last_used = monotonic()
        pipeline = BatchedInferencePipeline(model=model)
        try:
            segments, info = pipeline.transcribe(
                str(audio), language=language, task="transcribe", beam_size=spec.beam_size,
                batch_size=batch_size, vad_filter=True, without_timestamps=False,
                condition_on_previous_text=False, initial_prompt=prompt or None)
            pending: list[Segment] = []
            index = 0
            last_emit = monotonic()
            for segment in segments:
                text = segment.text.strip()
                if text:
                    pending.append(Segment(index, int(segment.start * 1000), int(segment.end * 1000), text))
                    index += 1
                if pending and monotonic() - last_emit >= 1.0:
                    progress = min(0.99, segment.end / info.duration) if info.duration else 0.0
                    if not emit(pending, progress):
                        return Result(info.duration, info.language)
                    pending, last_emit = [], monotonic()
            if pending and not emit(pending, 0.99):
                return Result(info.duration, info.language)
            return Result(info.duration, info.language)
        except RuntimeError as error:
            if "out of memory" in str(error).lower():
                raise OutOfMemory(str(error)) from error
            raise
        finally:
            self.last_used = monotonic()
            del pipeline
            gc.collect()

    def warmup(self, spec: ModelSpec, path: Path, sample: Path) -> None:
        """Confere CUDA, cuDNN e o modelo de ponta a ponta com um áudio curto."""
        model = self.load(spec, path)
        segments, _ = model.transcribe(str(sample), language="pt", beam_size=1, vad_filter=False)
        list(segments)
        self.last_used = monotonic()
