import os
import logging
import subprocess
import json
from .utils import get_media_info, check_existing_subtitle, extract_subtitle
from .translator import Translator
from .bitmap_extractor import BitmapExtractor
from .translation_stats import TranslationStats

logger = logging.getLogger(__name__)

# Idiomas que consideramos como "português"
TARGET_LANGUAGES = ['por', 'pt', 'bra', 'pt-br', 'por-br', 'pob', 'portuguese']
# Idiomas de origem preferidos (inglês primeiro)
SOURCE_LANGUAGES = ['eng', 'en']
# Codecs de legenda em texto (suportados diretamente)
TEXT_CODECS = ['subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'text']
# Codecs bitmap (requerem OCR)
BITMAP_CODECS = ['hdmv_pgs_subtitle', 'dvd_subtitle', 'dvdsub', 'pgssub']
# Variantes de nome de arquivo de legenda PT-BR
SUBTITLE_SUFFIXES = ['.por.srt', '.pt-br.srt', '.pt.srt', '.portuguese.srt', '.ptbr.srt']
# Títulos de tracks a ignorar
IGNORE_TITLES = ['commentary', 'director', 'description', 'sdh', 'forced', 'signs']


class Pipeline:
    def __init__(self):
        self.translator = Translator()
        self.bitmap_extractor = BitmapExtractor()
        self.stats = TranslationStats()

    # ------------------------------------------------------------------ #
    # Listagem de streams (para a UI)                                      #
    # ------------------------------------------------------------------ #

    def list_subtitles(self, filepath: str) -> list[dict]:
        """
        Retorna todos os streams de legenda disponíveis no arquivo.
        Usado pela API web para exibir opções ao usuário.
        """
        media_info = get_media_info(filepath)
        if not media_info:
            return []

        subtitle_streams = []
        for stream in media_info.get('streams', []):
            if stream.get('codec_type') != 'subtitle':
                continue

            tags = stream.get('tags', {})
            codec = stream.get('codec_name', 'unknown')
            lang = tags.get('language', 'unknown').lower()
            title = tags.get('title', '')
            is_bitmap = codec in BITMAP_CODECS
            is_text = codec in TEXT_CODECS

            subtitle_streams.append({
                "index": stream['index'],
                "codec": codec,
                "language": lang,
                "title": title,
                "is_bitmap": is_bitmap,
                "is_text": is_text,
                "label": self._make_label(lang, title, codec, is_bitmap),
            })

        return subtitle_streams

    def _make_label(self, lang: str, title: str, codec: str, is_bitmap: bool) -> str:
        parts = []
        if lang and lang != 'unknown':
            parts.append(lang.upper())
        if title:
            parts.append(title)
        parts.append(f"[{codec}]")
        if is_bitmap:
            parts.append("🖼️ OCR")
        return " — ".join(parts)

    # ------------------------------------------------------------------ #
    # Verificação de legenda existente (reforçada)                         #
    # ------------------------------------------------------------------ #

    def _has_portuguese_subtitle(self, filepath: str, media_info: dict) -> bool:
        """Verifica legenda PT-BR interna (múltiplas variantes de tag)."""
        for stream in media_info.get('streams', []):
            if stream.get('codec_type') != 'subtitle':
                continue
            tags = stream.get('tags', {})
            lang = tags.get('language', '').lower()
            if lang in TARGET_LANGUAGES:
                logger.info(f"Legenda PT-BR interna encontrada (stream {stream['index']}, lang={lang}).")
                return True
        return False

    def _has_external_subtitle(self, filepath: str) -> bool:
        """Verifica legendas externas com diversas variantes de nome."""
        base = os.path.splitext(filepath)[0]
        base_dir = os.path.dirname(filepath)
        base_name = os.path.basename(base)

        try:
            for f in os.listdir(base_dir):
                if not f.startswith(base_name):
                    continue
                suffix = f[len(base_name):].lower()
                if suffix in SUBTITLE_SUFFIXES:
                    logger.info(f"Legenda externa PT-BR encontrada: {f}")
                    return True
        except Exception as e:
            logger.error(f"Erro ao verificar legendas externas: {e}")
        return False

    # ------------------------------------------------------------------ #
    # Processamento principal                                              #
    # ------------------------------------------------------------------ #

    def process_file(self, filepath: str, force: bool = False, stream_index: int | None = None):
        """
        Processa um arquivo de mídia:
        - Se stream_index informado: usa esse stream diretamente.
        - Caso contrário: auto-detecta a melhor legenda disponível.
        - Suporta legendas texto e bitmap (via OCR).
        """
        logger.info(f"Processando: {os.path.basename(filepath)} | force={force} | stream_index={stream_index}")

        model_used = self.translator.model
        base_path = os.path.splitext(filepath)[0]
        output_srt = f"{base_path}.por.srt"

        media_info = get_media_info(filepath)
        if not media_info:
            logger.error("Não foi possível obter informações do arquivo.")
            return

        streams = [s for s in media_info.get('streams', []) if s.get('codec_type') == 'subtitle']

        # Log detalhado de todos os streams
        for s in streams:
            tags = s.get('tags', {})
            logger.info(
                f"  Stream {s['index']}: codec={s.get('codec_name')} "
                f"lang={tags.get('language', '?')} title={tags.get('title', '')}"
            )

        # --- Verificação de legenda existente (skip se não forçado) ---
        if not force:
            if self._has_portuguese_subtitle(filepath, media_info):
                self.stats.record(filepath, "skipped", model=model_used)
                return
            if self._has_external_subtitle(filepath):
                self.stats.record(filepath, "skipped", model=model_used)
                return

        # --- Se stream_index especificado pelo usuário, usa direto ---
        if stream_index is not None:
            target_stream = next((s for s in streams if s['index'] == stream_index), None)
            if not target_stream:
                logger.error(f"Stream {stream_index} não encontrado.")
                self.stats.record(filepath, "failed", model=model_used)
                return
            success = self._translate_stream(filepath, target_stream, output_srt, model_used)
            status = "success" if success else "failed"
            self.stats.record(
                filepath, status,
                source_lang=target_stream.get('tags', {}).get('language', 'unknown'),
                source_codec=target_stream.get('codec_name', 'unknown'),
                stream_index=stream_index,
                model=model_used,
            )
            return

        # --- Auto-detecção: prioridade inglês texto > qualquer texto > bitmap ---
        chosen = self._auto_select_stream(streams)
        if chosen:
            success = self._translate_stream(filepath, chosen, output_srt, model_used)
            status = "success" if success else "failed"
            self.stats.record(
                filepath, status,
                source_lang=chosen.get('tags', {}).get('language', 'unknown'),
                source_codec=chosen.get('codec_name', 'unknown'),
                stream_index=chosen['index'],
                model=model_used,
            )
        else:
            logger.info("Nenhuma legenda adequada encontrada para tradução.")
            self.stats.record(filepath, "failed", model=model_used)

    def _auto_select_stream(self, streams: list) -> dict | None:
        """Seleciona automaticamente o melhor stream para tradução."""
        # 1. Inglês em formato texto (sem tracks indesejados)
        for s in streams:
            tags = s.get('tags', {})
            lang = tags.get('language', '').lower()
            title = tags.get('title', '').lower()
            if lang in SOURCE_LANGUAGES and s.get('codec_name') in TEXT_CODECS:
                if not any(x in title for x in IGNORE_TITLES):
                    logger.info(f"Auto-selecionado: inglês texto (stream {s['index']})")
                    return s

        # 2. Qualquer texto (não-PT, sem tracks indesejados)
        for s in streams:
            tags = s.get('tags', {})
            lang = tags.get('language', '').lower()
            title = tags.get('title', '').lower()
            if lang in TARGET_LANGUAGES:
                continue
            if s.get('codec_name') in TEXT_CODECS:
                if not any(x in title for x in IGNORE_TITLES):
                    logger.info(f"Auto-selecionado: texto genérico (stream {s['index']}, lang={lang})")
                    return s

        # 3. Bitmap (PGS/DVD) — vai para OCR
        for s in streams:
            tags = s.get('tags', {})
            lang = tags.get('language', '').lower()
            title = tags.get('title', '').lower()
            if lang in TARGET_LANGUAGES:
                continue
            if s.get('codec_name') in BITMAP_CODECS:
                if not any(x in title for x in IGNORE_TITLES):
                    logger.info(f"Auto-selecionado: bitmap OCR (stream {s['index']}, codec={s.get('codec_name')})")
                    return s

        return None

    def _translate_stream(self, filepath: str, stream: dict, output_srt: str, model_used: str) -> bool:
        """Extrai e traduz um stream de legenda (texto ou bitmap)."""
        base_path = os.path.splitext(filepath)[0]
        codec = stream.get('codec_name', '')
        idx = stream['index']

        if codec in BITMAP_CODECS:
            # --- Fluxo bitmap: OCR → SRT → traduz ---
            temp_ocr_srt = f"{base_path}.ocr.temp.srt"
            logger.info(f"Stream bitmap detectado ({codec}). Iniciando OCR...")
            if not self.bitmap_extractor.extract_to_srt(filepath, idx, temp_ocr_srt):
                logger.error("OCR falhou.")
                return False
            success = self.translator.process(temp_ocr_srt, output_srt)
            try:
                os.remove(temp_ocr_srt)
            except Exception:
                pass
            return success
        else:
            # --- Fluxo texto: extrai SRT → traduz ---
            temp_eng_srt = f"{base_path}.src.temp.srt"
            if not extract_subtitle(filepath, idx, temp_eng_srt):
                logger.error(f"Falha ao extrair stream {idx}.")
                return False
            success = self.translator.process(temp_eng_srt, output_srt)
            try:
                os.remove(temp_eng_srt)
            except Exception:
                pass
            return success
