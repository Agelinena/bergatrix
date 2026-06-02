"""
Integração com o Bazarr no worker.

Fluxo:
  1. Localiza o arquivo no Bazarr (como filme ou episódio) pelo path
  2. Aciona download de legenda PT-BR
  3. Aguarda até BAZARR_WAIT_SECONDS para a legenda aparecer no disco
  4. Retorna True se a legenda foi encontrada/baixada, False caso contrário
"""

import os
import time
import logging
import httpx

logger = logging.getLogger(__name__)

BAZARR_URL = os.environ.get("BAZARR_URL", "http://bazarr:6767")
BAZARR_API_KEY = os.environ.get("BAZARR_API_KEY", "")
LANGUAGE = "pt-BR"
# Tempo máximo (segundos) para aguardar o download após acionar o Bazarr
BAZARR_WAIT_SECONDS = int(os.environ.get("BAZARR_WAIT_SECONDS", "60"))

SUBTITLE_SUFFIXES = ('.por.srt', '.pt-br.srt', '.pt.srt', '.portuguese.srt', '.ptbr.srt')


def _headers() -> dict:
    return {"X-Api-Key": BAZARR_API_KEY, "Accept": "application/json"}


def _subtitle_exists(filepath: str) -> bool:
    base = os.path.splitext(filepath)[0]
    return any(os.path.exists(base + s) for s in SUBTITLE_SUFFIXES)


# ------------------------------------------------------------------ #
# Lookup: filepath → ID no Bazarr                                     #
# ------------------------------------------------------------------ #

def _find_movie(filepath: str) -> dict | None:
    try:
        with httpx.Client(timeout=15) as c:
            r = c.get(f"{BAZARR_URL}/api/movies", headers=_headers(),
                      params={"start": 0, "length": -1})
            r.raise_for_status()
        target = os.path.normpath(filepath)
        for m in r.json().get("data", []):
            movie_path = os.path.normpath(m.get("path", ""))
            # Bazarr pode armazenar o diretório ou o arquivo completo
            if target.startswith(movie_path) or movie_path == target:
                return m
    except Exception as e:
        logger.warning(f"Bazarr: erro ao buscar filmes — {e}")
    return None


def _find_episode(filepath: str) -> dict | None:
    """Busca o episódio no Bazarr: primeiro lista séries, depois busca episódios por série."""
    target = os.path.normpath(filepath)
    try:
        with httpx.Client(timeout=15) as c:
            r = c.get(f"{BAZARR_URL}/api/series", headers=_headers(),
                      params={"start": 0, "length": -1})
            r.raise_for_status()
            series_list = r.json().get("data", [])

        for series in series_list:
            sonarr_id = series.get("sonarrSeriesId") or series.get("id")
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
    except Exception as e:
        logger.warning(f"Bazarr: erro ao buscar episódios — {e}")
    return None


# ------------------------------------------------------------------ #
# Trigger: aciona download                                            #
# ------------------------------------------------------------------ #

def _trigger(media_type: str, media_id: int) -> bool:
    try:
        with httpx.Client(timeout=30) as c:
            # Ao acionar, forçamos a busca ignorando o "score" padrão do release
            # O Bazarr usa a rota de manual/wanted com certos thresholds
            r = c.post(
                f"{BAZARR_URL}/api/subtitles",
                headers=_headers(),
                json={
                    "type": media_type,
                    "id": media_id,
                    "language": LANGUAGE,
                    "hi": "false",
                    "forced": "false",
                    # Injetamos parametros extras que algumas APIs aceitam para forçar match
                    "force": True, 
                    "ignore_score": True
                },
            )
            r.raise_for_status()
        logger.info(f"Bazarr: busca FORÇADA acionada ({media_type} id={media_id})")
        return True
    except Exception as e:
        logger.warning(f"Bazarr: falha ao acionar download — {e}")
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
        radarr_id = movie.get("radarrid") or movie.get("id")
        title = movie.get("title", os.path.basename(filepath))
        logger.info(f"Bazarr: filme encontrado — '{title}' (radarrid={radarr_id})")
        if radarr_id and _trigger("movie", int(radarr_id)):
            return _wait_for_subtitle(filepath)
        return False

    # Tenta episódio
    episode = _find_episode(filepath)
    if episode:
        ep_id = episode.get("sonarrEpisodeId") or episode.get("episode_id") or episode.get("id")
        title = episode.get("title", os.path.basename(filepath))
        logger.info(f"Bazarr: episódio encontrado — '{title}' (id={ep_id})")
        if ep_id and _trigger("episode", int(ep_id)):
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
