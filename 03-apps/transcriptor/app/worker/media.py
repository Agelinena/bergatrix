"""Entrada de mídia: baixar link (yt-dlp), conferir o arquivo (ffprobe) e
preparar o áudio (ffmpeg).

Arquivo enviado é entrada não confiável. O ffmpeg reconhece o formato pelo
conteúdo, e alguns formatos (playlist HLS, concat) fazem ele abrir outros
arquivos ou endereços. Por isso o ffprobe e o ffmpeg rodam só com os
demuxers de áudio e vídeo comuns (-format_whitelist) e só com o protocolo
file (-protocol_whitelist).
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

# Demuxers aceitos (nomes do ffmpeg). Fora daqui: hls, concat, image2, lavfi…
DEMUXERS = ("mp3,wav,flac,ogg,mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,aac,aiff,amr,avi,asf,"
            "mpeg,mpegts,caf,w64,wv,flv")
FFMPEG_INPUT = ["-protocol_whitelist", "file", "-format_whitelist", DEMUXERS]
PROBE_TIMEOUT = 60
CONVERT_TIMEOUT = 3 * 3600


class MediaError(Exception):
    """Problema com a mídia, explicado para a pessoa."""


class Canceled(Exception):
    def __init__(self):
        super().__init__("cancelado")


@dataclass(frozen=True)
class Probe:
    format_name: str
    duration: float


def probe(path: Path, max_seconds: int) -> Probe:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", *FFMPEG_INPUT, "-show_entries", "format=format_name,duration:stream=codec_type",
             "-of", "json", str(path)],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT, check=False)
    except subprocess.TimeoutExpired as error:
        raise MediaError("O arquivo demorou demais para ser lido.") from error
    try:
        data = json.loads(result.stdout or "{}")
    except ValueError:
        data = {}
    info = data.get("format") or {}
    if result.returncode != 0 or not info:
        raise MediaError("Formato não reconhecido. Envie áudio ou vídeo (mp3, m4a, wav, ogg, flac, mp4, mkv, webm…).")
    if not any(stream.get("codec_type") == "audio" for stream in data.get("streams", [])):
        raise MediaError("O arquivo não tem áudio.")
    try:
        duration = float(info.get("duration") or 0)
    except ValueError:
        duration = 0.0
    if duration <= 0:
        raise MediaError("Não foi possível saber a duração do áudio.")
    if duration > max_seconds:
        raise MediaError(f"O áudio tem {duration / 60:.0f} min; o limite é {max_seconds // 60} min.")
    return Probe(str(info.get("format_name", "")), duration)


def prepare(source: Path, directory: Path) -> tuple[Path, Path]:
    """Áudio para o Whisper (WAV 16 kHz mono) e para ouvir na tela (AAC)."""
    wav = directory / "audio.wav"
    playback = directory / "playback.m4a"
    command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *FFMPEG_INPUT, "-i", str(source),
               "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav),
               "-map", "0:a:0", "-vn", "-ac", "1", "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart",
               str(playback)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=CONVERT_TIMEOUT, check=False)
    except subprocess.TimeoutExpired as error:
        raise MediaError("A conversão do áudio demorou demais.") from error
    if result.returncode != 0 or not wav.exists():
        raise MediaError("Não foi possível converter o áudio. O arquivo pode estar corrompido.")
    return wav, playback


def download(url: str, directory: Path, *, max_bytes: int, max_seconds: int, proxy: str,
             on_progress: Callable[[float], None], canceled: Callable[[], bool]) -> tuple[Path, str]:
    """Baixa o áudio de um link (YouTube e outros sites do yt-dlp, ou link
    direto de mídia). Devolve o arquivo e o título."""
    from yt_dlp import YoutubeDL
    from yt_dlp.utils import DownloadError

    def hook(status: dict) -> None:
        if canceled():
            raise Canceled()
        if status.get("status") == "downloading":
            total = status.get("total_bytes") or status.get("total_bytes_estimate") or 0
            if total:
                on_progress(min(1.0, status.get("downloaded_bytes", 0) / total))

    def too_long(info: dict, *, incomplete: bool = False):
        duration = info.get("duration")
        if duration and duration > max_seconds:
            return f"too-long:{duration}"
        if info.get("is_live"):
            return "live"
        return None

    options = {
        "format": "bestaudio/best",
        "outtmpl": str(directory / "source.%(ext)s"),
        "noplaylist": True,
        "max_filesize": max_bytes,
        "match_filter": too_long,
        "progress_hooks": [hook],
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "socket_timeout": 30,
        "retries": 3,
        "overwrites": True,
        "cachedir": False,
    }
    if proxy:
        options["proxy"] = proxy
    try:
        with YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
    except Canceled:
        raise
    except Exception as error:
        if canceled():
            raise Canceled() from error
        if not isinstance(error, DownloadError):
            raise
        raise MediaError("Não foi possível baixar esse link. Confira se ele é público e se o endereço é "
                         "permitido (redes internas são bloqueadas).") from error
    if info is None:
        raise MediaError("Esse link não tem mídia para baixar.")
    if info.get("_type") == "playlist":
        raise MediaError("Envie o link de um vídeo ou áudio só, não de uma playlist.")
    files = sorted(p for p in directory.glob("source.*") if p.suffix not in (".part", ".ytdl"))
    if not files:
        duration = info.get("duration")
        if duration and duration > max_seconds:
            raise MediaError(f"O vídeo tem {duration / 60:.0f} min; o limite é {max_seconds // 60} min.")
        if info.get("is_live"):
            raise MediaError("Transmissões ao vivo não são suportadas.")
        raise MediaError("O arquivo passou do limite de tamanho ou não foi baixado.")
    return files[0], str(info.get("title") or "")[:200]
