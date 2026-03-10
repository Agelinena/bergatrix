import os
import logging
from .utils import get_media_info, extract_subtitle
from .translator import Translator
from .translation_stats import TranslationStats
from . import bazarr

logger = logging.getLogger(__name__)

# Idiomas que consideramos como "português"
TARGET_LANGUAGES = ['por', 'pt', 'bra', 'pt-br', 'por-br', 'pob', 'portuguese']
# Idiomas de origem preferidos
SOURCE_LANGUAGES = ['eng', 'en']
# Codecs de legenda em texto (suportados diretamente)
TEXT_CODECS = ['subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'text']
# Variantes de nome de arquivo de legenda PT-BR
SUBTITLE_SUFFIXES = ['.por.srt', '.pt-br.srt', '.pt.srt', '.portuguese.srt', '.ptbr.srt']
# Títulos de tracks a ignorar
IGNORE_TITLES = ['commentary', 'director', 'description', 'sdh', 'forced', 'signs']


class Pipeline:
    def __init__(self):
        self.translator = Translator()
        self.stats = TranslationStats()

    # ------------------------------------------------------------------ #
    # Listagem de streams (para a UI)                                      #
    # ------------------------------------------------------------------ #

    def list_subtitles(self, filepath: str) -> list[dict]:
        """Retorna todos os streams de legenda disponíveis no arquivo."""
        media_info = get_media_info(filepath)
        if not media_info:
            return []

        result = []
        for stream in media_info.get('streams', []):
            if stream.get('codec_type') != 'subtitle':
                continue
            tags = stream.get('tags', {})
            codec = stream.get('codec_name', 'unknown')
            lang = tags.get('language', 'unknown').lower()
            title = tags.get('title', '')
            is_text = codec in TEXT_CODECS

            label_parts = []
            if lang and lang != 'unknown':
                label_parts.append(lang.upper())
            if title:
                label_parts.append(title)
            label_parts.append(f"[{codec}]")
            if not is_text:
                label_parts.append("⚠️ binário")

            result.append({
                "index": stream['index'],
                "codec": codec,
                "language": lang,
                "title": title,
                "is_text": is_text,
                "label": " — ".join(label_parts),
            })

        return result

    # ------------------------------------------------------------------ #
    # Verificação de legenda existente                                     #
    # ------------------------------------------------------------------ #

    def _has_portuguese_subtitle(self, filepath: str, media_info: dict) -> bool:
        """Verifica legenda PT-BR interna."""
        for stream in media_info.get('streams', []):
            if stream.get('codec_type') != 'subtitle':
                continue
            lang = stream.get('tags', {}).get('language', '').lower()
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
        Fluxo:
          1. Verifica se já tem legenda PT-BR → pula (se não forçado)
          2. Tenta baixar via Bazarr (legenda pronta)
          3. Se Bazarr falhar → traduz via IA (extrai stream de texto e traduz)
        """
        fname = os.path.basename(filepath)
        logger.info(f"Processando: {fname} | force={force} | stream_index={stream_index}")

        model_used = self.translator.model
        base_path = os.path.splitext(filepath)[0]
        output_srt = f"{base_path}.por.srt"

        media_info = get_media_info(filepath)
        if not media_info:
            logger.error("Não foi possível obter informações do arquivo.")
            return

        streams = [s for s in media_info.get('streams', []) if s.get('codec_type') == 'subtitle']

        # Log detalhado de streams
        for s in streams:
            tags = s.get('tags', {})
            logger.info(
                f"  Stream {s['index']}: codec={s.get('codec_name')} "
                f"lang={tags.get('language', '?')} title={tags.get('title', '')}"
            )

        # --- Verificação de legenda existente ---
        if not force:
            if self._has_portuguese_subtitle(filepath, media_info):
                self.stats.record(filepath, "skipped", model=model_used)
                return
            if self._has_external_subtitle(filepath):
                self.stats.record(filepath, "skipped", model=model_used)
                return

        # --- Etapa 1: Bazarr ---
        logger.info(f"Etapa 1/2: Tentando Bazarr...")
        if bazarr.search_and_download(filepath):
            logger.info(f"✅ Legenda obtida via Bazarr para: {fname}")
            self.stats.record(filepath, "success", model="bazarr")
            return

        # --- Etapa 2: Tradução via IA ---
        logger.info(f"Etapa 2/2: Bazarr não encontrou — iniciando tradução via IA...")

        # Seleciona stream
        if stream_index is not None:
            chosen = next((s for s in streams if s['index'] == stream_index), None)
            if not chosen:
                logger.error(f"Stream {stream_index} não encontrado.")
                self.stats.record(filepath, "failed", model=model_used)
                return
        else:
            chosen = self._auto_select_stream(streams)

        if not chosen:
            logger.info("Nenhuma legenda em texto adequada para tradução.")
            self.stats.record(filepath, "failed", model=model_used)
            return

        codec = chosen.get('codec_name', '')
        if codec not in TEXT_CODECS:
            logger.warning(f"Stream {chosen['index']} tem codec binário ({codec}) — não suportado sem OCR. Pulando.")
            self.stats.record(filepath, "skipped", model=model_used)
            return

        lang = chosen.get('tags', {}).get('language', 'unknown')
        success = self._translate_stream(filepath, chosen, output_srt)
        status = "success" if success else "failed"
        self.stats.record(
            filepath, status,
            source_lang=lang,
            source_codec=codec,
            stream_index=chosen['index'],
            model=model_used,
        )

    def _auto_select_stream(self, streams: list) -> dict | None:
        """Seleciona automaticamente o melhor stream de texto para tradução."""
        # 1. Inglês em texto (sem tracks indesejados)
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

        return None

    def _translate_stream(self, filepath: str, stream: dict, output_srt: str) -> bool:
        """Extrai legenda de texto e traduz via IA."""
        base_path = os.path.splitext(filepath)[0]
        idx = stream['index']
        temp_srt = f"{base_path}.src.temp.srt"

        if not extract_subtitle(filepath, idx, temp_srt):
            logger.error(f"Falha ao extrair stream {idx}.")
            return False

        success = self.translator.process(temp_srt, output_srt)
        try:
            os.remove(temp_srt)
        except Exception:
            pass
        return success
