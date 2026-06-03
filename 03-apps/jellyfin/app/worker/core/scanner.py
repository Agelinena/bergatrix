import time
import logging
import os
import json
from datetime import datetime
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer, Thread

logger = logging.getLogger(__name__)

MEDIA_EXTENSIONS = ('.mkv', '.mp4', '.avi', '.mov')
# Inclui .pb.srt — formato que o Bazarr usa para Brazilian Portuguese (alpha-2 "pb")
SUBTITLE_SUFFIXES = ('.por.srt', '.pt-br.srt', '.pt.srt', '.portuguese.srt', '.ptbr.srt', '.pb.srt')
# Intervalo de varredura periódica em segundos (padrão: 1 hora)
PERIODIC_SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "3600"))
# Janela de cooldown: tempo mínimo antes de retentar um arquivo já processado (padrão: 72h)
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_HOURS", "72")) * 3600
STATS_FILE = "/app/stats/translation_stats.json"


def _has_subtitle(filepath: str) -> bool:
    """Verifica de forma rápida se o arquivo já tem legenda PT-BR externa."""
    base = os.path.splitext(filepath)[0]
    return any(os.path.exists(base + s) for s in SUBTITLE_SUFFIXES)


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


def _load_cooldown_index() -> dict:
    """
    Lê o arquivo de stats UMA única vez e retorna {filepath: epoch_mais_recente}.

    Evita reabrir/parsear o JSON inteiro para cada arquivo da biblioteca a cada scan
    (que tornava a varredura O(arquivos × histórico)).
    """
    if not os.path.exists(STATS_FILE):
        return {}
    try:
        with open(STATS_FILE, "r", encoding="utf-8") as f:
            stats = json.load(f)
    except Exception as e:
        logger.warning(f"Não foi possível carregar índice de cooldown: {e}")
        return {}

    index: dict = {}
    for entry in stats:
        fp = entry.get("filepath")
        if not fp:
            continue
        ts = _parse_timestamp(entry.get("timestamp", 0))
        if ts > index.get(fp, 0.0):
            index[fp] = ts
    return index


def _is_on_cooldown(filepath: str, cooldown_index: dict | None = None) -> bool:
    """Verifica se o arquivo foi processado dentro da janela de cooldown."""
    if cooldown_index is None:
        cooldown_index = _load_cooldown_index()
    last = cooldown_index.get(filepath)
    if last is None:
        return False
    return (time.time() - last) < COOLDOWN_SECONDS

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
        """Executa uma varredura completa e processa arquivos sem legenda PT-BR."""
        logger.info(f"━━ Iniciando varredura ━━")
        count_found = 0
        count_queued = 0
        count_cooldown = 0

        # Carrega o índice de cooldown UMA vez por varredura (em vez de reler o JSON por arquivo)
        cooldown_index = _load_cooldown_index()

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

                    if not _has_subtitle(filepath):
                        if _is_on_cooldown(filepath, cooldown_index):
                            count_cooldown += 1
                            continue

                        logger.info(f"  Sem legenda PT-BR e fora de cooldown: {fname} — agendando processamento")
                        try:
                            self.pipeline.process_file(filepath)
                            count_queued += 1
                        except Exception as e:
                            logger.error(f"  Erro ao processar {fname}: {e}")

        logger.info(
            f"━━ Varredura concluída: {count_found} verificados, "
            f"{count_queued} processados, {count_cooldown} em cooldown ━━"
        )

    def _periodic_scan(self):
        """Roda o scan imediatamente e depois repete a cada SCAN_INTERVAL segundos."""
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
