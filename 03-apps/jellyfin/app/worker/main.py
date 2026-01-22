import os
import logging
from dotenv import load_dotenv
from core.pipeline import Pipeline
from core.scanner import Scanner

# Load environment variables
load_dotenv()

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def main():
    logger.info("Starting Legendarr Worker...")
    
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        logger.error("GEMINI_API_KEY not found in environment variables.")
        return

    pipeline = Pipeline(api_key)
    
    # Watch directories
    watch_dirs = [
        "/media/filmes",
        "/media/series"
    ]
    
    scanner = Scanner(pipeline, watch_dirs)
    
    # Start Job Processor
    from core.job_processor import JobProcessor
    job_processor = JobProcessor(pipeline)
    job_processor.start()

    scanner.start()

if __name__ == "__main__":
    main()
