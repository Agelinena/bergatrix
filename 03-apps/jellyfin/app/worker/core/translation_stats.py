import json
import os
import threading
import logging
from datetime import datetime

logger = logging.getLogger(__name__)

TRANSLATION_STATS_FILE = "/app/stats/translation_stats.json"


class TranslationStats:
    """Persiste o histórico de traduções realizadas pelo worker."""

    def __init__(self):
        self.lock = threading.Lock()
        self._ensure_file()

    def _ensure_file(self):
        os.makedirs(os.path.dirname(TRANSLATION_STATS_FILE), exist_ok=True)
        if not os.path.exists(TRANSLATION_STATS_FILE):
            with open(TRANSLATION_STATS_FILE, "w") as f:
                json.dump([], f)

    def record(
        self,
        filepath: str,
        status: str,
        source_lang: str = "unknown",
        source_codec: str = "unknown",
        stream_index: int | None = None,
        model: str = "unknown",
    ):
        """Registra uma tradução (bem-sucedida ou falha).

        Mantém apenas a entrada MAIS RECENTE por arquivo. Antes o histórico crescia
        sem limite (chegou a 3 MB / ~7,8 mil entradas, com cada arquivo repetido 100+
        vezes por causa do cooldown quebrado), e o arquivo inteiro era reescrito a
        cada registro. Deduplicar por filepath limita o tamanho ao nº de arquivos
        da biblioteca.
        """
        with self.lock:
            data = self._load()
            # Conta falhas consecutivas do mesmo arquivo (cooldown progressivo:
            # revisita rápido nas primeiras N falhas e só depois recua para dias).
            prev = next((e for e in data if e.get("filepath") == filepath), None)
            prev_attempts = prev.get("attempts", 0) if prev else 0
            attempts = (prev_attempts + 1) if status == "failed" else 0
            # Remove registros antigos do mesmo arquivo (mantém só o estado atual)
            data = [e for e in data if e.get("filepath") != filepath]
            entry = {
                "filepath": filepath,
                "filename": os.path.basename(filepath),
                "status": status,          # "success" | "failed" | "skipped" | ...
                "attempts": attempts,
                "source_lang": source_lang,
                "source_codec": source_codec,
                "stream_index": stream_index,
                "model": model,
                "timestamp": datetime.now().isoformat(),
            }
            data.append(entry)
            self._save(data)
            logger.info(f"Stats de tradução registradas para {entry['filename']} [{status}]")

    def clear(self, filepath: str):
        """Remove o registro de um arquivo — ele volta a ser elegível para
        reprocessamento (sai de 'resolved'/cooldown). Usado pela auditoria de
        legendas ao descartar uma tradução incompleta."""
        with self.lock:
            data = self._load()
            new = [e for e in data if e.get("filepath") != filepath]
            if len(new) != len(data):
                self._save(new)
                logger.info(f"Stats: registro removido para {os.path.basename(filepath)} (reprocessar).")

    def get_all(self) -> list:
        with self.lock:
            return self._load()

    def get_summary(self) -> dict:
        with self.lock:
            data = self._load()
            total = len(data)
            success = sum(1 for e in data if e.get("status") == "success")
            failed = sum(1 for e in data if e.get("status") == "failed")
            last_entry = data[-1] if data else None
            return {
                "total": total,
                "success": success,
                "failed": failed,
                "last": last_entry,
            }

    def _load(self) -> list:
        try:
            if os.path.exists(TRANSLATION_STATS_FILE):
                with open(TRANSLATION_STATS_FILE, "r") as f:
                    return json.load(f)
        except (json.JSONDecodeError, IOError):
            return []
        return []

    def _save(self, data: list):
        with open(TRANSLATION_STATS_FILE, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
