import os
import json
import re
import logging
from .utils import get_media_info, extract_subtitle, find_pt_subtitle
from .translator import Translator
from .translation_stats import TranslationStats
from .translation_queue import TranslationQueue
from .subtitle_sync import align_by_ordinal_map, parse_srt, render_srt
from . import bazarr
from . import arr

logger = logging.getLogger(__name__)

# Idiomas que consideramos como "português" ('pb' = alpha-2 do Bazarr para Brazilian Portuguese)
TARGET_LANGUAGES = ['por', 'pt', 'pb', 'bra', 'pt-br', 'por-br', 'pob', 'portuguese']
# Idiomas de origem preferidos
SOURCE_LANGUAGES = ['eng', 'en']
# Codecs de legenda em texto (suportados diretamente)
TEXT_CODECS = ['subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'text']
# Títulos de tracks a ignorar
IGNORE_TITLES = ['commentary', 'director', 'description', 'sdh', 'forced', 'signs']

# --- Verificador de áudio ---
# Em modo estrito, rejeita também quando só há faixas sem tag ('und'); padrão = seguro.
AUDIO_CHECK_STRICT = os.environ.get("AUDIO_CHECK_STRICT", "false").lower() == "true"
# Máximo de re-downloads por mídia antes de desistir (evita loop infinito)
MAX_REDOWNLOAD_ATTEMPTS = int(os.environ.get("MAX_REDOWNLOAD_ATTEMPTS", "5"))
REJECTION_FILE = "/app/stats/audio_rejections.json"
# Tag no Radarr/Sonarr que ISENTA o item da validação de áudio (p/ manter dublado/outro idioma de propósito)
AUDIO_KEEP_TAG = os.environ.get("AUDIO_KEEP_TAG", "keep-audio").strip()
# Duração mínima (fração do runtime do Radarr/Sonarr) para o arquivo não ser considerado cortado/truncado
MIN_DURATION_RATIO = int(os.environ.get("MIN_DURATION_PERCENT", "80")) / 100.0
# Rótulo das legendas geradas por IA — vira o "título" da faixa no Jellyfin
# (ex.: "Português - AI"), deixando explícito que é tradução automática. As legendas
# do Bazarr NÃO recebem o rótulo. Evite "IA": colide com o idioma Interlingua (código 'ia');
# "AI" é seguro. Deixe vazio para desativar o rótulo (volta a salvar como .por.srt).
AI_SUBTITLE_LABEL = os.environ.get("AI_SUBTITLE_LABEL", "AI").strip()

# Nome do idioma (originalLanguage do Radarr/Sonarr) → códigos aceitos nas tags de áudio (ffprobe).
# Cobre variantes ISO-639-2 B/T e alpha-2. Idiomas fora do mapa → validação é pulada (seguro).
LANG_NAME_TO_CODES = {
    'english': {'eng', 'en'}, 'japanese': {'jpn', 'ja'}, 'korean': {'kor', 'ko'},
    'mandarin': {'chi', 'zho', 'cmn', 'zh'}, 'chinese': {'chi', 'zho', 'zh'},
    'cantonese': {'chi', 'zho', 'yue', 'zh'}, 'spanish': {'spa', 'es'},
    'french': {'fre', 'fra', 'fr'}, 'german': {'ger', 'deu', 'de'}, 'italian': {'ita', 'it'},
    'portuguese': {'por', 'pt', 'pob', 'pb'}, 'russian': {'rus', 'ru'}, 'hindi': {'hin', 'hi'},
    'dutch': {'dut', 'nld', 'nl'}, 'swedish': {'swe', 'sv'}, 'norwegian': {'nor', 'no', 'nob'},
    'danish': {'dan', 'da'}, 'finnish': {'fin', 'fi'}, 'polish': {'pol', 'pl'},
    'turkish': {'tur', 'tr'}, 'arabic': {'ara', 'ar'}, 'hebrew': {'heb', 'he'},
    'thai': {'tha', 'th'}, 'vietnamese': {'vie', 'vi'}, 'indonesian': {'ind', 'id'},
    'czech': {'cze', 'ces', 'cs'}, 'hungarian': {'hun', 'hu'}, 'greek': {'gre', 'ell', 'el'},
    'ukrainian': {'ukr', 'uk'}, 'romanian': {'rum', 'ron', 'ro'}, 'tamil': {'tam', 'ta'},
    'telugu': {'tel', 'te'}, 'flemish': {'dut', 'nld', 'nl'},
}


class Pipeline:
    def __init__(self):
        self.translator = Translator()
        self.stats = TranslationStats()
        # Fila serializada de tradução por IA (1 modelo por vez na GPU). As buscas
        # Bazarr seguem livres no fluxo; só a etapa de IA passa pela fila.
        self.translation_queue = TranslationQueue(self)
        self.translation_queue.start()

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
        """Verifica legenda externa PT-BR (case-insensitive, inclui .hi/.sdh/.forced)."""
        found = find_pt_subtitle(filepath)
        if found:
            logger.info(f"Legenda externa PT-BR encontrada: {os.path.basename(found)}")
            return True
        return False

    # ------------------------------------------------------------------ #
    # Processamento principal                                              #
    # ------------------------------------------------------------------ #

    def _should_keep_by_tag(self, arr_event: dict) -> bool:
        """
        True se o filme/série tem a tag de exceção (AUDIO_KEEP_TAG) no Radarr/Sonarr.
        Permite manter, de propósito, um item dublado/em outro idioma sem ser rejeitado.
        """
        if not AUDIO_KEEP_TAG or not arr_event:
            return False
        movie = arr_event.get('movie') or {}
        series = arr_event.get('series') or {}
        if movie.get('id'):
            # Só confia nas tags do evento quando vêm da varredura proativa (IDs confiáveis);
            # no webhook, as tags do payload são incompletas → consulta a API.
            if movie.get('_tags_reliable'):
                tid = arr.radarr_tag_id(AUDIO_KEEP_TAG)
                return tid is not None and tid in (movie.get('tags') or [])
            return arr.movie_has_tag(movie['id'], AUDIO_KEEP_TAG)
        if series.get('id'):
            if series.get('_tags_reliable'):
                tid = arr.sonarr_tag_id(AUDIO_KEEP_TAG)
                return tid is not None and tid in (series.get('tags') or [])
            return arr.series_has_tag(series['id'], AUDIO_KEEP_TAG)
        return False

    def _get_original_language(self, arr_event: dict) -> str | None:
        """Descobre o idioma original (nome, lower). Usa o payload do Arr; se faltar, consulta a API."""
        if not arr_event:
            return None
        # 1. Direto do payload do webhook
        for key in ('movie', 'series'):
            ol = (arr_event.get(key) or {}).get('originalLanguage') or {}
            if ol.get('name'):
                return ol['name'].lower()
        # 2. Consulta confiável à API do Radarr/Sonarr pelo ID
        movie_id = (arr_event.get('movie') or {}).get('id')
        series_id = (arr_event.get('series') or {}).get('id')
        if movie_id:
            return arr.get_movie_original_language(movie_id)
        if series_id:
            return arr.get_series_original_language(series_id)
        return None

    def _get_runtime(self, arr_event: dict) -> int | None:
        """Runtime esperado em minutos (payload do Arr ou consulta à API)."""
        if not arr_event:
            return None
        movie = arr_event.get('movie') or {}
        series = arr_event.get('series') or {}
        eps = arr_event.get('episodes') or []
        if movie.get('runtime'):
            return movie['runtime']
        if eps and eps[0].get('runtime'):
            return eps[0]['runtime']
        if series.get('runtime'):
            return series['runtime']
        if movie.get('id'):
            return arr.get_movie_runtime(movie['id'])
        if series.get('id'):
            return arr.get_series_runtime(series['id'])
        return None

    def _check_duration(self, filepath: str, media_info: dict, arr_event: dict) -> bool:
        """
        Detecta arquivos cortados/truncados comparando a duração real com o runtime
        que o Radarr/Sonarr conhecem. Se for muito menor, rejeita (deleta + blocklist
        + rebaixa). Retorna True se OK (ou sem como decidir), False se rejeitou.
        """
        runtime_min = self._get_runtime(arr_event)
        if not runtime_min or runtime_min < 5:
            return True  # sem runtime confiável (ex.: curta-metragem)
        try:
            actual_sec = float((media_info.get('format') or {}).get('duration', 0))
        except (TypeError, ValueError):
            return True
        if actual_sec <= 0:
            return True
        if actual_sec < runtime_min * 60 * MIN_DURATION_RATIO:
            logger.warning(
                f"Arquivo CORTADO/truncado: duração {actual_sec/60:.0f}min < esperado ~{runtime_min}min "
                f"(mín {MIN_DURATION_RATIO*100:.0f}%) — rejeitando e mandando rebaixar."
            )
            self._reject_media(filepath, arr_event)
            return False
        return True

    def validate_audio(self, filepath: str, arr_event: dict = None) -> bool:
        """
        Verifica se o arquivo tem áudio no idioma ORIGINAL.

        Retorna True se válido OU se não há como decidir com segurança (não rejeita
        no escuro). Retorna False apenas quando o idioma original é conhecido e
        comprovadamente ausente — caso em que deleta o arquivo, blocklista o release
        e dispara nova busca (o Arr baixa OUTRO release e o novo import re-verifica).
        """
        # Exceção: item marcado com a tag de "manter áudio" no Radarr/Sonarr → não mexe.
        if self._should_keep_by_tag(arr_event):
            logger.info(f"validate_audio: tag '{AUDIO_KEEP_TAG}' presente — mantendo o áudio como está (exceção).")
            return True

        media_info = get_media_info(filepath)
        if not media_info:
            logger.warning("validate_audio: não foi possível ler o arquivo — pulando validação.")
            return True

        # Arquivo cortado/truncado? (duração muito menor que o runtime do Arr) → rejeita e rebaixa
        if not self._check_duration(filepath, media_info, arr_event):
            return False

        audio_streams = [s for s in media_info.get('streams', []) if s.get('codec_type') == 'audio']
        if not audio_streams:
            logger.warning("validate_audio: nenhuma trilha de áudio encontrada — pulando.")
            return True

        original = self._get_original_language(arr_event)
        if not original:
            logger.info("validate_audio: idioma original desconhecido — pulando (benefício da dúvida).")
            return True

        expected = LANG_NAME_TO_CODES.get(original)
        if not expected:
            logger.info(f"validate_audio: idioma original '{original}' não mapeado — pulando validação.")
            return True

        audio_langs, has_undefined = set(), False
        for s in audio_streams:
            lang = (s.get('tags', {}).get('language') or '').lower().strip()
            if lang in ('', 'und', 'unknown', 'mis', 'zxx'):
                has_undefined = True
            else:
                audio_langs.add(lang)

        # Original presente?
        if expected & audio_langs:
            logger.info(f"validate_audio: OK — áudio original ({original}) presente. Trilhas: {sorted(audio_langs)}")
            return True

        # Original ausente, mas há faixa sem tag → benefício da dúvida (exceto modo estrito)
        if has_undefined and not AUDIO_CHECK_STRICT:
            logger.warning(
                f"validate_audio: original ({original}) não rotulado, mas há faixa 'und' — "
                f"mantendo (modo seguro). Trilhas: {sorted(audio_langs)}"
            )
            return True

        logger.warning(
            f"validate_audio: áudio ORIGINAL ({original} → {sorted(expected)}) AUSENTE! "
            f"Trilhas: {sorted(audio_langs)} — rejeitando e mandando rebaixar."
        )
        self._reject_media(filepath, arr_event)
        return False

    # --- Guard contra loop de re-download ---
    def _rejection_key(self, arr_event: dict, filepath: str) -> str:
        if 'movie' in (arr_event or {}):
            return f"movie:{(arr_event.get('movie') or {}).get('id')}"
        if 'series' in (arr_event or {}):
            eps = arr_event.get('episodes') or []
            return f"episode:{(arr_event.get('series') or {}).get('id')}:{eps[0].get('id') if eps else '?'}"
        return f"path:{filepath}"

    def _rejection_count(self, key: str) -> int:
        try:
            with open(REJECTION_FILE, encoding="utf-8") as f:
                return json.load(f).get(key, 0)
        except Exception:
            return 0

    def _record_rejection(self, key: str):
        try:
            data = {}
            if os.path.exists(REJECTION_FILE):
                with open(REJECTION_FILE, encoding="utf-8") as f:
                    data = json.load(f)
            data[key] = data.get(key, 0) + 1
            os.makedirs(os.path.dirname(REJECTION_FILE), exist_ok=True)
            with open(REJECTION_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f)
        except Exception as e:
            logger.error(f"Erro ao registrar rejeição: {e}")

    def _reject_media(self, filepath: str, arr_event: dict):
        """Deleta o arquivo, blocklista o release ruim e dispara nova busca (pega OUTRO release)."""
        if not arr_event:
            logger.info("_reject_media: sem dados do Arr (webhook) — não é possível rebaixar automaticamente.")
            return

        key = self._rejection_key(arr_event, filepath)
        if self._rejection_count(key) >= MAX_REDOWNLOAD_ATTEMPTS:
            logger.error(
                f"_reject_media: limite de {MAX_REDOWNLOAD_ATTEMPTS} re-downloads atingido para {key}. "
                f"Não rebaixando mais — revise manualmente (pode não haver release com o áudio original)."
            )
            return

        download_id = arr_event.get('downloadId')
        if 'movieFile' in arr_event:
            movie = arr_event.get('movie') or {}
            file_id = (arr_event.get('movieFile') or {}).get('id')
            if movie.get('id'):
                arr.reject_movie(movie['id'], file_id, download_id)
        elif 'episodeFile' in arr_event:
            series = arr_event.get('series') or {}
            file_id = (arr_event.get('episodeFile') or {}).get('id')
            ep_ids = [e.get('id') for e in (arr_event.get('episodes') or []) if e.get('id')]
            if series.get('id'):
                arr.reject_episode(series['id'], ep_ids, file_id, download_id)

        self._record_rejection(key)

    def process_file(self, filepath: str, force: bool = False, stream_index: int | None = None):
        """
        Fluxo:
          1. Verifica se já tem legenda PT-BR → pula (se não forçado)
          2. Tenta baixar via Bazarr (legenda pronta)
          3. Se Bazarr falhar → traduz via IA (extrai stream de texto e traduz)
        """
        fname = os.path.basename(filepath)
        logger.info(f"Processando: {fname} | force={force} | stream_index={stream_index}")

        model_used = self.translator.translator_model
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

        # --- Tradução forçada pela web: ignora legenda existente e Bazarr ---
        if force:
            logger.info(f"Modo forçado solicitado para {fname}: ignorando legenda existente e Bazarr, abrindo fila de IA.")
            self.translation_queue.enqueue(filepath, stream_index=stream_index, force=True)
            return

        # --- Verificação de legenda existente ---
        if not force:
            if self._has_portuguese_subtitle(filepath, media_info):
                self.stats.record(filepath, "skipped_internal", model=model_used)
                return
            if self._has_external_subtitle(filepath):
                # O usuário quer que o ALASS rode mesmo em legendas que já existem
                logger.info("Legenda externa já existe. Tentando refinar a sincronia com ALASS...")
                
                # Tenta achar qual é o arquivo real da legenda externa PT-BR
                existing_srt = find_pt_subtitle(filepath)

                if existing_srt:
                    # Sincroniza com ALASS
                    synced = self._sync_with_alass(filepath, existing_srt, streams)
                    if synced:
                        logger.info(f"✅ Legenda existente refinada perfeitamente via ALASS: {fname}")
                        self.stats.record(filepath, "success_alass_refine", model="alass")
                    else:
                        logger.warning("ALASS não conseguiu refinar a legenda existente.")
                        self.stats.record(filepath, "skipped_external", model=model_used)
                else:
                    self.stats.record(filepath, "skipped_external", model=model_used)
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
                logger.warning("Sincronização alass não aplicada. Mantendo a legenda do Bazarr.")
                # Garante que a legenda fique como .por.srt (Bazarr salva como .pb.srt),
                # formato que o Jellyfin reconhece como Português.
                self._ensure_por_name(filepath, output_srt)
                self.stats.record(filepath, "success", model="bazarr_raw")
                return

        # --- Etapa 2: Tradução via IA (ENFILEIRADA, não inline) ---
        # Em vez de traduzir aqui (o que travaria o Bazarr dos próximos itens),
        # enfileira na fila serializada e retorna. A IA roda 1 por vez na GPU; o
        # Bazarr continua correndo livremente para os demais arquivos.
        logger.info("Etapa 2/2: Bazarr não encontrou — enfileirando tradução via IA...")
        self.translation_queue.enqueue(filepath, stream_index=stream_index, force=force)

    def _do_ai_translation(self, filepath: str, stream_index: int | None = None, force: bool = False):
        """
        Tradução via IA de UM arquivo — executada pelo worker da fila (1 por vez na GPU).
        Re-obtém o estado atual do arquivo (ele pode ter sido substituído/movido pelo
        Arr enquanto aguardava na fila).
        """
        fname = os.path.basename(filepath)
        model_used = self.translator.translator_model
        # Legenda por IA recebe o rótulo no nome → o Jellyfin mostra "Português - AI".
        base = os.path.splitext(filepath)[0]
        output_srt = f"{base}.{AI_SUBTITLE_LABEL}.por.srt" if AI_SUBTITLE_LABEL else f"{base}.por.srt"

        if not os.path.exists(filepath):
            logger.info(f"IA: arquivo não existe mais — pulando tradução: {fname}")
            return

        media_info = get_media_info(filepath)
        if not media_info:
            logger.error(f"IA: não foi possível obter informações de {fname}.")
            return
        streams = [s for s in media_info.get('streams', []) if s.get('codec_type') == 'subtitle']

        logger.info(f"IA: iniciando tradução de {fname}...")

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
            logger.warning(f"Stream {chosen['index']} tem codec binário ({codec}) — não suportado. Pulando.")
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

    def _ensure_por_name(self, filepath: str, output_srt: str) -> None:
        """
        Renomeia a legenda baixada pelo Bazarr para o padrão .por.srt.

        O Bazarr salva como .pt-BR.srt / .pt-BR.hi.srt. Normalizar para .por.srt
        garante reconhecimento consistente tanto aqui quanto no player.
        """
        if os.path.exists(output_srt):
            return  # já está no formato correto (ex.: alass gerou)
        found = find_pt_subtitle(filepath)
        if found and os.path.normpath(found) != os.path.normpath(output_srt):
            try:
                os.rename(found, output_srt)
                logger.info(f"Legenda normalizada para o Jellyfin: {os.path.basename(output_srt)}")
            except Exception as e:
                logger.error(f"Falha ao normalizar nome da legenda: {e}")

    def align_with_alass(self, filepath: str, stream_index: int | None = None, source_path: str | None = None) -> bool:
        """Execução explícita de alinhamento via ALASS para um arquivo."""
        if not os.path.exists(filepath):
            logger.warning(f"ALASS: arquivo não existe mais — ignorando: {filepath}")
            return False

        media_info = get_media_info(filepath)
        streams = [] if not media_info else [s for s in media_info.get('streams', []) if s.get('codec_type') == 'subtitle']
        target_subtitle = source_path or find_pt_subtitle(filepath) or f"{os.path.splitext(filepath)[0]}.por.srt"

        if stream_index is not None:
            chosen = next((s for s in streams if s.get('index') == stream_index), None)
            if chosen and chosen.get('codec_name') in TEXT_CODECS:
                logger.info(f"ALASS: usando stream {stream_index} como referência para {os.path.basename(filepath)}")
                if not os.path.exists(target_subtitle):
                    target_subtitle = f"{os.path.splitext(filepath)[0]}.por.srt"

        return self._sync_with_alass(
            filepath,
            target_subtitle,
            streams,
            reference_stream_index=stream_index,
        )

    def _sync_with_alass(
        self,
        filepath: str,
        downloaded_srt: str,
        streams: list,
        reference_stream_index: int | None = None,
    ) -> bool:
        """Extrai legenda embutida original e sincroniza a legenda do Bazarr via alass."""
        import subprocess

        # Pega a legenda alvo real; se for passado um arquivo externo, usa ele; senão tenta localizar a PT externa
        actual_dl = downloaded_srt or find_pt_subtitle(filepath)
        if not actual_dl or not os.path.exists(actual_dl):
            logger.warning(f"ALASS: nenhuma legenda alvo encontrada para {os.path.basename(filepath)}")
            return False

        base_stream = None
        if reference_stream_index is not None:
            base_stream = next(
                (s for s in streams if s.get('index') == reference_stream_index),
                None,
            )
            if base_stream and base_stream.get('codec_name') not in TEXT_CODECS:
                base_stream = None
        if base_stream is None:
            base_stream = next(
                (
                    s for s in streams
                    if s.get('tags', {}).get('language', '').lower() in SOURCE_LANGUAGES
                    and s.get('codec_name') in TEXT_CODECS
                ),
                None,
            )

        if not base_stream:
            logger.info("ALASS: sem legenda de texto embutida como base — mantendo a legenda sem realinhar.")
            return False

        base_path = os.path.splitext(filepath)[0]
        ref_srt = f"{base_path}.ref.temp.srt"
        synced_srt = f"{base_path}.por.srt"
        tmp_out = f"{base_path}.synced.temp.srt"

        try:
            if not extract_subtitle(filepath, base_stream['index'], ref_srt):
                return False

            with open(ref_srt, "r", encoding="utf-8", errors="ignore") as reference_file:
                reference_cues = parse_srt(reference_file.read())
            with open(actual_dl, "r", encoding="utf-8", errors="ignore") as target_file:
                target_cues = parse_srt(target_file.read())

            # Quando as contagens divergem muito, o ALASS pode casar falas
            # incorretamente. O mapa ordinal preserva o texto da tradução e
            # corrige o relógio por trechos, sem exigir correspondência textual.
            count_ratio = max(len(reference_cues), len(target_cues)) / max(1, min(len(reference_cues), len(target_cues)))
            if reference_cues and target_cues and count_ratio >= 1.20:
                mapped_cues = align_by_ordinal_map(reference_cues, target_cues)
                if mapped_cues:
                    with open(synced_srt, "w", encoding="utf-8") as output_file:
                        output_file.write(render_srt(mapped_cues))
                    logger.info(
                        f"Mapa temporal por blocos concluído para {os.path.basename(filepath)}: "
                        f"{len(target_cues)} -> {len(reference_cues)} blocos de referência"
                    )
                    return True

            # Escreve em temp para não ler/escrever o mesmo .por.srt in-place
            subprocess.run(['alass', ref_srt, actual_dl, tmp_out], check=True, capture_output=True)
            if not os.path.exists(tmp_out) or os.path.getsize(tmp_out) == 0:
                logger.warning(f"ALASS gerou saída vazia para {os.path.basename(filepath)}; tentando fallback por escala temporal.")
                if self._fallback_time_ratio_sync(filepath, actual_dl, ref_srt):
                    logger.warning(f"Fallback por escala temporal resgatou a sincronização para {os.path.basename(filepath)}")
                    return True
                return False

            os.replace(tmp_out, synced_srt)  # substitui atomicamente
            # Remove a legenda original se tiver nome diferente do destino (.por.srt)
            if os.path.normpath(actual_dl) != os.path.normpath(synced_srt) and os.path.exists(actual_dl):
                os.remove(actual_dl)
            logger.info(f"ALASS concluído com sucesso para {os.path.basename(filepath)}: legenda sincronizada em {synced_srt}")
            return True
        except Exception as e:
            logger.error(f"ALASS falhou para {os.path.basename(filepath)}: {e}")
            try:
                if self._fallback_time_ratio_sync(filepath, actual_dl, ref_srt):
                    logger.warning(f"ALASS falhou, mas fallback por escala temporal resgatou a sincronização para {os.path.basename(filepath)}")
                    return True
            except Exception:
                pass
            return False
        finally:
            for tmp in (ref_srt, tmp_out):
                if os.path.exists(tmp):
                    try:
                        os.remove(tmp)
                    except OSError:
                        pass

    def _fallback_time_ratio_sync(self, filepath: str, subtitle_path: str, reference_path: str) -> bool:
        """
        Fallback heurístico para casos em que o ALASS falha porque a legenda em PT
        tem estrutura temporal muito diferente da original (ex.: 715 x 915 blocos).

        Em vez de tentar alinhar por blocos semânticos, usa uma escala temporal
        proporcional sobre todos os timestamps da legenda alvo, preservando o texto.
        """
        if not os.path.exists(subtitle_path) or not os.path.exists(reference_path):
            return False

        pattern = re.compile(r"(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})")
        try:
            with open(reference_path, "r", encoding="utf-8", errors="ignore") as f:
                ref_text = f.read()
            with open(subtitle_path, "r", encoding="utf-8", errors="ignore") as f:
                sub_text = f.read()

            ref_times = [m.group(0) for m in pattern.finditer(ref_text)]
            sub_times = [m.group(0) for m in pattern.finditer(sub_text)]
            if not ref_times or not sub_times:
                return False

            def parse_ts(raw: str):
                m = re.search(r"(\d{2}:\d{2}:\d{2}),(\d{3})", raw)
                if not m:
                    return 0.0
                hh, mm, ss = map(int, m.group(1).split(':'))
                ms = int(m.group(2))
                return hh * 3600 + mm * 60 + ss + ms / 1000.0

            ref_end = max(parse_ts(ts) for ts in ref_times)
            sub_end = max(parse_ts(ts) for ts in sub_times)
            if ref_end <= 0 or sub_end <= 0:
                return False

            ratio = ref_end / sub_end
            if abs(ratio - 1.0) < 0.05:
                return False

            def shift_ts(raw: str, factor: float):
                match = pattern.search(raw)
                if not match:
                    return raw
                start = parse_ts(match.group(1))
                end = parse_ts(match.group(2))
                def fmt(ts):
                    total_ms = int(round(ts * 1000))
                    hh = total_ms // 3600000
                    rem = total_ms % 3600000
                    mm = rem // 60000
                    rem %= 60000
                    ss = rem // 1000
                    ms = rem % 1000
                    return f"{hh:02d}:{mm:02d}:{ss:02d},{ms:03d}"
                return f"{fmt(start * factor)} --> {fmt(end * factor)}"

            new_text = sub_text
            for x in pattern.finditer(sub_text):
                raw = x.group(0)
                repl = shift_ts(raw, ratio)
                new_text = new_text.replace(raw, repl, 1)

            out_path = f"{os.path.splitext(filepath)[0]}.fallback-alass.srt"
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(new_text)

            logger.warning(f"Fallback por escala temporal aplicado para {os.path.basename(filepath)} (ratio={ratio:.3f})")
            return True
        except Exception as e:
            logger.error(f"Fallback de sincronização por escala temporal falhou para {os.path.basename(filepath)}: {e}")
            return False

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

        # guard_path: aborta a tradução se o vídeo for removido/rejeitado no meio
        success = self.translator.process(temp_srt, output_srt, guard_path=filepath)
        try:
            os.remove(temp_srt)
        except Exception:
            pass
        return success
