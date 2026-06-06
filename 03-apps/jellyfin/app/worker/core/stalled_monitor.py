"""
Monitor de downloads travados (stalled).

Vigia a fila do Radarr/Sonarr e, quando um download fica "stalled" (travado, ex.:
sem conexões por bloqueio de firewall/VPN) por mais de STALLED_TIMEOUT, remove-o
do download client, blocklista o release e dispara nova busca — fazendo o Arr
pegar OUTRO release automaticamente.

Usa a API do Radarr/Sonarr (não precisa das credenciais do qBittorrent):
  GET    /api/v3/queue
  DELETE /api/v3/queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=false
"""

import os
import time
import logging
from threading import Thread
from . import arr

logger = logging.getLogger(__name__)

STALLED_TIMEOUT = int(os.environ.get("STALLED_TIMEOUT_MINUTES", "5")) * 60
CHECK_INTERVAL = int(os.environ.get("STALLED_CHECK_INTERVAL", "60"))


class StalledMonitor:
    def __init__(self):
        # {downloadId: epoch em que foi visto 'stalled' pela primeira vez}
        self._first_seen: dict = {}

    def start(self):
        if not (arr.radarr_enabled() or arr.sonarr_enabled()):
            logger.info("StalledMonitor: RADARR/SONARR_API_KEY não configuradas — desativado.")
            return
        Thread(target=self._loop, daemon=True).start()
        logger.info(
            f"StalledMonitor iniciado — remove downloads stalled após {STALLED_TIMEOUT // 60}min "
            f"(checa a cada {CHECK_INTERVAL}s)."
        )

    def _loop(self):
        while True:
            try:
                self._check()
            except Exception as e:
                logger.error(f"StalledMonitor: erro no loop: {e}")
            time.sleep(CHECK_INTERVAL)

    @staticmethod
    def _is_stalled(item: dict) -> bool:
        if (item.get("trackedDownloadStatus") or "").lower() != "warning":
            return False
        blob = (item.get("errorMessage") or "").lower()
        for sm in item.get("statusMessages") or []:
            blob += " " + (sm.get("title") or "").lower()
            blob += " " + " ".join(sm.get("messages") or []).lower()
        return "stalled" in blob

    def _check(self):
        now = time.time()
        active = set()
        sources = []
        if arr.radarr_enabled():
            sources.append(("Radarr", arr.radarr_queue, arr.radarr_remove_queue))
        if arr.sonarr_enabled():
            sources.append(("Sonarr", arr.sonarr_queue, arr.sonarr_remove_queue))

        for label, get_queue, remove in sources:
            for item in get_queue():
                if not self._is_stalled(item):
                    continue
                dlid = item.get("downloadId") or f"{label}:{item.get('id')}"
                active.add(dlid)
                first = self._first_seen.setdefault(dlid, now)
                elapsed = now - first
                if elapsed >= STALLED_TIMEOUT:
                    title = item.get("title", "?")
                    logger.warning(
                        f"{label}: '{title}' travado (stalled) há {elapsed / 60:.0f}min — "
                        f"removendo, blocklistando e rebaixando outro release."
                    )
                    if remove(item.get("id"), blocklist=True):
                        self._first_seen.pop(dlid, None)
                else:
                    logger.info(
                        f"{label}: '{item.get('title', '?')}' stalled há {elapsed / 60:.0f}min "
                        f"(remove em {(STALLED_TIMEOUT - elapsed) / 60:.0f}min se persistir)."
                    )

        # Esquece os que voltaram a baixar / saíram da fila
        for dlid in list(self._first_seen):
            if dlid not in active:
                self._first_seen.pop(dlid, None)
