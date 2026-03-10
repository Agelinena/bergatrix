"""
Módulo de integração com o Bazarr.
Permite buscar legendas PT-BR para filmes/episódios via API do Bazarr,
mapeando o filepath do arquivo para o ID interno do Bazarr.
"""

import os
import logging
import httpx

logger = logging.getLogger(__name__)

BAZARR_URL = os.environ.get("BAZARR_URL", "http://bazarr:6767")
BAZARR_API_KEY = os.environ.get("BAZARR_API_KEY", "")
LANGUAGE = "pt-BR"


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

        # Normaliza os paths para comparação
        target = os.path.normpath(filepath)
        for m in movies:
            movie_path = m.get("path", "")
            # Bazarr armazena o diretório do filme, não o arquivo
            # O arquivo real fica dentro desse diretório
            if target.startswith(os.path.normpath(movie_path)):
                return m
            # Tenta também comparação direta (alguns setups armazenam o path completo)
            if os.path.normpath(movie_path) == target:
                return m
    except Exception as e:
        logger.error(f"Erro ao buscar filmes no Bazarr: {e}")
    return None


def _find_episode_by_path(filepath: str) -> dict | None:
    """Busca o episódio no Bazarr cujo path coincide com o filepath fornecido."""
    try:
        with httpx.Client(timeout=15) as client:
            # Bazarr não permite buscar todos os episódios sem series ID,
            # mas podemos usar o endpoint de episódios com filtro de path
            resp = client.get(
                f"{BAZARR_URL}/api/episodes",
                headers=_headers(),
                params={"start": 0, "length": -1},
            )
            resp.raise_for_status()
            episodes = resp.json().get("data", [])

        target = os.path.normpath(filepath)
        for ep in episodes:
            if os.path.normpath(ep.get("path", "")) == target:
                return ep
    except Exception as e:
        logger.error(f"Erro ao buscar episódios no Bazarr: {e}")
    return None


def _trigger_movie_search(radarr_id: int) -> bool:
    """Aciona busca de legendas PT-BR para um filme."""
    try:
        with httpx.Client(timeout=30) as client:
            resp = client.post(
                f"{BAZARR_URL}/api/subtitles",
                headers=_headers(),
                json={
                    "type": "movie",
                    "id": radarr_id,
                    "language": LANGUAGE,
                    "hi": "false",
                    "forced": "false",
                },
            )
            resp.raise_for_status()
            logger.info(f"Bazarr: busca de legenda PT-BR iniciada para filme ID={radarr_id}")
            return True
    except Exception as e:
        logger.error(f"Erro ao acionar busca no Bazarr (filme {radarr_id}): {e}")
        return False


def _trigger_episode_search(sonarr_episode_id: int) -> bool:
    """Aciona busca de legendas PT-BR para um episódio."""
    try:
        with httpx.Client(timeout=30) as client:
            resp = client.post(
                f"{BAZARR_URL}/api/subtitles",
                headers=_headers(),
                json={
                    "type": "episode",
                    "id": sonarr_episode_id,
                    "language": LANGUAGE,
                    "hi": "false",
                    "forced": "false",
                },
            )
            resp.raise_for_status()
            logger.info(f"Bazarr: busca de legenda PT-BR iniciada para episódio ID={sonarr_episode_id}")
            return True
    except Exception as e:
        logger.error(f"Erro ao acionar busca no Bazarr (episódio {sonarr_episode_id}): {e}")
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
        radarr_id = movie.get("radarrid") or movie.get("id")
        title = movie.get("title", os.path.basename(filepath))
        if radarr_id and _trigger_movie_search(int(radarr_id)):
            return {
                "success": True,
                "type": "movie",
                "message": f"Busca iniciada no Bazarr para: {title}",
            }
        return {"success": False, "type": "movie", "message": f"Filme encontrado ({title}) mas falha ao acionar busca."}

    # Tenta episódio
    episode = _find_episode_by_path(filepath)
    if episode:
        ep_id = episode.get("sonarrEpisodeId") or episode.get("episode_id") or episode.get("id")
        title = episode.get("title", os.path.basename(filepath))
        if ep_id and _trigger_episode_search(int(ep_id)):
            return {
                "success": True,
                "type": "episode",
                "message": f"Busca iniciada no Bazarr para: {title}",
            }
        return {"success": False, "type": "episode", "message": f"Episódio encontrado ({title}) mas falha ao acionar busca."}

    return {
        "success": False,
        "type": None,
        "message": "Arquivo não encontrado no Bazarr. Verifique se o Radarr/Sonarr já o importou.",
    }
