"""
Monitor de downloads travados (stalled).

Vigia a fila do Radarr/Sonarr e age em dois casos:
  • download FALHOU (status failed / erro de unpack-import / Usenet sem artigos):
    remove na hora, blocklista o release e rebaixa outro;
  • download TRAVADO ("stalled", ex.: sem conexões por firewall/VPN) por mais de
    STALLED_TIMEOUT: remove, blocklista e dispara nova busca.
Em ambos, o Arr pega OUTRO release automaticamente.

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
    def _classify(item: dict) -> str | None:
        """Classifica um item da fila: 'failed' (remover já), 'stalled' (remover
        após o timeout) ou None (saudável). Cobre torrents travados e também
        downloads que falharam de vez (Usenet sem artigos, unpack/import com erro)."""
        status = (item.get("status") or "").lower()
        tds = (item.get("trackedDownloadStatus") or "").lower()
        state = (item.get("trackedDownloadState") or "").lower()

        # Mensagens (errorMessage + statusMessages) consolidadas p/ busca textual.
        blob = (item.get("errorMessage") or "").lower()
        for sm in item.get("statusMessages") or []:
            blob += " " + (sm.get("title") or "").lower()
            blob += " " + " ".join(sm.get("messages") or []).lower()

        # 1) Falha definitiva → remover/blocklistar imediatamente (não adianta esperar).
        if status == "failed" or tds == "error" or state in ("failedpending", "failed"):
            return "failed"

        # 2) Download concluído, preso/aguardando no IMPORT (não é problema do release):
        #    NÃO rebaixar — evita apagar um download bom por erro de importação.
        if state in ("importpending", "importblocked", "importing", "imported"):
            return None

        # 3) Travado (sem conexões/seeds, firewall, etc.) → só remove se persistir.
        #    A versão do Arr pode pôr o aviso em 'status' OU em 'trackedDownloadStatus',
        #    e às vezes o texto "stalled" nem vem na API (é a UI que monta a frase).
        #    Por isso cobrimos os dois caminhos: sinal textual OU warning enquanto baixa.
        if any(w in blob for w in ("stalled", "no connections", "no peers")):
            return "stalled"
        if status == "warning" or tds == "warning":
            return "stalled"
        return None

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
                kind = self._classify(item)
                if not kind:
                    continue
                dlid = item.get("downloadId") or f"{label}:{item.get('id')}"
                title = item.get("title", "?")

                # Falha definitiva → age na hora, sem esperar o timeout.
                if kind == "failed":
                    logger.warning(
                        f"{label}: '{title}' com FALHA de download — removendo, "
                        f"blocklistando e rebaixando outro release."
                    )
                    if remove(item.get("id"), blocklist=True):
                        self._first_seen.pop(dlid, None)
                    continue

                # Stalled → só remove depois de STALLED_TIMEOUT persistindo.
                active.add(dlid)
                first = self._first_seen.setdefault(dlid, now)
                elapsed = now - first
                if elapsed >= STALLED_TIMEOUT:
                    logger.warning(
                        f"{label}: '{title}' travado (stalled) há {elapsed / 60:.0f}min — "
                        f"removendo, blocklistando e rebaixando outro release."
                    )
                    if remove(item.get("id"), blocklist=True):
                        self._first_seen.pop(dlid, None)
                else:
                    logger.info(
                        f"{label}: '{title}' stalled há {elapsed / 60:.0f}min "
                        f"(remove em {(STALLED_TIMEOUT - elapsed) / 60:.0f}min se persistir)."
                    )

        # Esquece os que voltaram a baixar / saíram da fila
        for dlid in list(self._first_seen):
            if dlid not in active:
                self._first_seen.pop(dlid, None)
