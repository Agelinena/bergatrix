import time
import logging
import os
import json
from datetime import datetime
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer, Thread
from .utils import has_pt_subtitle

logger = logging.getLogger(__name__)

MEDIA_EXTENSIONS = ('.mkv', '.mp4', '.avi', '.mov')
# Intervalo de varredura periódica em segundos (padrão: 1 hora)
PERIODIC_SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "3600"))
# Janela de cooldown: tempo mínimo antes de retentar um arquivo já processado (padrão: 72h)
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_HOURS", "72")) * 3600
STATS_FILE = "/app/stats/translation_stats.json"


def _has_subtitle(filepath: str) -> bool:
    """Verifica se o arquivo já tem legenda PT-BR externa (case-insensitive, inclui .hi/.sdh/.forced)."""
    return has_pt_subtitle(filepath)


def _parse_timestamp(value) -> float:
    """
    Converte um timestamp para epoch (float).

    Aceita tanto epoch numérico quanto string ISO-8601 (ex.: "2026-03-14T19:30:22").
    Esse é o cerne do bug do cooldown: as stats gravam ISO string, mas a comparação
    antiga subtraía string de float (TypeError silencioso → cooldown nunca ativava).
    """
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value).timestamp()
        except ValueError:
            return 0.0
    return 0.0


# Status que indicam que o arquivo já foi tratado de forma definitiva → não reprocessar.
RESOLVED_STATUSES = {
    "success", "success_alass_refine", "bazarr_alass", "bazarr_raw",
    "skipped_internal", "skipped_external", "aligned",
}


def _load_stats_index() -> dict:
    """
    Lê o stats UMA vez e retorna {filepath: {"ts": epoch, "status": str}} (entrada mais recente).

    Usado tanto para o cooldown quanto para saber se o arquivo já foi resolvido — evita
    reparsear o JSON para cada arquivo da biblioteca a cada scan.
    """
    if not os.path.exists(STATS_FILE):
        return {}
    try:
        with open(STATS_FILE, "r", encoding="utf-8") as f:
            stats = json.load(f)
    except Exception as e:
        logger.warning(f"Não foi possível carregar índice de stats: {e}")
        return {}

    index: dict = {}
    for entry in stats:
        fp = entry.get("filepath")
        if not fp:
            continue
        ts = _parse_timestamp(entry.get("timestamp", 0))
        if ts >= index.get(fp, {}).get("ts", -1.0):
            index[fp] = {"ts": ts, "status": entry.get("status")}
    return index


def _is_on_cooldown(filepath: str, stats_index: dict | None = None) -> bool:
    """Verifica se o arquivo foi processado dentro da janela de cooldown."""
    if stats_index is None:
        stats_index = _load_stats_index()
    info = stats_index.get(filepath)
    if not info:
        return False
    return (time.time() - info["ts"]) < COOLDOWN_SECONDS


def _is_resolved(filepath: str, stats_index: dict) -> bool:
    """True se o arquivo já foi tratado de forma definitiva (legenda obtida/alinhada/interna)."""
    info = stats_index.get(filepath)
    return bool(info and info.get("status") in RESOLVED_STATUSES)

# ------------------------------------------------------------------ #
# Watchdog: reage a arquivos novos/movidos                            #
# ------------------------------------------------------------------ #

class MediaEventHandler(FileSystemEventHandler):
    def __init__(self, pipeline, debounce_interval: int = 60):
        self.pipeline = pipeline
        self.debounce_interval = debounce_interval
        self.timers: dict = {}

    def on_created(self, event):
        if not event.is_directory:
            self._process_event(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._process_event(event.dest_path)

    def _process_event(self, filepath: str):
        # Ignora downloads em andamento
        if "downloads" in filepath.split(os.sep):
            return
        if not filepath.lower().endswith(MEDIA_EXTENSIONS):
            return

        logger.info(f"Arquivo detectado: {os.path.basename(filepath)}. Aguardando {self.debounce_interval}s...")

        # Debounce para aguardar a escrita terminar
        if filepath in self.timers:
            self.timers[filepath].cancel()
        timer = Timer(self.debounce_interval, self._trigger_pipeline, [filepath])
        self.timers[filepath] = timer
        timer.start()

    def _trigger_pipeline(self, filepath: str):
        self.timers.pop(filepath, None)
        if os.path.exists(filepath):
            logger.info(f"Arquivo estabilizado: {os.path.basename(filepath)}. Processando...")
            self.pipeline.process_file(filepath)
        else:
            logger.warning(f"Arquivo sumiu antes do processamento: {filepath}")


# ------------------------------------------------------------------ #
# Scanner principal                                                    #
# ------------------------------------------------------------------ #

class Scanner:
    def __init__(self, pipeline, watch_dirs: list[str]):
        self.pipeline = pipeline
        self.watch_dirs = watch_dirs
        self.observer = Observer()

    def _run_scan(self):
        """
        Varredura completa. Para cada arquivo:
          - já resolvido (legenda obtida/alinhada/interna) → pula;
          - tem legenda PT-BR externa ainda não alinhada → processa (ALASS refina);
          - sem legenda e fora de cooldown → processa (Bazarr → IA).
        """
        logger.info(f"━━ Iniciando varredura ━━")
        count_found = 0
        count_queued = 0
        count_cooldown = 0
        count_resolved = 0

        # Lê o stats UMA vez por varredura (timestamp + status de cada arquivo)
        stats_index = _load_stats_index()

        for watch_dir in self.watch_dirs:
            if not os.path.exists(watch_dir):
                continue
            for root, _, files in os.walk(watch_dir):
                for fname in files:
                    if not fname.lower().endswith(MEDIA_EXTENSIONS):
                        continue
                    if ".temp." in fname:
                        continue
                    filepath = os.path.join(root, fname)
                    count_found += 1

                    # Já tratado de forma definitiva (inclui legendas já alinhadas) → pula
                    if _is_resolved(filepath, stats_index):
                        count_resolved += 1
                        continue

                    has_ext = _has_subtitle(filepath)
                    # Tem legenda externa não-alinhada → alinha (ALASS). Sem legenda → respeita cooldown.
                    if has_ext or not _is_on_cooldown(filepath, stats_index):
                        motivo = "alinhar legenda existente" if has_ext else "obter legenda (Bazarr/IA)"
                        logger.info(f"  Processando ({motivo}): {fname}")
                        try:
                            self.pipeline.process_file(filepath)
                            count_queued += 1
                        except Exception as e:
                            logger.error(f"  Erro ao processar {fname}: {e}")
                    else:
                        count_cooldown += 1

        logger.info(
            f"━━ Varredura concluída: {count_found} verificados, {count_queued} processados, "
            f"{count_resolved} já resolvidos, {count_cooldown} em cooldown ━━"
        )

    def _run_audio_check(self):
        """
        Varredura proativa do acervo: garante que cada filme/episódio tenha o áudio
        no idioma ORIGINAL, consultando o Radarr/Sonarr. Os que falham são deletados,
        o release é blocklistado e uma nova busca é disparada (pega OUTRO release).
        """
        from . import arr
        if not (arr.radarr_enabled() or arr.sonarr_enabled()):
            logger.info("Varredura de áudio: RADARR/SONARR_API_KEY não configuradas — pulando.")
            return

        logger.info("━━ Varredura de áudio (idioma original) ━━")
        checked = rejected = 0

        # Filmes (Radarr)
        if arr.radarr_enabled():
            for m in arr.list_movies():
                mf = m.get("movieFile") or {}
                path = mf.get("path")
                if not path or not os.path.exists(path):
                    continue
                event = {
                    "movie": {"id": m.get("id"), "originalLanguage": m.get("originalLanguage")},
                    "movieFile": {"id": mf.get("id")},
                    "downloadId": None,
                }
                checked += 1
                try:
                    if not self.pipeline.validate_audio(path, event):
                        rejected += 1
                except Exception as e:
                    logger.error(f"Erro na validação de áudio de {os.path.basename(path)}: {e}")

        # Séries/episódios (Sonarr)
        if arr.sonarr_enabled():
            for s in arr.list_series():
                ol = s.get("originalLanguage")
                for ef in arr.list_series_episode_files(s.get("id")):
                    path = ef["path"]
                    if not os.path.exists(path):
                        continue
                    event = {
                        "series": {"id": s.get("id"), "originalLanguage": ol},
                        "episodeFile": {"id": ef["episode_file_id"]},
                        "episodes": [{"id": ef["episode_id"]}],
                        "downloadId": None,
                    }
                    checked += 1
                    try:
                        if not self.pipeline.validate_audio(path, event):
                            rejected += 1
                    except Exception as e:
                        logger.error(f"Erro na validação de áudio de {os.path.basename(path)}: {e}")

        logger.info(f"━━ Varredura de áudio concluída: {checked} verificados, {rejected} rejeitados (rebaixando) ━━")

    def _periodic_scan(self):
        """Roda o scan imediatamente e depois repete a cada SCAN_INTERVAL segundos."""
        # Validação proativa de áudio (uma vez, no boot) antes da varredura de legendas
        self._run_audio_check()

        # Scan inicial (logo após o watchdog iniciar)
        logger.info(f"Executando scan inicial...")
        self._run_scan()

        while True:
            logger.info(f"Próximo scan automático em {PERIODIC_SCAN_INTERVAL}s.")
            time.sleep(PERIODIC_SCAN_INTERVAL)
            self._run_scan()

    def start(self):
        # Watchdog: monitora eventos em tempo real
        event_handler = MediaEventHandler(self.pipeline)
        for directory in self.watch_dirs:
            if os.path.exists(directory):
                logger.info(f"Monitorando (watchdog): {directory}")
                self.observer.schedule(event_handler, directory, recursive=True)
            else:
                logger.warning(f"Diretório não encontrado: {directory}")

        self.observer.start()

        # Thread de varredura periódica (não bloqueia o watchdog)
        scan_thread = Thread(target=self._periodic_scan, daemon=True)
        scan_thread.start()
        logger.info(f"Varredura periódica agendada a cada {PERIODIC_SCAN_INTERVAL}s ({PERIODIC_SCAN_INTERVAL // 60} min).")

        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            self.observer.stop()
        self.observer.join()
