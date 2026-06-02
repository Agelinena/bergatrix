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

    def validate_audio(self, filepath: str, arr_event: dict = None) -> bool:
        """
        Valida se o arquivo tem trilhas de áudio originais baseando-se no payload do Sonarr/Radarr.
        """
        media_info = get_media_info(filepath)
        if not media_info:
            return False
            
        audio_streams = [s for s in media_info.get('streams', []) if s.get('codec_type') == 'audio']
        
        # Coleta metadados de idioma do FFprobe (tags.language e tags.title)
        available_langs = []
        for s in audio_streams:
            tags = s.get('tags', {})
            lang = tags.get('language', '').lower()
            title = tags.get('title', '').lower()
            available_langs.append(f"{lang} {title}")
            
        # Determinar idioma original pelo payload (arr_event) ou padrão para eng
        original_lang_code = 'eng'
        
        if arr_event:
            # Radarr / Sonarr normalmente não mandam o idioma original diretamente no webhook padrão,
            # mas podemos procurar em 'movie' ou 'series'
            if 'movie' in arr_event and 'originalLanguage' in arr_event['movie']:
                original_lang_code = arr_event['movie']['originalLanguage'].get('name', 'English').lower()
            elif 'series' in arr_event and 'originalLanguage' in arr_event['series']:
                original_lang_code = arr_event['series']['originalLanguage'].get('name', 'English').lower()

        # Mapeamento básico para códigos ISO-639-2
        lang_map = {
            'english': 'eng', 'japanese': 'jpn', 'korean': 'kor', 'spanish': 'spa',
            'french': 'fre', 'german': 'ger', 'italian': 'ita', 'portuguese': 'por'
        }
        
        expected_code = lang_map.get(original_lang_code, original_lang_code[:3])
        
        # Verifica se o código esperado está presente ou se tem "unknown" (pode ser a trilha principal sem tag)
        # Além disso, verificamos pelo título da trilha caso a tag language seja estranha
        is_valid = False
        for lang_info in available_langs:
            if expected_code in lang_info or 'unknown' in lang_info or original_lang_code in lang_info:
                is_valid = True
                break
                
        if is_valid:
            return True
            
        logger.warning(f"Áudio original ({expected_code}) ausente! Encontrado: {available_langs}")
        
        # Deletar via API do Radarr/Sonarr
        self._reject_media(filepath, arr_event)
        return False

    def _reject_media(self, filepath: str, arr_event: dict):
        """
        Deleta o arquivo via API do Radarr/Sonarr e marca como falho para forçar re-download.
        """
        if not arr_event:
            return
            
        try:
            import httpx
            import os
            
            if 'movieFile' in arr_event:
                # Radarr
                file_id = arr_event['movieFile'].get('id')
                url = os.environ.get('RADARR_URL', 'http://radarr:7878')
                api_key = os.environ.get('RADARR_API_KEY', '')
                if not file_id or not api_key:
                    return
                    
                with httpx.Client() as client:
                    client.delete(
                        f"{url}/api/v3/moviefile/{file_id}",
                        headers={"X-Api-Key": api_key}
                    )
                logger.info(f"Arquivo deletado no Radarr: ID {file_id}")
                
            elif 'episodeFile' in arr_event:
                # Sonarr
                file_id = arr_event['episodeFile'].get('id')
                url = os.environ.get('SONARR_URL', 'http://sonarr:8989')
                api_key = os.environ.get('SONARR_API_KEY', '')
                if not file_id or not api_key:
                    return
                    
                with httpx.Client() as client:
                    client.delete(
                        f"{url}/api/v3/episodefile/{file_id}",
                        headers={"X-Api-Key": api_key}
                    )
                logger.info(f"Arquivo deletado no Sonarr: ID {file_id}")
                
        except Exception as e:
            logger.error(f"Erro ao deletar arquivo via API Arr: {e}")

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
            logger.info(f"Legenda bruta obtida via Bazarr para: {fname}")
            
            # Sincronização ALASS (Sub-to-Sub)
            synced = self._sync_with_alass(filepath, output_srt, streams)
            if synced:
                logger.info(f"✅ Legenda sincronizada perfeitamente via alass: {fname}")
                self.stats.record(filepath, "success", model="bazarr_alass")
                return
            else:
                logger.warning("Falha na sincronização alass. Mantendo a original ou caindo pra IA...")
                self.stats.record(filepath, "success", model="bazarr_raw")
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

    def _sync_with_alass(self, filepath: str, downloaded_srt: str, streams: list) -> bool:
        """Extrai legenda embutida original e sincroniza a legenda do Bazarr via alass."""
        import subprocess
        base_stream = next((s for s in streams if s.get('tags', {}).get('language', '').lower() in SOURCE_LANGUAGES and s.get('codec_name') in TEXT_CODECS), None)
                
        if not base_stream:
            logger.warning("Nenhuma legenda embutida em texto para base de sincronia.")
            return False
            
        base_path = os.path.splitext(filepath)[0]
        ref_srt = f"{base_path}.ref.temp.srt"
        
        try:
            actual_dl = next((base_path + sfx for sfx in SUBTITLE_SUFFIXES if os.path.exists(base_path + sfx)), None)
            if not actual_dl: return False

            if not extract_subtitle(filepath, base_stream['index'], ref_srt): return False
                
            synced_srt = f"{base_path}.por.srt"
            cmd = ['alass', ref_srt, actual_dl, synced_srt]
            subprocess.run(cmd, check=True, capture_output=True)
            
            if actual_dl != synced_srt: os.remove(actual_dl)
            return True
        except Exception as e:
            logger.error(f"Erro no alass sync: {e}")
            return False
        finally:
            if os.path.exists(ref_srt): os.remove(ref_srt)

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
