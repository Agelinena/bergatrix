"""
Fila de tradução por IA (serializada — 1 modelo por vez na GPU).

As buscas via Bazarr continuam correndo livres no fluxo (scanner/webhook). Quando o
Bazarr NÃO encontra a legenda, a tradução via IA é ENFILEIRADA aqui e processada por
um único worker. Assim:
  • nunca roda mais de uma tradução por vez (não estoura a VRAM da GPU);
  • o Bazarr de outros itens não fica preso atrás da tradução em andamento
    (o scanner segue buscando enquanto o worker traduz o item anterior).
"""

import os
import queue
import logging
import threading
from threading import Thread

logger = logging.getLogger(__name__)


class TranslationQueue:
    def __init__(self, pipeline):
        self.pipeline = pipeline
        self._q: "queue.Queue[dict]" = queue.Queue()
        self._pending: set[str] = set()   # filepaths na fila OU em tradução (dedup)
        self._lock = threading.Lock()
        self._started = False

    def start(self):
        if self._started:
            return
        self._started = True
        Thread(target=self._worker, daemon=True).start()
        logger.info("Fila de tradução por IA iniciada (1 tradução por vez na GPU).")

    def enqueue(self, filepath: str, stream_index: int | None = None, force: bool = False) -> bool:
        """Adiciona um arquivo à fila. Ignora duplicados (já na fila ou traduzindo)."""
        with self._lock:
            if filepath in self._pending:
                logger.info(f"IA: '{os.path.basename(filepath)}' já está na fila — ignorando duplicado.")
                return False
            self._pending.add(filepath)
        self._q.put({"filepath": filepath, "stream_index": stream_index, "force": force})
        logger.info(
            f"IA: enfileirado para tradução ({self._q.qsize()} na fila): {os.path.basename(filepath)}"
        )
        return True

    def pending_count(self) -> int:
        return self._q.qsize()

    def _worker(self):
        while True:
            item = self._q.get()
            fp = item["filepath"]
            try:
                self.pipeline._do_ai_translation(
                    fp, stream_index=item.get("stream_index"), force=item.get("force", False)
                )
            except Exception as e:
                logger.error(f"Fila de tradução: erro ao traduzir {os.path.basename(fp)}: {e}")
            finally:
                with self._lock:
                    self._pending.discard(fp)
                self._q.task_done()
