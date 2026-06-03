"""
Módulo de integração com o Bazarr (interface web).
Permite buscar/baixar legendas PT-BR para filmes/episódios via API do Bazarr,
mapeando o filepath do arquivo para o ID interno do Bazarr.

Usa a mesma API confirmada no worker:
  - Lookup:   GET /api/movies | /api/series | /api/episodes?seriesid[]=N
  - Download: PATCH /api/movies/subtitles | PATCH /api/episodes/subtitles
"""

import os
import logging
import httpx

logger = logging.getLogger(__name__)

BAZARR_URL = os.environ.get("BAZARR_URL", "http://bazarr:6767")
BAZARR_API_KEY = os.environ.get("BAZARR_API_KEY", "")
# Para Brazilian Portuguese o alpha-2 do Bazarr é "pb".
LANGUAGE = os.environ.get("BAZARR_LANGUAGE", "pb")


def _headers() -> dict:
    return {"X-Api-Key": BAZARR_API_KEY, "Accept": "application/json"}


def _find_movie_by_path(filepath: str) -> dict | None:
    """Busca o filme no Bazarr cujo path coincide com o filepath fornecido."""
    try:
        with httpx.Client(timeout=15) as client:
            resp = client.get(f"{BAZARR_URL}/api/movies", headers=_headers(),
                              params={"start": 0, "length": -1})
            resp.raise_for_status()
            movies = resp.json().get("data", [])

        target = os.path.normpath(filepath)
        for m in movies:
            movie_path = os.path.normpath(m.get("path", ""))
            if movie_path and (target == movie_path or target.startswith(movie_path)):
                return m
    except Exception as e:
        logger.error(f"Erro ao buscar filmes no Bazarr: {e}")
    return None


def _find_episode_by_path(filepath: str) -> dict | None:
    """
    Busca o episódio no Bazarr cujo path coincide com o filepath fornecido.

    A API do Bazarr NÃO permite listar todos os episódios de uma vez — é obrigatório
    informar seriesid[]. Então iteramos as séries e buscamos os episódios de cada uma.
    """
    target = os.path.normpath(filepath)
    try:
        with httpx.Client(timeout=15) as client:
            resp = client.get(f"{BAZARR_URL}/api/series", headers=_headers(),
                              params={"start": 0, "length": -1})
            resp.raise_for_status()
            series_list = resp.json().get("data", [])

        for series in series_list:
            sonarr_id = series.get("sonarrSeriesId")
            if not sonarr_id:
                continue
            try:
                with httpx.Client(timeout=15) as client:
                    resp = client.get(f"{BAZARR_URL}/api/episodes", headers=_headers(),
                                      params={"seriesid[]": sonarr_id})
                    if resp.status_code != 200:
                        continue
                    episodes = resp.json().get("data", [])
                for ep in episodes:
                    if os.path.normpath(ep.get("path", "")) == target:
                        return ep
            except Exception:
                continue
    except Exception as e:
        logger.error(f"Erro ao buscar episódios no Bazarr: {e}")
    return None


def _download_movie_subtitle(radarr_id: int) -> bool:
    """Aciona o download automático de legenda PT-BR para um filme."""
    try:
        with httpx.Client(timeout=120) as client:
            resp = client.patch(
                f"{BAZARR_URL}/api/movies/subtitles",
                headers=_headers(),
                params={"radarrid": radarr_id, "language": LANGUAGE, "hi": "false", "forced": "false"},
            )
        if resp.status_code in (200, 201, 204):
            logger.info(f"Bazarr: download acionado para filme radarrId={radarr_id}")
            return True
        logger.error(f"Bazarr: PATCH movies/subtitles retornou {resp.status_code}: {resp.text[:200]}")
        return False
    except Exception as e:
        logger.error(f"Erro ao acionar download no Bazarr (filme {radarr_id}): {e}")
        return False


def _download_episode_subtitle(series_id: int, episode_id: int) -> bool:
    """Aciona o download automático de legenda PT-BR para um episódio."""
    try:
        with httpx.Client(timeout=120) as client:
            resp = client.patch(
                f"{BAZARR_URL}/api/episodes/subtitles",
                headers=_headers(),
                params={"seriesid": series_id, "episodeid": episode_id,
                        "language": LANGUAGE, "hi": "false", "forced": "false"},
            )
        if resp.status_code in (200, 201, 204):
            logger.info(f"Bazarr: download acionado para episódio seriesId={series_id} episodeId={episode_id}")
            return True
        logger.error(f"Bazarr: PATCH episodes/subtitles retornou {resp.status_code}: {resp.text[:200]}")
        return False
    except Exception as e:
        logger.error(f"Erro ao acionar download no Bazarr (episódio {episode_id}): {e}")
        return False


def search_subtitle(filepath: str) -> dict:
    """
    Ponto de entrada principal.
    Retorna: {"success": bool, "type": "movie"|"episode"|None, "message": str}
    """
    if not BAZARR_API_KEY:
        return {"success": False, "type": None, "message": "BAZARR_API_KEY não configurada."}

    # Tenta filme primeiro
    movie = _find_movie_by_path(filepath)
    if movie:
        radarr_id = movie.get("radarrId") or movie.get("radarrid") or movie.get("id")
        title = movie.get("title", os.path.basename(filepath))
        if radarr_id and _download_movie_subtitle(int(radarr_id)):
            return {"success": True, "type": "movie",
                    "message": f"Download de legenda acionado no Bazarr para: {title}"}
        return {"success": False, "type": "movie",
                "message": f"Filme encontrado ({title}) mas o Bazarr não conseguiu baixar. Verifique se há provider PT-BR e se o idioma '{LANGUAGE}' está no perfil."}

    # Tenta episódio
    episode = _find_episode_by_path(filepath)
    if episode:
        series_id = episode.get("sonarrSeriesId")
        ep_id = episode.get("sonarrEpisodeId")
        title = episode.get("title", os.path.basename(filepath))
        if series_id and ep_id and _download_episode_subtitle(int(series_id), int(ep_id)):
            return {"success": True, "type": "episode",
                    "message": f"Download de legenda acionado no Bazarr para: {title}"}
        return {"success": False, "type": "episode",
                "message": f"Episódio encontrado ({title}) mas o Bazarr não conseguiu baixar. Verifique se há provider PT-BR e se o idioma '{LANGUAGE}' está no perfil."}

    return {
        "success": False,
        "type": None,
        "message": "Arquivo não encontrado no Bazarr. Verifique se o Radarr/Sonarr já o importou.",
    }
