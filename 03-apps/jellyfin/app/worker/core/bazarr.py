"""
Integração com o Bazarr no worker.

Fluxo:
  1. Localiza o arquivo no Bazarr (como filme ou episódio) pelo path
  2. Aciona o download automático de legenda PT-BR (Bazarr busca nos providers e baixa a melhor)
  3. Aguarda até BAZARR_WAIT_SECONDS para a legenda aparecer no disco
  4. Retorna True se a legenda foi encontrada/baixada, False caso contrário

API do Bazarr (confirmada no código-fonte oficial):
  - Lookup:   GET /api/movies            -> data[].radarrId / .path
              GET /api/series            -> data[].sonarrSeriesId / .path
              GET /api/episodes?seriesid[]=N -> data[].sonarrSeriesId / .sonarrEpisodeId / .path
  - Download: PATCH /api/movies/subtitles?radarrid=&language=&hi=&forced=
              PATCH /api/episodes/subtitles?seriesid=&episodeid=&language=&hi=&forced=
              (retorna 204 No Content em sucesso)
"""

import os
import time
import logging
import httpx
from .utils import has_pt_subtitle

logger = logging.getLogger(__name__)

BAZARR_URL = os.environ.get("BAZARR_URL", "http://bazarr:6767")
BAZARR_API_KEY = os.environ.get("BAZARR_API_KEY", "")
# Código de idioma usado pelo Bazarr. Para Brazilian Portuguese o alpha-2 é "pb".
# (Use "pt" se o seu Languages Profile estiver configurado como Português europeu.)
LANGUAGE = os.environ.get("BAZARR_LANGUAGE", "pb")
# Tempo máximo (segundos) para aguardar o download após acionar o Bazarr
BAZARR_WAIT_SECONDS = int(os.environ.get("BAZARR_WAIT_SECONDS", "120"))
BAZARR_SYNC_TIMEOUT = int(os.environ.get("BAZARR_SYNC_TIMEOUT", "900"))
BAZARR_SYNC_POLL_SECONDS = float(os.environ.get("BAZARR_SYNC_POLL_SECONDS", "10"))
BAZARR_SYNC_DISCOVERY_SECONDS = int(os.environ.get("BAZARR_SYNC_DISCOVERY_SECONDS", "20"))


def _headers() -> dict:
    return {"X-Api-Key": BAZARR_API_KEY, "Accept": "application/json"}


def _list_jobs(job_id: int | None = None, status: str | None = None) -> list[dict]:
    """Lista jobs do Bazarr, com filtro opcional por ID/status."""
    params = {}
    if job_id is not None:
        params["id"] = job_id
    if status:
        params["status"] = status
    try:
        with httpx.Client(timeout=15) as client:
            response = client.get(
                f"{BAZARR_URL}/api/system/jobs",
                headers=_headers(),
                params=params,
            )
        if response.status_code != 200:
            logger.warning(f"Bazarr: consulta de jobs retornou HTTP {response.status_code}")
            return []
        payload = response.json()
        return payload.get("data", payload if isinstance(payload, list) else [])
    except Exception as e:
        logger.warning(f"Bazarr: erro ao consultar jobs: {e}")
        return []


def _job_matches_subtitle(job: dict, subtitle_path: str) -> bool:
    name = str(job.get("job_name", ""))
    return os.path.normpath(subtitle_path) in os.path.normpath(name)


def _wait_for_sync_job(subtitle_path: str, previous_job_ids: set[int]) -> bool:
    """Descobre e acompanha o job assíncrono criado pelo sync do Bazarr."""
    deadline = time.monotonic() + BAZARR_SYNC_TIMEOUT
    discovery_deadline = min(
        deadline,
        time.monotonic() + BAZARR_SYNC_DISCOVERY_SECONDS,
    )
    job_id = None

    while time.monotonic() < discovery_deadline:
        active_jobs = _list_jobs(status="pending") + _list_jobs(status="running")
        candidates = [
            job for job in active_jobs
            if _job_matches_subtitle(job, subtitle_path)
            and int(job.get("job_id", -1)) not in previous_job_ids
        ]
        if candidates:
            job_id = int(candidates[-1]["job_id"])
            logger.info(f"Bazarr: job de sync encontrado id={job_id} alvo={subtitle_path}")
            break
        time.sleep(BAZARR_SYNC_POLL_SECONDS)

    if job_id is None:
        logger.error(
            f"Bazarr: sync aceito, mas job não localizado para {subtitle_path} "
            f"em {BAZARR_SYNC_DISCOVERY_SECONDS}s"
        )
        return False

    while time.monotonic() < deadline:
        jobs = _list_jobs(job_id=job_id)
        job = jobs[0] if jobs else None
        status = (job or {}).get("status", "unknown")
        progress = (job or {}).get("progress_value")
        progress_max = (job or {}).get("progress_max")
        message = (job or {}).get("progress_message", "")
        logger.info(
            f"Bazarr: sync job={job_id} status={status} "
            f"progresso={progress}/{progress_max} mensagem={message}"
        )
        if status == "completed":
            logger.info(f"Bazarr: sync concluído para {subtitle_path} job={job_id}")
            return True
        if status == "failed":
            logger.error(f"Bazarr: sync falhou para {subtitle_path} job={job_id}")
            return False
        time.sleep(BAZARR_SYNC_POLL_SECONDS)

    logger.error(f"Bazarr: timeout aguardando sync job={job_id} para {subtitle_path}")
    return False


def _subtitle_exists(filepath: str) -> bool:
    """Detecção da legenda baixada (case-insensitive, inclui .pt-BR.hi.srt do Bazarr)."""
    return has_pt_subtitle(filepath)


# ------------------------------------------------------------------ #
# Lookup: filepath → ID no Bazarr                                     #
# ------------------------------------------------------------------ #

def _find_movie(filepath: str) -> dict | None:
    target = os.path.normpath(filepath)
    for attempt in range(3):
        try:
            with httpx.Client(timeout=15) as c:
                r = c.get(f"{BAZARR_URL}/api/movies", headers=_headers(),
                          params={"start": 0, "length": -1})
                r.raise_for_status()
            for m in r.json().get("data", []):
                movie_path = os.path.normpath(m.get("path", ""))
                # Bazarr pode armazenar o diretório ou o arquivo completo
                if movie_path and (target == movie_path or target.startswith(movie_path)):
                    return m
            return None  # Encontrou a lista mas o arquivo não está nela — não adianta retentar
        except Exception as e:
            logger.warning(f"Bazarr: erro ao buscar filmes (tentativa {attempt+1}/3) — {e}")
            time.sleep(10)
    return None


def _find_episode(filepath: str) -> dict | None:
    """Busca o episódio no Bazarr: primeiro lista séries, depois busca episódios por série."""
    target = os.path.normpath(filepath)
    for attempt in range(3):
        try:
            with httpx.Client(timeout=15) as c:
                r = c.get(f"{BAZARR_URL}/api/series", headers=_headers(),
                          params={"start": 0, "length": -1})
                r.raise_for_status()
                series_list = r.json().get("data", [])

            for series in series_list:
                sonarr_id = series.get("sonarrSeriesId")
                if not sonarr_id:
                    continue
                try:
                    with httpx.Client(timeout=15) as c:
                        r = c.get(f"{BAZARR_URL}/api/episodes", headers=_headers(),
                                  params={"seriesid[]": sonarr_id})
                        if r.status_code != 200:
                            continue
                        episodes = r.json().get("data", [])
                    for ep in episodes:
                        if os.path.normpath(ep.get("path", "")) == target:
                            return ep
                except Exception:
                    continue
            return None
        except Exception as e:
            logger.warning(f"Bazarr: erro ao buscar episódios (tentativa {attempt+1}/3) — {e}")
            time.sleep(10)
    return None


def find_media_context(filepath: str) -> dict | None:
    """Retorna tipo e ID interno necessários para a API de sincronização."""
    movie = _find_movie(filepath)
    if movie:
        media_id = movie.get("radarrId") or movie.get("radarrid") or movie.get("id")
        if media_id:
            return {"type": "movie", "id": int(media_id), "language": LANGUAGE}

    episode = _find_episode(filepath)
    if episode:
        media_id = episode.get("sonarrEpisodeId") or episode.get("id")
        if media_id:
            return {"type": "episode", "id": int(media_id), "language": LANGUAGE}
    return None


# ------------------------------------------------------------------ #
# Trigger: aciona o download automático (PATCH .../subtitles)        #
# ------------------------------------------------------------------ #

def _download_movie_subtitle(radarr_id: int) -> bool:
    try:
        with httpx.Client(timeout=120) as c:
            r = c.patch(
                f"{BAZARR_URL}/api/movies/subtitles",
                headers=_headers(),
                params={
                    "radarrid": radarr_id,
                    "language": LANGUAGE,
                    "hi": "false",
                    "forced": "false",
                },
            )
        if r.status_code in (200, 201, 204):
            logger.info(f"Bazarr: download de legenda acionado (movie radarrid={radarr_id}, lang={LANGUAGE})")
            return True
        logger.warning(f"Bazarr: PATCH movies/subtitles retornou {r.status_code}: {r.text[:200]}")
        return False
    except Exception as e:
        logger.warning(f"Bazarr: falha ao acionar download de filme — {e}")
        return False


def _download_episode_subtitle(series_id: int, episode_id: int) -> bool:
    try:
        with httpx.Client(timeout=120) as c:
            r = c.patch(
                f"{BAZARR_URL}/api/episodes/subtitles",
                headers=_headers(),
                params={
                    "seriesid": series_id,
                    "episodeid": episode_id,
                    "language": LANGUAGE,
                    "hi": "false",
                    "forced": "false",
                },
            )
        if r.status_code in (200, 201, 204):
            logger.info(f"Bazarr: download acionado (episode seriesid={series_id}, episodeid={episode_id}, lang={LANGUAGE})")
            return True
        logger.warning(f"Bazarr: PATCH episodes/subtitles retornou {r.status_code}: {r.text[:200]}")
        return False
    except Exception as e:
        logger.warning(f"Bazarr: falha ao acionar download de episódio — {e}")
        return False


# ------------------------------------------------------------------ #
# Ponto de entrada principal                                          #
# ------------------------------------------------------------------ #

def search_and_download(filepath: str) -> bool:
    """
    Tenta encontrar e baixar uma legenda PT-BR pelo Bazarr.

    Retorna:
      True  → legenda baixada com sucesso (arquivo apareceu no disco)
      False → Bazarr não encontrou ou não baixou dentro do tempo limite
    """
    if not BAZARR_API_KEY:
        logger.debug("BAZARR_API_KEY não configurada — pulando etapa Bazarr.")
        return False

    logger.info(f"Bazarr: buscando legenda para {os.path.basename(filepath)}...")

    # Tenta filme
    movie = _find_movie(filepath)
    if movie:
        radarr_id = movie.get("radarrId") or movie.get("radarrid") or movie.get("id")
        title = movie.get("title", os.path.basename(filepath))
        logger.info(f"Bazarr: filme encontrado — '{title}' (radarrId={radarr_id})")
        if radarr_id and _download_movie_subtitle(int(radarr_id)):
            return _wait_for_subtitle(filepath)
        return False

    # Tenta episódio
    episode = _find_episode(filepath)
    if episode:
        series_id = episode.get("sonarrSeriesId")
        ep_id = episode.get("sonarrEpisodeId")
        title = episode.get("title", os.path.basename(filepath))
        logger.info(f"Bazarr: episódio encontrado — '{title}' (seriesId={series_id}, episodeId={ep_id})")
        if series_id and ep_id and _download_episode_subtitle(int(series_id), int(ep_id)):
            return _wait_for_subtitle(filepath)
        return False

    logger.info(f"Bazarr: arquivo não encontrado no Bazarr — {os.path.basename(filepath)}")
    return False


def sync_subtitle(
    media_path: str,
    subtitle_path: str,
    reference: str | None = None,
) -> bool:
    """Solicita ao Bazarr a sincronização da legenda externa selecionada.

    Quando reference é ``s:<index>``, o Bazarr usa uma legenda embutida como
    referência e não a trilha de áudio. Sem referência, o Bazarr pode usar
    sincronização por áudio conforme a configuração dele.
    """
    if not BAZARR_API_KEY:
        logger.warning("Bazarr: API key ausente — não foi possível solicitar sync.")
        return False
    context = find_media_context(media_path)
    if not context:
        logger.warning(f"Bazarr: mídia não encontrada para sincronização: {media_path}")
        return False

    previous_jobs = _list_jobs()
    previous_job_ids = {
        int(job["job_id"])
        for job in previous_jobs
        if str(job.get("job_id", "")).isdigit()
    }
    form = {
        "id": str(context["id"]),
        "type": context["type"],
        "language": context["language"],
        "path": subtitle_path,
        "hi": "False",
        "forced": "False",
        "max_offset_seconds": "60",
        "no_fix_framerate": "False",
        "gss": "False",
    }
    if reference:
        form["reference"] = reference
    try:
        with httpx.Client(timeout=BAZARR_WAIT_SECONDS + 30) as client:
            response = client.patch(
                f"{BAZARR_URL}/api/subtitles",
                headers=_headers(),
                params={"action": "sync"},
                data=form,
            )
        if response.status_code in (200, 201, 202, 204):
            logger.info(
                f"Bazarr: sync solicitado para {subtitle_path} "
                f"(type={context['type']} id={context['id']} "
                f"referência={reference or 'áudio'})"
            )
            return _wait_for_sync_job(subtitle_path, previous_job_ids)
        logger.warning(
            f"Bazarr: sync retornou HTTP {response.status_code}: {response.text[:300]}"
        )
    except Exception as e:
        logger.warning(f"Bazarr: falha ao solicitar sync de {subtitle_path}: {e}")
    return False


def _wait_for_subtitle(filepath: str) -> bool:
    """Aguarda até BAZARR_WAIT_SECONDS para a legenda aparecer no disco."""
    logger.info(f"Bazarr: aguardando download (máx {BAZARR_WAIT_SECONDS}s)...")
    elapsed = 0
    check_interval = 5

    while elapsed < BAZARR_WAIT_SECONDS:
        time.sleep(check_interval)
        elapsed += check_interval
        if _subtitle_exists(filepath):
            logger.info(f"✅ Bazarr: legenda PT-BR baixada com sucesso!")
            return True

    logger.info(f"Bazarr: legenda não apareceu em {BAZARR_WAIT_SECONDS}s — partindo para tradução via IA.")
    return False
