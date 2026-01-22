import time
import logging
import os
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from threading import Timer

logger = logging.getLogger(__name__)

class MediaEventHandler(FileSystemEventHandler):
    def __init__(self, pipeline, debounce_interval=60):
        self.pipeline = pipeline
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
        # Filter logic
        if "downloads" in filepath.split(os.sep):
            return
        
        if not any(filepath.lower().endswith(ext) for ext in ['.mkv', '.mp4', '.avi', '.mov']):
            return

        logger.info(f"File detected: {filepath}. Waiting {self.debounce_interval}s to stabilize...")
        
        # Debounce logic
        if filepath in self.timers:
            self.timers[filepath].cancel()
        
        timer = Timer(self.debounce_interval, self._trigger_pipeline, [filepath])
        self.timers[filepath] = timer
        timer.start()

    def _trigger_pipeline(self, filepath):
        if filepath in self.timers:
            del self.timers[filepath]
        
        if os.path.exists(filepath):
            logger.info(f"File stabilized: {filepath}. Starting pipeline.")
            self.pipeline.process_file(filepath)
        else:
            logger.warning(f"File {filepath} disappeared before processing.")

class Scanner:
    def __init__(self, pipeline, watch_dirs):
        self.pipeline = pipeline
        self.watch_dirs = watch_dirs
        self.observer = Observer()

    def start(self):
        event_handler = MediaEventHandler(self.pipeline)
        
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
