import time
import logging
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer, Thread

logger = logging.getLogger(__name__)

MEDIA_EXTENSIONS = ('.mkv', '.mp4', '.avi', '.mov')
SUBTITLE_SUFFIXES = ('.por.srt', '.pt-br.srt', '.pt.srt', '.portuguese.srt', '.ptbr.srt')
# Intervalo de varredura periódica em segundos (padrão: 1 hora)
PERIODIC_SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "3600"))


def _has_subtitle(filepath: str) -> bool:
    """Verifica de forma rápida se o arquivo já tem legenda PT-BR externa."""
    base = os.path.splitext(filepath)[0]
    return any(os.path.exists(base + s) for s in SUBTITLE_SUFFIXES)


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

    def _periodic_scan(self):
        """
        Varredura completa a cada SCAN_INTERVAL segundos.
        Enfileira para tradução apenas arquivos que ainda não têm legenda PT-BR.
        """
        while True:
            time.sleep(PERIODIC_SCAN_INTERVAL)
            logger.info(f"━━ Varredura periódica iniciada (intervalo: {PERIODIC_SCAN_INTERVAL}s) ━━")
            count_found = 0
            count_queued = 0

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
                            logger.info(f"  Sem legenda PT-BR: {fname} — agendando tradução")
                            try:
                                self.pipeline.process_file(filepath)
                                count_queued += 1
                            except Exception as e:
                                logger.error(f"  Erro ao processar {fname}: {e}")

            logger.info(
                f"━━ Varredura concluída: {count_found} arquivos verificados, "
                f"{count_queued} sem legenda processados ━━"
            )

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
