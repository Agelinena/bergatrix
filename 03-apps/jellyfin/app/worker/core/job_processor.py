import os
import json
import time
import logging
from threading import Thread

logger = logging.getLogger(__name__)


class JobProcessor:
    """
    Processa jobs de tradução criados pela interface web.
    Faz polling a cada 5s no diretório de jobs.
    """

    def __init__(self, pipeline, jobs_dir: str = "/app/jobs"):
        self.pipeline = pipeline
        self.jobs_dir = jobs_dir
        self.running = False

    def start(self):
        self.running = True
        thread = Thread(target=self._loop, daemon=True)
        thread.start()
        logger.info(f"JobProcessor iniciado — monitorando {self.jobs_dir}")

    def _loop(self):
        while self.running:
            try:
                if os.path.exists(self.jobs_dir):
                    for filename in sorted(os.listdir(self.jobs_dir)):
                        if filename.endswith(".json"):
                            self._process_job(os.path.join(self.jobs_dir, filename))
            except Exception as e:
                logger.error(f"Erro no loop do JobProcessor: {e}")
            time.sleep(5)

    def _process_job(self, job_filepath: str):
        try:
            with open(job_filepath, "r") as f:
                job = json.load(f)

            job_id = job.get("id", "?")
            job_type = job.get("type", "?")
            target_file = job.get("filepath", "")
            force = job.get("force", False)
            stream_index = job.get("stream_index")  # pode ser None (auto) ou int

            logger.info(
                f"Processando job {job_id}: type={job_type} | "
                f"file={os.path.basename(target_file)} | "
                f"force={force} | stream_index={stream_index}"
            )

            if job_type == "translate":
                self.pipeline.process_file(
                    target_file,
                    force=force,
                    stream_index=stream_index,
                )
            elif job_type == "scan":
                logger.info("Executando varredura manual da biblioteca...")
                from core.scanner import _has_subtitle, MEDIA_EXTENSIONS
                watch_dirs = ["/media/filmes", "/media/series"]
                import os as _os
                count = 0
                for d in watch_dirs:
                    if not _os.path.exists(d):
                        continue
                    for root, _, files in _os.walk(d):
                        for fname in files:
                            if not fname.lower().endswith(MEDIA_EXTENSIONS):
                                continue
                            if ".temp." in fname:
                                continue
                            fp = _os.path.join(root, fname)
                            if not _has_subtitle(fp):
                                self.pipeline.process_file(fp)
                                count += 1
                logger.info(f"Varredura manual concluída: {count} arquivos sem legenda processados.")
            else:
                logger.warning(f"Tipo de job desconhecido '{job_type}' — ignorado.")


            # Job concluído: remove o arquivo
            os.remove(job_filepath)
            logger.info(f"Job {job_id} concluído.")

        except Exception as e:
            logger.error(f"Falha ao processar job {job_filepath}: {e}")
            # Deletar para evitar loop infinito
            try:
                os.remove(job_filepath)
            except Exception:
                pass
