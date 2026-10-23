"""Exportação da transcrição: texto corrido, SRT, WebVTT e JSON."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Iterable

# Parágrafo novo depois de uma pausa longa ou de um parágrafo comprido.
PARAGRAPH_PAUSE_MS = 2000
PARAGRAPH_MAX_CHARS = 700


@dataclass(frozen=True)
class Segment:
    idx: int
    start_ms: int
    end_ms: int
    text: str


def timestamp(ms: int, separator: str = ".") -> str:
    hours, rest = divmod(max(0, ms), 3_600_000)
    minutes, rest = divmod(rest, 60_000)
    seconds, millis = divmod(rest, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}{separator}{millis:03d}"


def paragraphs(segments: Iterable[Segment]) -> list[str]:
    result: list[str] = []
    current: list[str] = []
    length = 0
    last_end: int | None = None
    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue
        pause = last_end is not None and segment.start_ms - last_end >= PARAGRAPH_PAUSE_MS
        if current and (pause or length >= PARAGRAPH_MAX_CHARS):
            result.append(" ".join(current))
            current, length = [], 0
        current.append(text)
        length += len(text) + 1
        last_end = segment.end_ms
    if current:
        result.append(" ".join(current))
    return result


def to_text(segments: Iterable[Segment]) -> str:
    return "\n\n".join(paragraphs(segments)) + "\n"


def to_srt(segments: Iterable[Segment]) -> str:
    blocks = []
    for number, segment in enumerate((s for s in segments if s.text.strip()), start=1):
        blocks.append(f"{number}\n{timestamp(segment.start_ms, ',')} --> {timestamp(segment.end_ms, ',')}\n"
                      f"{segment.text.strip()}\n")
    return "\n".join(blocks)


def to_vtt(segments: Iterable[Segment]) -> str:
    blocks = ["WEBVTT\n"]
    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue
        # "-->" no texto quebraria o arquivo.
        blocks.append(f"{timestamp(segment.start_ms)} --> {timestamp(segment.end_ms)}\n{text.replace('-->', '->')}\n")
    return "\n".join(blocks)


def to_json(job: dict, segments: Iterable[Segment]) -> str:
    return json.dumps({
        "id": str(job["id"]),
        "title": job["title"],
        "language": job.get("detected_language") or job.get("language"),
        "model": job["model"],
        "duration_seconds": job.get("duration_seconds"),
        "segments": [{"start": s.start_ms / 1000, "end": s.end_ms / 1000, "text": s.text.strip()} for s in segments],
    }, ensure_ascii=False, indent=2) + "\n"


EXPORTS = {
    "txt": ("text/plain; charset=utf-8", to_text),
    "srt": ("application/x-subrip; charset=utf-8", to_srt),
    "vtt": ("text/vtt; charset=utf-8", to_vtt),
}
