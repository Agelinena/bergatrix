import time
import logging
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer

logger = logging.getLogger(__name__)

class MediaEventHandler(FileSystemEventHandler):
    def __init__(self, job_queue, debounce_interval=60):
        self.job_queue = job_queue
        self.debounce_interval = debounce_interval
        self.timers = {}

    def on_created(self, event):
        if event.is_directory:
            return
        self._process_event(event.src_path)

    def on_moved(self, event):
        if event.is_directory:
            return
        self._process_event(event.dest_path)

    def _process_event(self, filepath):
        # Strict filtering
        # 1. Check extensions
        if not any(filepath.lower().endswith(ext) for ext in ['.mkv', '.mp4', '.avi', '.mov']):
            return

        # 2. Check strict paths (must be in /media/filmes or /media/series)
        # Assuming container has /media mounted as ROOT
        # Normalize path
        abs_path = os.path.abspath(filepath)
        
        is_filmes = "/media/filmes" in abs_path
        is_series = "/media/series" in abs_path
        
        if not (is_filmes or is_series):
            # logger.debug(f"Ignored file outside target dirs: {filepath}")
            return
            
        # 3. Ignore cache/downloads explicitly just in case they are nested (though they shouldn't be based on plan)
        parts = filepath.split(os.sep)
        if "downloads" in parts or "cache" in parts or ".temp." in filepath:
            return

        logger.info(f"File detected: {filepath}. Waiting {self.debounce_interval}s to stabilize...")
        
        if filepath in self.timers:
            self.timers[filepath].cancel()
        
        timer = Timer(self.debounce_interval, self._trigger_queue, [filepath])
        self.timers[filepath] = timer
        timer.start()

    def _trigger_queue(self, filepath):
        if filepath in self.timers:
            del self.timers[filepath]
        
        if os.path.exists(filepath):
            logger.info(f"File stabilized: {filepath}. Queueing for processing.")
            self.job_queue.put(filepath)
        else:
            logger.warning(f"File {filepath} disappeared before processing.")

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
