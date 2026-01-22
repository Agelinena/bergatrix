import logging
import os
import time
import threading
import queue
from core.processor import Processor
from core.scanner import Scanner

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def worker(job_queue, processor):
    while True:
        filepath = job_queue.get()
        try:
            processor.process_file(filepath)
        except Exception as e:
            logger.error(f"Error processing file {filepath}: {e}")
        finally:
            job_queue.task_done()

def main():
    logger.info("Starting Legendarr Optimizer (Parallel Edition)...")
    
    # Configuration
    max_workers = int(os.getenv('MAX_WORKERS', '2'))
    logger.info(f"Worker threads: {max_workers}")

    # Initialize Components
    processor = Processor()
    job_queue = queue.Queue()
    
    # Start Worker Threads
    for i in range(max_workers):
        t = threading.Thread(target=worker, args=(job_queue, processor), daemon=True)
        t.start()
        logger.info(f"Started worker thread #{i+1}")

    # Define directories to watch strictly
    watch_dirs = [
        "/media/filmes",
        "/media/series"
    ]
    
    # Initial Scan
    logger.info("Running initial scan (queuing files)...")
    extensions = ('.mkv', '.mp4', '.avi', '.mov')
    count = 0
    for watch_dir in watch_dirs:
        if os.path.exists(watch_dir):
            for root, dirs, files in os.walk(watch_dir):
                for file in files:
                    if file.lower().endswith(extensions) and ".temp." not in file:
                        full_path = os.path.join(root, file)
                        job_queue.put(full_path)
                        count += 1
    
    logger.info(f"Initial scan complete. {count} files queued. Starting Watchdog...")
    
    scanner = Scanner(job_queue, watch_dirs)
    scanner.start()

if __name__ == "__main__":
    main()
