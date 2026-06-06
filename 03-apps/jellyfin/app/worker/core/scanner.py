import time
import logging
import os
import json
from datetime import datetime
from .utils import has_pt_subtitle

logger = logging.getLogger(__name__)

MEDIA_EXTENSIONS = ('.mkv', '.mp4', '.avi', '.mov')
# Intervalo de varredura periódica em segundos (padrão: 1 hora)
PERIODIC_SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "3600"))
# Cooldown progressivo: revisita falhas a cada RETRY_INTERVAL_HOURS (padrão 1h);
# após MAX_FAST_RETRIES falhas, recua para COOLDOWN_HOURS (padrão 72h / 3 dias).
RETRY_INTERVAL_SECONDS = int(os.environ.get("RETRY_INTERVAL_HOURS", "1")) * 3600
MAX_FAST_RETRIES = int(os.environ.get("MAX_FAST_RETRIES", "6"))
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_HOURS", "72")) * 3600
STATS_FILE = "/app/stats/translation_stats.json"
# Cache {filepath: mtime} dos arquivos cujo áudio já foi verificado e está OK —
# evita re-checar (ffprobe) a cada boot. Re-verifica só quando o arquivo muda.
AUDIO_VERIFIED_FILE = "/app/stats/audio_verified.json"


def _has_subtitle(filepath: str) -> bool:
    """Verifica se o arquivo já tem legenda PT-BR externa (case-insensitive, inclui .hi/.sdh/.forced)."""
    return has_pt_subtitle(filepath)


def _parse_timestamp(value) -> float:
    """
    Converte um timestamp para epoch (float).

    Aceita tanto epoch numérico quanto string ISO-8601 (ex.: "2026-03-14T19:30:22").
    Esse é o cerne do bug do cooldown: as stats gravam ISO string, mas a comparação
    antiga subtraía string de float (TypeError silencioso → cooldown nunca ativava).
    """
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value).timestamp()
        except ValueError:
            return 0.0
    return 0.0


# Status que indicam que o arquivo já foi tratado de forma definitiva → não reprocessar.
RESOLVED_STATUSES = {
    "success", "success_alass_refine", "bazarr_alass", "bazarr_raw",
    "skipped_internal", "skipped_external", "aligned",
}


def _load_stats_index() -> dict:
    """
    Lê o stats UMA vez e retorna {filepath: {"ts": epoch, "status": str}} (entrada mais recente).

    Usado tanto para o cooldown quanto para saber se o arquivo já foi resolvido — evita
    reparsear o JSON para cada arquivo da biblioteca a cada scan.
    """
    if not os.path.exists(STATS_FILE):
        return {}
    try:
        with open(STATS_FILE, "r", encoding="utf-8") as f:
            stats = json.load(f)
    except Exception as e:
        logger.warning(f"Não foi possível carregar índice de stats: {e}")
        return {}

    index: dict = {}
    for entry in stats:
        fp = entry.get("filepath")
        if not fp:
            continue
        ts = _parse_timestamp(entry.get("timestamp", 0))
        if ts >= index.get(fp, {}).get("ts", -1.0):
            index[fp] = {"ts": ts, "status": entry.get("status"), "attempts": entry.get("attempts", 0)}
    return index


def _is_on_cooldown(filepath: str, stats_index: dict | None = None) -> bool:
    """
    Cooldown progressivo: nas primeiras MAX_FAST_RETRIES falhas, revisita a cada
    RETRY_INTERVAL_SECONDS (1h). A partir daí, recua para COOLDOWN_SECONDS (3 dias).
    """
    if stats_index is None:
        stats_index = _load_stats_index()
    info = stats_index.get(filepath)
    if not info:
        return False
    elapsed = time.time() - info["ts"]
    window = COOLDOWN_SECONDS if info.get("attempts", 0) >= MAX_FAST_RETRIES else RETRY_INTERVAL_SECONDS
    return elapsed < window


def _is_resolved(filepath: str, stats_index: dict) -> bool:
    """True se o arquivo já foi tratado de forma definitiva (legenda obtida/alinhada/interna)."""
    info = stats_index.get(filepath)
    return bool(info and info.get("status") in RESOLVED_STATUSES)


def _load_audio_verified() -> dict:
    """Cache {filepath: mtime} dos arquivos cujo áudio já foi verificado e está OK."""
    if not os.path.exists(AUDIO_VERIFIED_FILE):
        return {}
    try:
        with open(AUDIO_VERIFIED_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_audio_verified(cache: dict):
    try:
        os.makedirs(os.path.dirname(AUDIO_VERIFIED_FILE), exist_ok=True)
        with open(AUDIO_VERIFIED_FILE, "w", encoding="utf-8") as f:
            json.dump(cache, f)
    except Exception as e:
        logger.warning(f"Não foi possível salvar cache de áudio verificado: {e}")

# ------------------------------------------------------------------ #
# Scanner principal                                                    #
# ------------------------------------------------------------------ #

class Scanner:
    def __init__(self, pipeline, watch_dirs: list[str]):
        self.pipeline = pipeline
        self.watch_dirs = watch_dirs

    def _run_scan(self):
        """
        Varredura completa. Para cada arquivo:
          - já resolvido (legenda obtida/alinhada/interna) → pula;
          - tem legenda PT-BR externa ainda não alinhada → processa (ALASS refina);
          - sem legenda e fora de cooldown → processa (Bazarr → IA).
        """
        logger.info(f"━━ Iniciando varredura ━━")
        count_found = 0
        count_queued = 0
        count_cooldown = 0
        count_resolved = 0

        # Lê o stats UMA vez por varredura (timestamp + status de cada arquivo)
        stats_index = _load_stats_index()

        for watch_dir in self.watch_dirs:
            if not os.path.exists(watch_dir):
                continue
            for root, _, files in os.walk(watch_dir):
                for fname in files:
                    if not fname.lower().endswith(MEDIA_EXTENSIONS):
                        continue
                    if ".temp." in fname:
                        continue
                    filepath = os.path.join(root, fname)
                    count_found += 1

                    # Já tratado de forma definitiva (inclui legendas já alinhadas) → pula
                    if _is_resolved(filepath, stats_index):
                        count_resolved += 1
                        continue

                    has_ext = _has_subtitle(filepath)
                    # Tem legenda externa não-alinhada → alinha (ALASS). Sem legenda → respeita cooldown.
                    if has_ext or not _is_on_cooldown(filepath, stats_index):
                        motivo = "alinhar legenda existente" if has_ext else "obter legenda (Bazarr/IA)"
                        logger.info(f"  Processando ({motivo}): {fname}")
                        try:
                            self.pipeline.process_file(filepath)
                            count_queued += 1
                        except Exception as e:
                            logger.error(f"  Erro ao processar {fname}: {e}")
                    else:
                        count_cooldown += 1

        logger.info(
            f"━━ Varredura concluída: {count_found} verificados, {count_queued} processados, "
            f"{count_resolved} já resolvidos, {count_cooldown} em cooldown ━━"
        )

    def _run_audio_check(self):
        """
        Varredura proativa do acervo: garante que cada filme/episódio tenha o áudio
        no idioma ORIGINAL, consultando o Radarr/Sonarr. Os que falham são deletados,
        o release é blocklistado e uma nova busca é disparada (pega OUTRO release).
        """
        from . import arr
        if not (arr.radarr_enabled() or arr.sonarr_enabled()):
            logger.info("Varredura de áudio: RADARR/SONARR_API_KEY não configuradas — pulando.")
            return

        logger.info("━━ Varredura de áudio (idioma original) ━━")
        checked = rejected = skipped = 0
        verified = _load_audio_verified()  # {filepath: mtime}

        def _process(path: str, event: dict):
            nonlocal checked, rejected, skipped
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                return
            # Já verificado e o arquivo não mudou → não re-checa (não mexe mais)
            if verified.get(path) == mtime:
                skipped += 1
                return
            checked += 1
            try:
                ok = self.pipeline.validate_audio(path, event)
            except Exception as e:
                logger.error(f"Erro na validação de áudio de {os.path.basename(path)}: {e}")
                return
            if ok and os.path.exists(path):
                verified[path] = mtime           # marca como OK — não mexe até o arquivo mudar
            elif not ok:
                rejected += 1
                verified.pop(path, None)          # rejeitado/deletado: sai do cache

        # Filmes (Radarr)
        if arr.radarr_enabled():
            for m in arr.list_movies():
                mf = m.get("movieFile") or {}
                path = mf.get("path")
                if not path or not os.path.exists(path):
                    continue
                _process(path, {
                    "movie": {"id": m.get("id"), "originalLanguage": m.get("originalLanguage"),
                              "tags": m.get("tags") or [], "runtime": m.get("runtime"),
                              "_tags_reliable": True},
                    "movieFile": {"id": mf.get("id")},
                    "downloadId": None,
                })

        # Séries/episódios (Sonarr)
        if arr.sonarr_enabled():
            for s in arr.list_series():
                ol = s.get("originalLanguage")
                s_runtime = s.get("runtime")
                for ef in arr.list_series_episode_files(s.get("id")):
                    path = ef["path"]
                    if not os.path.exists(path):
                        continue
                    _process(path, {
                        "series": {"id": s.get("id"), "originalLanguage": ol,
                                   "tags": s.get("tags") or [], "runtime": s_runtime,
                                   "_tags_reliable": True},
                        "episodeFile": {"id": ef["episode_file_id"]},
                        "episodes": [{"id": ef["episode_id"]}],
                        "downloadId": None,
                    })

        _save_audio_verified(verified)
        logger.info(
            f"━━ Varredura de áudio concluída: {checked} verificados, {rejected} rejeitados, "
            f"{skipped} já OK (pulados pelo cache) ━━"
        )

    def _periodic_scan(self):
        """Roda o scan imediatamente e depois repete a cada SCAN_INTERVAL segundos."""
        # Validação proativa de áudio (uma vez, no boot) antes da varredura de legendas
        self._run_audio_check()

        # Scan inicial (logo após o watchdog iniciar)
        logger.info(f"Executando scan inicial...")
        self._run_scan()

        while True:
            logger.info(f"Próximo scan automático em {PERIODIC_SCAN_INTERVAL}s.")
            time.sleep(PERIODIC_SCAN_INTERVAL)
            self._run_scan()

    def start(self):
        # Sem watchdog de tempo real: arquivos novos são tratados pelo WEBHOOK do Arr
        # (que valida áudio/duração/tag ANTES de mexer na legenda) e a varredura periódica
        # cobre o restante. Isso elimina a corrida em que o watchdog traduzia, em paralelo,
        # um arquivo que o webhook estava validando/rejeitando.
        logger.info(f"Varredura periódica a cada {PERIODIC_SCAN_INTERVAL}s ({PERIODIC_SCAN_INTERVAL // 60} min).")
        self._periodic_scan()  # bloqueia (loop infinito)
