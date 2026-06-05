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
BAZARR_WAIT_SECONDS = int(os.environ.get("BAZARR_WAIT_SECONDS", "60"))


def _headers() -> dict:
    return {"X-Api-Key": BAZARR_API_KEY, "Accept": "application/json"}


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
