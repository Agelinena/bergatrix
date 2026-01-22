import os
import json
import time
import logging
from threading import Thread

logger = logging.getLogger(__name__)

class JobProcessor:
    def __init__(self, pipeline, jobs_dir="/app/jobs"):
        self.pipeline = pipeline
        self.jobs_dir = jobs_dir
        self.running = False

    def start(self):
        self.running = True
        thread = Thread(target=self._loop)
        thread.daemon = True
        thread.start()
        logger.info(f"JobProcessor started, watching {self.jobs_dir}")

    def _loop(self):
        while self.running:
            try:
                if os.path.exists(self.jobs_dir):
                    for filename in os.listdir(self.jobs_dir):
                        if filename.endswith(".json"):
                            filepath = os.path.join(self.jobs_dir, filename)
                            self._process_job(filepath)
            except Exception as e:
                logger.error(f"Error in JobProcessor loop: {e}")
            
            time.sleep(5)

    def _process_job(self, job_filepath):
        try:
            with open(job_filepath, 'r') as f:
                job = json.load(f)
            
            logger.info(f"Processing job {job['id']}: {job['type']} for {job['filepath']}")
            
            target_file = job['filepath']
            
            if job['type'] == 'translate':
                # Force translation logic
                force = job.get('force', False)
                self.pipeline.process_file(target_file, force=force)
                
            elif job['type'] == 'transcribe':
                # Transcription is disabled
                logger.warning(f"Transcription job ignored for {target_file}")

            # Clean up job file
            os.remove(job_filepath)
            logger.info(f"Job {job['id']} completed.")

        except Exception as e:
            logger.error(f"Failed to process job {job_filepath}: {e}")
            # Move to failed? Or just delete to avoid loop?
            # For now, delete to avoid infinite loop
            try:
                os.remove(job_filepath)
            except:
                pass
