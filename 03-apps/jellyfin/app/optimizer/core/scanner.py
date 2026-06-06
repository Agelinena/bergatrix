import time
import logging
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer

logger = logging.getLogger(__name__)

class MediaEventHandler(FileSystemEventHandler):
    def __init__(self, job_queue, debounce_interval=60, stable_seconds=10):
        self.job_queue = job_queue
        self.debounce_interval = debounce_interval
        self.stable_seconds = stable_seconds
        self.timers = {}

    def on_created(self, event):
        if not event.is_directory:
            self._schedule(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._schedule(event.dest_path)

    def on_modified(self, event):
        # Reinicia o debounce enquanto o arquivo ainda está sendo gravado (import/cópia)
        if not event.is_directory:
            self._schedule(event.src_path, quiet=True)

    def _accept(self, filepath: str) -> bool:
        if not any(filepath.lower().endswith(ext) for ext in ['.mkv', '.mp4', '.avi', '.mov']):
            return False
        abs_path = os.path.abspath(filepath)
        if not ("/media/filmes" in abs_path or "/media/series" in abs_path):
            return False
        parts = filepath.split(os.sep)
        if "downloads" in parts or "cache" in parts or ".temp." in filepath:
            return False
        return True

    def _schedule(self, filepath, quiet=False):
        if not self._accept(filepath):
            return
        if filepath in self.timers:
            self.timers[filepath].cancel()
        elif not quiet:
            logger.info(f"File detected: {filepath}. Aguardando {self.debounce_interval}s sem alterações...")
        timer = Timer(self.debounce_interval, self._trigger_queue, [filepath])
        self.timers[filepath] = timer
        timer.start()

    def _trigger_queue(self, filepath):
        self.timers.pop(filepath, None)
        if not os.path.exists(filepath):
            logger.warning(f"File {filepath} disappeared before processing.")
            return

        # CRÍTICO: confirma que o arquivo parou de crescer antes de processar.
        # Sem isto, o optimizer pegava arquivos ainda sendo importados (cópia em
        # andamento) e os re-encodava parciais, TRUNCANDO o filme.
        try:
            size1 = os.path.getsize(filepath)
            time.sleep(self.stable_seconds)
            size2 = os.path.getsize(filepath)
        except OSError:
            return
        if size1 != size2:
            logger.info(f"Ainda sendo gravado (import em andamento?): {os.path.basename(filepath)} — reagendando.")
            timer = Timer(self.debounce_interval, self._trigger_queue, [filepath])
            self.timers[filepath] = timer
            timer.start()
            return

        logger.info(f"File stabilized: {filepath}. Queueing for processing.")
        self.job_queue.put(filepath)

class Scanner:
    def __init__(self, job_queue, watch_dirs):
        self.job_queue = job_queue
        self.watch_dirs = watch_dirs
        self.observer = Observer()

    def start(self):
        event_handler = MediaEventHandler(self.job_queue)
        
        for directory in self.watch_dirs:
            if os.path.exists(directory):
                logger.info(f"Monitoring directory: {directory}")
                self.observer.schedule(event_handler, directory, recursive=True)
            else:
                logger.warning(f"Directory not found: {directory}")

        self.observer.start()
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            self.observer.stop()
        self.observer.join()
