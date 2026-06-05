import logging
import time
import httpx
import os
from logging.handlers import RotatingFileHandler
from dotenv import load_dotenv
from core.pipeline import Pipeline
from core.scanner import Scanner

# Load environment variables
load_dotenv()

_LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'
logging.basicConfig(level=logging.INFO, format=_LOG_FORMAT)

# Além do stdout, grava os logs em arquivo no volume compartilhado (/app/stats),
# para a interface web exibi-los. Rotaciona em ~1MB (mantém 2 backups) p/ não crescer.
_LOG_FILE = "/app/stats/worker.log"
try:
    os.makedirs(os.path.dirname(_LOG_FILE), exist_ok=True)
    _file_handler = RotatingFileHandler(_LOG_FILE, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    _file_handler.setFormatter(logging.Formatter(_LOG_FORMAT))
    logging.getLogger().addHandler(_file_handler)
except Exception as _e:
    logging.warning(f"Não foi possível configurar log em arquivo ({_LOG_FILE}): {_e}")

logger = logging.getLogger(__name__)

def wait_for_bazarr():
    bazarr_url = os.environ.get("BAZARR_URL", "http://bazarr:6767")
    api_key = os.environ.get("BAZARR_API_KEY", "")
    if not api_key:
        return
        
    logger.info("Aguardando o Bazarr iniciar e ficar pronto...")
    for _ in range(30):
        try:
            with httpx.Client(timeout=5) as c:
                r = c.get(f"{bazarr_url}/api/system/status", headers={"X-Api-Key": api_key})
                if r.status_code == 200:
                    logger.info("Bazarr está online e responsivo!")
                    return
        except Exception:
            pass
        time.sleep(10)
    logger.warning("Tempo limite esgotado aguardando o Bazarr. O sistema pode falhar integrações.")

def main():
    logger.info("Iniciando Legendarr Worker...")
    wait_for_bazarr()

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
