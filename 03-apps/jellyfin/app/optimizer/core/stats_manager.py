import json
import os
import threading
import logging

logger = logging.getLogger(__name__)

STATS_FILE = "/app/stats/stats.json"

class StatsManager:
    def __init__(self):
        self.lock = threading.Lock()
        self._ensure_stats_file()

    def _ensure_stats_file(self):
        if not os.path.exists(os.path.dirname(STATS_FILE)):
            os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
        
        if not os.path.exists(STATS_FILE):
             with open(STATS_FILE, 'w') as f:
                 json.dump({}, f)

    def update_stat(self, filepath, original_size, optimized_size):
        with self.lock:
            try:
                data = self._load_data()
                
                saved_bytes = original_size - optimized_size
                # Use relative path as key to keep it clean if possible, or full path
                # Let's use standard full path for uniqueness but maybe strip /media prefix for display?
                # User asked for per-file stats.
                
                data[filepath] = {
                    "original_size": original_size,
                    "optimized_size": optimized_size,
                    "saved_bytes": saved_bytes,
                    "timestamp": int(os.path.getmtime(STATS_FILE)) # Approximate
                }
                
                self._save_data(data)
                logger.info(f"Stats updated for {filepath}. Saved: {saved_bytes / (1024**3):.2f} GB")
                return True
            except Exception as e:
                logger.error(f"Failed to update stats: {e}")
                return False

    def get_stats(self):
        with self.lock:
            return self._load_data()

    def _load_data(self):
        try:
            if os.path.exists(STATS_FILE):
                with open(STATS_FILE, 'r') as f:
                    return json.load(f)
        except json.JSONDecodeError:
            return {}
        return {}

    def _save_data(self, data):
        with open(STATS_FILE, 'w') as f:
            json.dump(data, f, indent=4)
