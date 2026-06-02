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
    for attempt in range(3):
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
            return None # File not found, no need to retry
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
            return None
        except Exception as e:
            logger.warning(f"Bazarr: erro ao buscar episódios (tentativa {attempt+1}/3) — {e}")
            time.sleep(10)
    return None


# ------------------------------------------------------------------ #
# Trigger: aciona download                                            #
# ------------------------------------------------------------------ #

def _trigger(media_type: str, media_id: int) -> bool:
    try:
        with httpx.Client(timeout=60) as c:
            # Para forçar download, em vez de disparar a rotina automática (que descarta legendas com score baixo),
            # nós vamos buscar todas as legendas disponíveis e forçar o download da primeira com a linguagem correta.
            search_endpoint = f"{BAZARR_URL}/api/movies/{media_id}/subtitles" if media_type == "movie" else f"{BAZARR_URL}/api/episodes/{media_id}/subtitles"
            
            try:
                # 1. Faz busca manual
                logger.info(f"Fazendo busca manual profunda no Bazarr para {media_type} ID={media_id}")
                resp = c.get(search_endpoint, headers=_headers(), params={"language": LANGUAGE})
                
                if resp.status_code == 200:
                    subs = resp.json().get("data", [])
                    if subs:
                        # Pega a melhor opção retornada e manda baixar explicitamente
                        best_sub = subs[0]
                        logger.info(f"Legenda manual encontrada no Bazarr: Score={best_sub.get('score')} Provider={best_sub.get('provider')}")
                        
                        # A rota de download manual costuma ser um GET com query param, ou POST no mesmo path do provider
                        # No Bazarr, geralmente se envia as infos da legenda na URL ou corpo
                        # Uma rota comum de download explícito na API v1:
                        download_payload = {
                            "action": "download",
                            "name": best_sub.get('name', ''),
                            "provider": best_sub.get('provider', '')
                        }
                        
                        dl_resp = c.post(
                            f"{BAZARR_URL}/api/subtitles",
                            headers=_headers(),
                            json=download_payload
                        )
                        logger.info("Download manual acionado via API")
                        return True
            except Exception as e:
                logger.warning(f"Tentativa de busca profunda manual falhou, fallback para rotina automática: {e}")

            # Fallback: comando automático padrão
            if media_type == "movie":
                payload = {"name": "MoviesSearch", "movieid": [media_id]}
            else:
                payload = {"name": "EpsSearch", "episodeid": [media_id]}
                
            r = c.post(
                f"{BAZARR_URL}/api/command",
                headers=_headers(),
                json=payload
            )
            r.raise_for_status()
        logger.info(f"Bazarr: comando de busca automática enviado ({media_type} id={media_id})")
        return True
    except Exception as e:
        logger.warning(f"Bazarr: falha ao acionar comando de busca — {e}")
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
