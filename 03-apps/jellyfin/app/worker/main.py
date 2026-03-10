import logging
from dotenv import load_dotenv
from core.pipeline import Pipeline
from core.scanner import Scanner

# Load environment variables
load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def main():
    logger.info("Iniciando Legendarr Worker...")

    # Pipeline inicializa o Translator internamente (lê OPENROUTER_API_KEY do env)
    pipeline = Pipeline()

    # Diretórios a monitorar
    watch_dirs = [
        "/media/filmes",
        "/media/series"
    ]

    scanner = Scanner(pipeline, watch_dirs)

    # Job Processor: processa jobs criados pela interface web
    from core.job_processor import JobProcessor
    job_processor = JobProcessor(pipeline)
    job_processor.start()

    scanner.start()


if __name__ == "__main__":
    main()
