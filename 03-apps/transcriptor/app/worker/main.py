"""Worker do Transcriptor: pega jobs da fila no Postgres e transcreve na GPU.

Ao subir: devolve à fila o que estava rodando quando caiu, baixa e confere
os modelos do catálogo e faz uma transcrição de teste. Só depois disso
começa a pegar jobs. O estado (GPU, modelos, modelo carregado) vai para a
tabela workers, que a interface mostra aos administradores.

Rodar: python -m app.worker.main
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from uuid import UUID

import asyncpg

from app import db
from app import jobs as repo
from app.catalog import CATALOG, available
from app.config import settings
from app.worker import media, models
from app.worker.engine import Engine, OutOfMemory, gpu_info

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("transcriptor.worker")

POLL_SECONDS = 5
JOB_HEARTBEAT_SECONDS = 20
HOUSEKEEPING_SECONDS = 600
HEALTH_FILE = Path("/tmp/healthy")
GENERIC_ERROR = "Falha inesperada no processamento. Tente de novo."


class Worker:
    def __init__(self):
        self.name = settings.worker_name
        self.engine = Engine()
        self.pool = None
        self.wake = asyncio.Event()
        self.stopping = False
        self.detail: dict = {"models": {}, "gpu": {}}
        self.model_paths: dict[str, Path] = {}

    # ── Estado ───────────────────────────────────────────────────────

    async def report(self, state: str, **detail) -> None:
        self.detail.update(detail)
        self.detail["loaded_model"] = self.engine.spec.id if self.engine.spec else None
        await self.pool.execute(
            """INSERT INTO workers (name, state, detail) VALUES ($1, $2, $3)
               ON CONFLICT (name) DO UPDATE SET state = $2, detail = $3, heartbeat_at = now()""",
            self.name, state, self.detail)
        HEALTH_FILE.touch()

    # ── Subida ───────────────────────────────────────────────────────

    async def prepare_models(self) -> None:
        for spec in available(settings.enabled_models):
            self.detail["models"][spec.id] = "baixando" if not models.is_ready(spec) else "conferindo"
            await self.report("preparing")
            try:
                self.model_paths[spec.id] = await asyncio.to_thread(models.ensure, spec)
                self.detail["models"][spec.id] = "ok"
            except Exception as error:
                logger.error("[worker] modelo %s indisponível: %s", spec.id, error)
                self.detail["models"][spec.id] = f"erro: {str(error)[:160]}"
        await self.report("preparing")

    async def warmup(self) -> None:
        spec = CATALOG.get(settings.default_model)
        if spec is None or spec.id not in self.model_paths:
            spec = next((CATALOG[i] for i in self.model_paths), None)
        if spec is None:
            raise RuntimeError("nenhum modelo disponível")
        sample = Path("/tmp/warmup.wav")
        await asyncio.to_thread(subprocess.run, [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-ac", "1", "-ar", "16000", str(sample)], check=True)
        await asyncio.to_thread(self.engine.warmup, spec, self.model_paths[spec.id], sample)
        sample.unlink(missing_ok=True)

    async def listen(self) -> None:
        while not self.stopping:
            connection = None
            try:
                connection = await asyncpg.connect(settings.database_url)
                await connection.add_listener("transcriptor_queue", lambda *args: self.wake.set())
                while not self.stopping:
                    await asyncio.sleep(15)
                    await connection.execute("SELECT 1")
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning("[worker] aviso da fila caiu (%s); reconectando", error)
                await asyncio.sleep(3)
            finally:
                if connection is not None and not connection.is_closed():
                    await connection.close()

    # ── Laço principal ───────────────────────────────────────────────

    async def run(self) -> None:
        self.pool = await db.create_pool(max_size=4)
        Path(settings.work_dir).mkdir(parents=True, exist_ok=True)
        self.detail["gpu"] = await asyncio.to_thread(gpu_info)
        await self.report("starting")
        # O que este worker rodava quando caiu volta para a fila.
        await self.pool.execute(
            """UPDATE jobs SET status = 'queued', progress = 0 WHERE worker = $1 AND status = ANY($2::text[])""",
            self.name, list(repo.ACTIVE))
        await self.prepare_models()
        try:
            await self.warmup()
        except Exception as error:
            logger.exception("[worker] teste da GPU falhou")
            await self.report("error", error=f"teste da GPU falhou: {str(error)[:300]}")
            raise
        self.detail.pop("error", None)
        await self.report("ready")
        listener = asyncio.create_task(self.listen())
        housekeeping = asyncio.create_task(self.housekeeping())
        try:
            while not self.stopping:
                job = await repo.claim(self.pool, self.name)
                if job is None:
                    self.engine.unload_if_idle(settings.idle_unload_minutes * 60)
                    await self.report("ready")
                    self.wake.clear()
                    try:
                        await asyncio.wait_for(self.wake.wait(), POLL_SECONDS)
                    except asyncio.TimeoutError:
                        pass
                    continue
                await self.report("busy", job=str(job["id"]))
                await self.process(job)
                self.detail.pop("job", None)
        finally:
            listener.cancel()
            housekeeping.cancel()
            await db.close_pool()

    async def process(self, job) -> None:
        job_id: UUID = job["id"]
        directory = repo.work_dir(job_id)
        directory.mkdir(parents=True, exist_ok=True)
        cancel = asyncio.Event()
        heartbeat = asyncio.create_task(self.job_heartbeat(job_id, cancel))
        loop = asyncio.get_running_loop()
        wav = None
        try:
            max_seconds = settings.max_duration_minutes * 60
            if job["source_kind"] == "url":
                progress = {"value": 0.0}
                pusher = asyncio.create_task(self.push_download_progress(job_id, progress, cancel))
                try:
                    source, title = await asyncio.to_thread(
                        media.download, job["source_url"], directory, max_bytes=settings.max_upload_bytes,
                        max_seconds=max_seconds, proxy=settings.egress_proxy,
                        on_progress=lambda value: progress.__setitem__("value", value), canceled=cancel.is_set)
                finally:
                    pusher.cancel()
                fields = {"status": "preparing", "progress": 0.0}
                if title and job["title"] == (job["source_url"] or "")[:200]:
                    fields["title"] = title
                await repo.update(self.pool, job_id, **fields)
            else:
                source = repo.upload_path(job_id)
                if not source.exists():
                    raise media.MediaError("O arquivo enviado não está mais no servidor. Envie de novo.")
                await repo.update(self.pool, job_id, status="preparing")
            probe = await asyncio.to_thread(media.probe, source, max_seconds)
            wav, playback = await asyncio.to_thread(media.prepare, source, directory)
            if job["source_kind"] == "url":
                source.unlink(missing_ok=True)
            if not await repo.update(self.pool, job_id, status="transcribing", progress=0.0,
                                     duration_seconds=probe.duration, has_audio=playback.exists()):
                raise media.Canceled()

            spec = CATALOG[job["model"]]
            path = self.model_paths.get(spec.id)
            if path is None:
                raise media.MediaError(f"O modelo {spec.label} não está disponível no servidor agora.")
            await self.report("busy", job=str(job_id))
            result = await self.transcribe(job, spec, path, wav, cancel, loop)
            if cancel.is_set():
                raise media.Canceled()
            await repo.update(self.pool, job_id, detected_language=result.language)
            await repo.finish(self.pool, job_id, "done")
            # Transcrição pronta: o arquivo original não é mais necessário.
            repo.upload_path(job_id).unlink(missing_ok=True)
            logger.info("[worker] %s pronto (%s, %.0f s de áudio)", job_id, spec.id, result.duration)
        except media.Canceled:
            await repo.finish(self.pool, job_id, "canceled")
        except media.MediaError as error:
            await repo.finish(self.pool, job_id, "failed", str(error))
        except OutOfMemory:
            await repo.finish(self.pool, job_id, "failed",
                              "A GPU ficou sem memória (outro serviço pode estar usando). Tente de novo ou use o modelo Rápido.")
        except Exception:
            logger.exception("[worker] %s falhou", job_id)
            await repo.finish(self.pool, job_id, "failed", GENERIC_ERROR)
        finally:
            heartbeat.cancel()
            if wav is not None:
                wav.unlink(missing_ok=True)

    async def transcribe(self, job, spec, path, wav, cancel, loop):
        job_id = job["id"]
        batch_size = spec.batch_size
        while True:
            def emit(segments, progress):
                if cancel.is_set():
                    return False
                future = asyncio.run_coroutine_threadsafe(self.save(job_id, segments, progress), loop)
                if not future.result():
                    cancel.set()
                    return False
                return True

            try:
                return await asyncio.to_thread(
                    self.engine.transcribe, wav, spec, path, language=job["language"], prompt=job["prompt"],
                    batch_size=batch_size, emit=emit)
            except OutOfMemory:
                # Recomeça do zero com metade do lote.
                await self.pool.execute("DELETE FROM segments WHERE job_id = $1", job_id)
                self.engine.unload()
                if batch_size <= 1:
                    raise
                batch_size //= 2
                logger.warning("[worker] sem memória na GPU; tentando com lote %d", batch_size)

    async def push_download_progress(self, job_id, progress: dict, cancel: asyncio.Event) -> None:
        last = -1.0
        while True:
            await asyncio.sleep(2)
            if progress["value"] != last:
                last = progress["value"]
                if not await repo.update(self.pool, job_id, progress=round(last, 3)):
                    cancel.set()

    async def save(self, job_id, segments, progress) -> bool:
        await repo.add_segments(self.pool, job_id, segments)
        return await repo.update(self.pool, job_id, progress=round(progress, 3))

    async def job_heartbeat(self, job_id, cancel: asyncio.Event) -> None:
        while True:
            await asyncio.sleep(JOB_HEARTBEAT_SECONDS)
            if not await repo.update(self.pool, job_id):
                cancel.set()
            await self.report("busy", job=str(job_id))

    # ── Limpeza ──────────────────────────────────────────────────────

    async def housekeeping(self) -> None:
        while True:
            try:
                await self.clean()
            except Exception:
                logger.exception("[worker] limpeza falhou")
            await asyncio.sleep(HOUSEKEEPING_SECONDS)

    async def clean(self) -> None:
        pool = self.pool
        await repo.requeue_stale(pool)
        if settings.retention_days > 0:
            for row in await pool.fetch(
                    """DELETE FROM jobs WHERE created_at < now() - make_interval(days => $1)
                       AND status = ANY($2::text[]) RETURNING id""",
                    settings.retention_days, list(repo.FINISHED)):
                repo.remove_work(row["id"])
        for row in await pool.fetch(
                """UPDATE jobs SET has_audio = false WHERE has_audio
                   AND finished_at < now() - make_interval(days => $1) RETURNING id""", settings.audio_days):
            repo.playback_path(row["id"]).unlink(missing_ok=True)
        # Original de transcrição que falhou: guardado 3 dias para "tentar de novo".
        for row in await pool.fetch(
                """SELECT id FROM jobs WHERE status IN ('failed', 'canceled')
                   AND finished_at < now() - interval '3 days'"""):
            repo.upload_path(row["id"]).unlink(missing_ok=True)
        for row in await pool.fetch(
                "DELETE FROM jobs WHERE status = 'uploading' AND created_at < now() - interval '1 day' RETURNING id"):
            repo.remove_work(row["id"])
        await pool.execute("DELETE FROM sessions WHERE expires_at < now()")
        await pool.execute("DELETE FROM login_states WHERE created_at < now() - interval '1 hour'")
        known = {str(r["id"]) for r in await pool.fetch("SELECT id FROM jobs")}
        for entry in Path(settings.work_dir).iterdir():
            if entry.name not in known and time.time() - entry.stat().st_mtime > 3600:
                shutil.rmtree(entry, ignore_errors=True) if entry.is_dir() else entry.unlink(missing_ok=True)


def main() -> None:
    worker = Worker()

    def stop(*_):
        worker.stopping = True
        worker.wake.set()

    signal.signal(signal.SIGTERM, stop)
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    asyncio.run(worker.run())


if __name__ == "__main__":
    main()
