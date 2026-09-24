"""Subtitle alignment helpers for structurally different SRT files."""

from dataclasses import dataclass
import re
from typing import Iterable


_TIMESTAMP = re.compile(
    r"(?P<start>\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*"
    r"(?P<end>\d{2}:\d{2}:\d{2}[,.]\d{3})"
)


@dataclass
class Cue:
    start: float
    end: float
    text: str


def parse_timestamp(value: str) -> float:
    hours, minutes, seconds = value.replace(".", ",").split(":")
    whole, millis = seconds.split(",")
    return int(hours) * 3600 + int(minutes) * 60 + int(whole) + int(millis) / 1000


def format_timestamp(value: float) -> str:
    total_ms = max(0, int(round(value * 1000)))
    hours, remainder = divmod(total_ms, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, millis = divmod(remainder, 1_000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def parse_srt(content: str) -> list[Cue]:
    cues = []
    for block in re.split(r"\n\s*\n", content.replace("\r\n", "\n").strip()):
        lines = block.split("\n")
        match = next((item for item in (_TIMESTAMP.search(line) for line in lines) if item), None)
        if not match:
            continue
        text_line = next((index for index, line in enumerate(lines) if _TIMESTAMP.search(line)), -1)
        text = "\n".join(lines[text_line + 1:]).strip()
        cues.append(Cue(parse_timestamp(match.group("start")), parse_timestamp(match.group("end")), text))
    return cues


def render_srt(cues: Iterable[Cue]) -> str:
    blocks = []
    for index, cue in enumerate(cues, start=1):
        blocks.append(
            f"{index}\n{format_timestamp(cue.start)} --> {format_timestamp(cue.end)}\n{cue.text.strip()}"
        )
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def _interpolate(value: float, points: list[tuple[float, float]]) -> float:
    if value <= points[0][0]:
        return points[0][1]
    if value >= points[-1][0]:
        return points[-1][1]
    for (left_x, left_y), (right_x, right_y) in zip(points, points[1:]):
        if value <= right_x:
            width = right_x - left_x
            if width <= 0:
                return right_y
            fraction = (value - left_x) / width
            return left_y + (right_y - left_y) * fraction
    return points[-1][1]


def build_ordinal_time_map(reference: list[Cue], target: list[Cue]) -> list[tuple[float, float]]:
    """Build a monotonic piecewise map using cue order and timeline endpoints."""
    if not reference or not target:
        return []
    reference_end = max(cue.end for cue in reference)
    target_end = max(cue.end for cue in target)
    if reference_end <= 0 or target_end <= 0:
        return []

    points = [(0.0, 0.0)]
    for index, cue in enumerate(target):
        position = index / max(1, len(target) - 1)
        reference_index = round(position * (len(reference) - 1))
        reference_cue = reference[reference_index]
        target_center = (cue.start + cue.end) / 2
        reference_center = (reference_cue.start + reference_cue.end) / 2
        points.append((target_center, reference_center))
    points.append((target_end, reference_end))

    result = []
    for x, y in sorted(points):
        if result and x <= result[-1][0]:
            continue
        if result and y < result[-1][1]:
            y = result[-1][1]
        result.append((x, y))
    return result


def align_by_ordinal_map(reference: list[Cue], target: list[Cue]) -> list[Cue]:
    """Retimes target cues without changing text, preserving local cue duration."""
    points = build_ordinal_time_map(reference, target)
    if not points:
        return []
    aligned = []
    for cue in target:
        start = _interpolate(cue.start, points)
        end = _interpolate(cue.end, points)
        if end <= start:
            end = start + min(1.0, max(0.2, cue.end - cue.start))
        aligned.append(Cue(start, end, cue.text))
    return aligned


def alignment_metrics(original: list[Cue], aligned: list[Cue]) -> dict:
    """Summarize timing changes for logs and operational diagnostics."""
    pairs = list(zip(original, aligned))
    start_deltas = [abs(new.start - old.start) for old, new in pairs]
    end_deltas = [abs(new.end - old.end) for old, new in pairs]
    changed = sum(
        1 for old, new in pairs
        if abs(new.start - old.start) >= 0.001 or abs(new.end - old.end) >= 0.001
    )
    return {
        "original_cues": len(original),
        "aligned_cues": len(aligned),
        "changed_cues": changed,
        "average_start_delta": sum(start_deltas) / len(start_deltas) if start_deltas else 0.0,
        "maximum_start_delta": max(start_deltas, default=0.0),
        "average_end_delta": sum(end_deltas) / len(end_deltas) if end_deltas else 0.0,
        "maximum_end_delta": max(end_deltas, default=0.0),
    }
