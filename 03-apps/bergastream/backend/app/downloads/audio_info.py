"""Qualidade real de um arquivo de áudio (lida com ffprobe, não pelo nome).

`rank` ordena as qualidades para decidir se vale trocar o arquivo:

    10  baixa     MP3 ≤ 128 kbps (Deezer grátis), AAC 96 do YouTube sem PO Token
    20  média     MP3 192, Opus/AAC do YouTube (~128–160 kbps)
    30  alta      MP3 320 (Deezer Premium), AAC 256
    40  sem perda FLAC 16 bits (qualidade de CD)
    50  hi-res    FLAC 24 bits

Opus e AAC rendem mais por kbps que MP3: contam como 1,5× e 1,3× o bitrate.
"""
from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("bergastream.downloads.audio_info")

LOW, MEDIUM, HIGH, LOSSLESS, HIRES = 10, 20, 30, 40, 50
_LOSSLESS = {"flac", "alac", "wavpack", "ape", "tta"}
_EFFICIENCY = {"opus": 1.5, "aac": 1.3, "vorbis": 1.3}


@dataclass(frozen=True)
class AudioInfo:
    codec: str
    bitrate_kbps: int | None
    sample_rate: int | None
    bit_depth: int | None

    @property
    def lossless(self) -> bool:
        return self.codec in _LOSSLESS

    @property
    def rank(self) -> int:
        if self.lossless:
            return HIRES if (self.bit_depth or 16) > 16 else LOSSLESS
        equivalent = (self.bitrate_kbps or 0) * _EFFICIENCY.get(self.codec, 1.0)
        if equivalent >= 280:
            return HIGH
        if equivalent >= 150:
            return MEDIUM
        return LOW

    @property
    def format(self) -> str:
        """Rótulo da coluna `files.format` (mesmo vocabulário de antes)."""
        if self.codec == "mp3":
            kbps = self.bitrate_kbps or 0
            return "mp3_320" if kbps >= 280 else "mp3_192" if kbps >= 170 else "mp3_128"
        return {"flac": "flac", "aac": "aac", "opus": "opus", "vorbis": "vorbis"}.get(self.codec, self.codec)

    @property
    def label(self) -> str:
        """Texto curto para logs e status: "FLAC 24/96", "MP3 320", "Opus 152"."""
        if self.lossless:
            khz = (self.sample_rate or 44100) / 1000
            return f"{self.codec.upper()} {self.bit_depth or 16}/{khz:g}"
        name = {"mp3": "MP3", "aac": "AAC", "opus": "Opus", "vorbis": "Vorbis"}.get(self.codec, self.codec)
        return f"{name} {self.bitrate_kbps}" if self.bitrate_kbps else name


def _int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_ffprobe(data: dict) -> AudioInfo | None:
    stream = next((s for s in data.get("streams") or [] if s.get("codec_type") == "audio"), None)
    if stream is None:
        return None
    codec = (stream.get("codec_name") or "").lower()
    bitrate = _int(stream.get("bit_rate")) or _int((data.get("format") or {}).get("bit_rate"))
    depth = _int(stream.get("bits_per_raw_sample")) or _int(stream.get("bits_per_sample"))
    if not depth and codec in _LOSSLESS:
        depth = 24 if str(stream.get("sample_fmt", "")).startswith("s32") else 16
    return AudioInfo(
        codec=codec,
        bitrate_kbps=round(bitrate / 1000) if bitrate else None,
        sample_rate=_int(stream.get("sample_rate")),
        bit_depth=depth if codec in _LOSSLESS else None,
    )


def probe(path: Path) -> AudioInfo | None:
    """Qualidade do arquivo, ou None se o ffprobe não conseguir ler."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_streams",
             "-show_format", str(path)],
            capture_output=True, text=True, timeout=20, check=False).stdout
        return parse_ffprobe(json.loads(out or "{}"))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        logger.warning("[audio] não leu %s: %s", path, exc)
        return None
