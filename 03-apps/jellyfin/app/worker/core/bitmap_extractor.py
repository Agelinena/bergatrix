import os
import json
import shutil
import subprocess
import logging
import tempfile

logger = logging.getLogger(__name__)

# Idiomas suportados pelo Tesseract para OCR
TESSERACT_LANG_MAP = {
    "eng": "eng", "en": "eng",
    "por": "por", "pt": "por", "bra": "por", "pt-br": "por",
    "spa": "spa", "fra": "fra", "deu": "deu", "ita": "ita",
}
DEFAULT_TESSERACT_LANG = "eng"


class BitmapExtractor:
    """
    Extrai legendas bitmap (PGS / DVD) para SRT via OCR usando o **pgsrip**,
    que preserva os timestamps reais do PGS e usa o Tesseract internamente.

    Requer o binário `pgsrip` (pip install pgsrip + mkvtoolnix + tessdata).
    Se o pgsrip NÃO estiver disponível, o OCR é pulado de forma limpa.

    Nota: a versão anterior tinha um fallback "frame a frame" via ffmpeg que
    (a) falhava sempre com "image2 encoder disabled" e (b) quando não falhava,
    gerava timestamps inventados (índice do frame × duração), produzindo legendas
    completamente dessincronizadas. Esse fallback foi removido.
    """

    def __init__(self):
        self.has_pgsrip = shutil.which("pgsrip") is not None
        for cmd in ["ffmpeg", "tesseract"]:
            if shutil.which(cmd) is None:
                logger.warning(f"Dependência não encontrada: {cmd}")
        if not self.has_pgsrip:
            logger.info("pgsrip não instalado — OCR de legendas PGS/bitmap está desabilitado.")

    def _get_stream_language(self, filepath: str, stream_index: int) -> str:
        """Obtém o idioma do stream via ffprobe (para guiar o OCR)."""
        try:
            cmd = [
                "ffprobe", "-v", "quiet", "-print_format", "json",
                "-show_streams", "-select_streams", f"s:{stream_index}", filepath,
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
            streams = json.loads(result.stdout).get("streams", [])
            if streams:
                lang = streams[0].get("tags", {}).get("language", "eng").lower()
                return TESSERACT_LANG_MAP.get(lang, DEFAULT_TESSERACT_LANG)
        except Exception as e:
            logger.error(f"Erro ao obter idioma do stream: {e}")
        return DEFAULT_TESSERACT_LANG

    def _run_pgsrip(self, sup_file: str, lang: str) -> str | None:
        """
        Roda o pgsrip sobre um arquivo .sup. O pgsrip grava o .srt ao lado do
        arquivo de entrada. Retorna o caminho do .srt gerado ou None.
        """
        try:
            result = subprocess.run(
                ["pgsrip", "--language", lang, "--force", sup_file],
                capture_output=True, text=True, timeout=600,
            )
            if result.returncode != 0:
                logger.warning(f"pgsrip falhou (rc={result.returncode}): {result.stderr[:200]}")
                return None
            # pgsrip gera <base>.srt ao lado do .sup
            out_dir = os.path.dirname(sup_file)
            for f in os.listdir(out_dir):
                if f.lower().endswith(".srt"):
                    return os.path.join(out_dir, f)
            logger.warning("pgsrip terminou mas nenhum .srt foi encontrado.")
            return None
        except Exception as e:
            logger.warning(f"Erro ao executar pgsrip: {e}")
            return None

    def extract_to_srt(self, filepath: str, stream_index: int, output_srt: str) -> bool:
        """
        Extrai a legenda bitmap (stream_index) para SRT via OCR (pgsrip).
        Retorna True se bem-sucedido.
        """
        if not self.has_pgsrip:
            logger.info("OCR de PGS requer o pgsrip (não instalado) — pulando extração.")
            return False

        lang = self._get_stream_language(filepath, stream_index)
        logger.info(f"Iniciando OCR (pgsrip) do stream {stream_index} de {os.path.basename(filepath)} [lang={lang}]")

        with tempfile.TemporaryDirectory(prefix="legendarr_ocr_") as tmp_dir:
            sup_file = os.path.join(tmp_dir, "subtitle.sup")

            # Extrai o stream PGS como .sup (cópia, sem re-encode)
            cmd = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-i", filepath, "-map", f"0:{stream_index}", "-c:s", "copy", sup_file,
            ]
            result = subprocess.run(cmd, capture_output=True)
            if result.returncode != 0 or not os.path.exists(sup_file):
                logger.error(f"FFmpeg falhou ao extrair .sup: {result.stderr.decode()[:300]}")
                return False

            srt_path = self._run_pgsrip(sup_file, lang)
            if not srt_path:
                return False

            try:
                shutil.copy2(srt_path, output_srt)
                logger.info(f"OCR concluído via pgsrip: {os.path.basename(output_srt)}")
                return True
            except Exception as e:
                logger.error(f"Erro ao salvar SRT do pgsrip: {e}")
                return False
