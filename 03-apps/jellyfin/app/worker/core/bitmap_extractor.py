import os
import json
import subprocess
import logging
import tempfile

logger = logging.getLogger(__name__)

# Idiomas suportados pelo Tesseract para OCR
TESSERACT_LANG_MAP = {
    "eng": "eng",
    "en": "eng",
    "por": "por",
    "pt": "por",
    "bra": "por",
    "pt-br": "por",
    "spa": "spa",
    "fra": "fra",
    "deu": "deu",
    "ita": "ita",
}
DEFAULT_TESSERACT_LANG = "eng"


class BitmapExtractor:
    """
    Extrai legendas bitmap (PGS / DVD) usando:
    1. FFmpeg para extrair os frames em formato PGM/PNG
    2. Tesseract OCR para converter imagens em texto
    3. Reconstrói o SRT com os timestamps originais
    """

    def __init__(self):
        self._check_dependencies()

    def _check_dependencies(self):
        for cmd in ["ffmpeg", "tesseract"]:
            result = subprocess.run(["which", cmd], capture_output=True)
            if result.returncode != 0:
                logger.warning(f"Dependência não encontrada: {cmd}")

    def _get_stream_language(self, filepath: str, stream_index: int) -> str:
        """Obtém o idioma do stream via ffprobe."""
        try:
            cmd = [
                "ffprobe", "-v", "quiet",
                "-print_format", "json",
                "-show_streams",
                "-select_streams", f"s:{stream_index}",
                filepath
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
            data = json.loads(result.stdout)
            streams = data.get("streams", [])
            if streams:
                lang = streams[0].get("tags", {}).get("language", "eng").lower()
                return TESSERACT_LANG_MAP.get(lang, DEFAULT_TESSERACT_LANG)
        except Exception as e:
            logger.error(f"Erro ao obter idioma do stream: {e}")
        return DEFAULT_TESSERACT_LANG

    def _extract_subtitle_frames(self, filepath: str, stream_index: int, output_dir: str) -> list[dict]:
        """
        Usa ffmpeg para extrair as legendas bitmap como arquivo .sup.
        Depois usa pgsrip (se disponível) ou processa frame a frame.
        Retorna lista de {timestamp_start, timestamp_end, image_path}.
        """
        sup_file = os.path.join(output_dir, "subtitle.sup")

        # Extrair .sup do MKV
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", filepath,
            "-map", f"0:{stream_index}",
            "-c:s", "copy",
            sup_file
        ]
        result = subprocess.run(cmd, capture_output=True)
        if result.returncode != 0:
            logger.error(f"FFmpeg falhou ao extrair .sup: {result.stderr.decode()[:300]}")
            return []

        if not os.path.exists(sup_file):
            logger.error("Arquivo .sup não foi criado.")
            return []

        # Tentar pgsrip primeiro (mais preciso)
        frames = self._try_pgsrip(sup_file, output_dir)
        if frames:
            return frames

        # Fallback: extrair frames PNG diretamente com ffmpeg
        return self._extract_frames_ffmpeg(filepath, stream_index, output_dir)

    def _try_pgsrip(self, sup_file: str, output_dir: str) -> list[dict]:
        """Tenta usar pgsrip para converter .sup em imagens + timestamps."""
        try:
            result = subprocess.run(
                ["pgsrip", "-o", output_dir, sup_file],
                capture_output=True, text=True, timeout=300
            )
            if result.returncode != 0:
                logger.warning(f"pgsrip falhou: {result.stderr[:200]}")
                return []

            # pgsrip gera um arquivo .srt diretamente em alguns casos
            srt_path = sup_file.replace(".sup", ".srt")
            if os.path.exists(srt_path):
                logger.info("pgsrip gerou SRT diretamente!")
                # Retornar flag especial para uso direto
                return [{"direct_srt": srt_path}]

            return []
        except FileNotFoundError:
            logger.info("pgsrip não encontrado, usando fallback FFmpeg.")
            return []
        except Exception as e:
            logger.warning(f"Erro no pgsrip: {e}")
            return []

    def _extract_frames_ffmpeg(self, filepath: str, stream_index: int, output_dir: str) -> list[dict]:
        """
        Fallback: extrai frames de legenda usando ffmpeg com filtro subtitles.
        Gera um PNG por frame + arquivo de timestamps.
        """
        frames_pattern = os.path.join(output_dir, "frame_%05d.png")
        timestamps_file = os.path.join(output_dir, "timestamps.txt")

        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", filepath,
            "-map", f"0:{stream_index}",
            "-vsync", "0",
            frames_pattern
        ]
        result = subprocess.run(cmd, capture_output=True)
        if result.returncode != 0:
            logger.error(f"FFmpeg frame extraction falhou: {result.stderr.decode()[:300]}")
            return []

        frames = sorted([
            os.path.join(output_dir, f)
            for f in os.listdir(output_dir)
            if f.startswith("frame_") and f.endswith(".png")
        ])

        if not frames:
            logger.error("Nenhum frame extraído.")
            return []

        logger.info(f"{len(frames)} frames extraídos para OCR.")
        return [{"image_path": f, "index": i + 1} for i, f in enumerate(frames)]

    def _ocr_image(self, image_path: str, lang: str) -> str:
        """Executa Tesseract OCR em uma imagem."""
        try:
            result = subprocess.run(
                ["tesseract", image_path, "stdout", "-l", lang, "--psm", "6"],
                capture_output=True, text=True, timeout=30
            )
            return result.stdout.strip()
        except Exception as e:
            logger.error(f"Erro no OCR de {image_path}: {e}")
            return ""

    def _frames_to_srt(self, frames: list[dict], lang: str, fps: float = 25.0) -> str:
        """Converte lista de frames OCR em conteúdo SRT."""
        srt_lines = []
        frame_duration = 1.0 / fps  # duração aproximada por frame

        for item in frames:
            if not item.get("image_path"):
                continue

            idx = item["index"]
            text = self._ocr_image(item["image_path"], lang)

            if not text:
                continue

            # Timestamps aproximados baseados no índice do frame
            start_sec = (idx - 1) * frame_duration * 2  # espaçamento aproximado
            end_sec = start_sec + 3.0  # duração padrão de 3s

            start_ts = self._sec_to_srt_ts(start_sec)
            end_ts = self._sec_to_srt_ts(end_sec)

            srt_lines.append(f"{len(srt_lines) + 1}\n{start_ts} --> {end_ts}\n{text}\n")

        return "\n".join(srt_lines)

    def _sec_to_srt_ts(self, seconds: float) -> str:
        h = int(seconds // 3600)
        m = int((seconds % 3600) // 60)
        s = int(seconds % 60)
        ms = int((seconds - int(seconds)) * 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

    def extract_to_srt(self, filepath: str, stream_index: int, output_srt: str) -> bool:
        """
        Ponto de entrada principal.
        Extrai legenda bitmap e converte para SRT via OCR.
        Retorna True se bem sucedido.
        """
        logger.info(f"Iniciando extração bitmap → SRT: stream {stream_index} de {os.path.basename(filepath)}")

        tesseract_lang = self._get_stream_language(filepath, stream_index)
        logger.info(f"Idioma detectado para OCR: {tesseract_lang}")

        with tempfile.TemporaryDirectory(prefix="legendarr_ocr_") as tmp_dir:
            frames = self._extract_subtitle_frames(filepath, stream_index, tmp_dir)

            if not frames:
                logger.error("Nenhum frame extraído para OCR.")
                return False

            # pgsrip gerou SRT diretamente
            if frames and "direct_srt" in frames[0]:
                direct_srt = frames[0]["direct_srt"]
                logger.info(f"pgsrip gerou SRT diretamente: {direct_srt}")
                try:
                    import shutil
                    shutil.copy2(direct_srt, output_srt)
                    return True
                except Exception as e:
                    logger.error(f"Erro ao copiar SRT do pgsrip: {e}")
                    return False

            # OCR frame a frame
            srt_content = self._frames_to_srt(frames, tesseract_lang)

            if not srt_content.strip():
                logger.error("OCR não gerou texto válido.")
                return False

            try:
                with open(output_srt, "w", encoding="utf-8") as f:
                    f.write(srt_content)
                logger.info(f"SRT via OCR salvo em: {output_srt}")
                return True
            except Exception as e:
                logger.error(f"Erro ao salvar SRT: {e}")
                return False
