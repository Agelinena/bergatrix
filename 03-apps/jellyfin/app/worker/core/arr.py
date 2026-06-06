"""
Cliente das APIs do Radarr e Sonarr (v3).

Usado pelo verificador de áudio para garantir que o arquivo tenha o áudio no
idioma ORIGINAL. Quando falta, o release é blocklistado e uma nova busca é
disparada — assim o Arr baixa OUTRO release (não o mesmo), e o novo import
dispara nova verificação (loop até vir um arquivo correto).

Endpoints confirmados no código-fonte do Radarr/Sonarr:
  GET    /api/v3/movie/{id}                 -> originalLanguage {id,name}
  GET    /api/v3/series/{id}                -> originalLanguage {id,name}
  GET    /api/v3/movie                      -> lista (path, movieFile, originalLanguage)
  GET    /api/v3/history?downloadId=...     -> {records:[{id,eventType,...}]}
  GET    /api/v3/history/movie?movieId=...  -> [{id,eventType,...}]
  GET    /api/v3/history/series?seriesId=.. -> [{id,eventType,...}]
  POST   /api/v3/history/failed/{id}        -> blocklista o release + re-busca
  DELETE /api/v3/moviefile/{id} | /episodefile/{id}
  POST   /api/v3/command  {name, movieIds|episodeIds}
"""

import os
import logging
import httpx

logger = logging.getLogger(__name__)

RADARR_URL = os.environ.get("RADARR_URL", "http://radarr:7878").rstrip("/")
RADARR_API_KEY = os.environ.get("RADARR_API_KEY", "")
SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989").rstrip("/")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "")


def radarr_enabled() -> bool:
    return bool(RADARR_API_KEY)


def sonarr_enabled() -> bool:
    return bool(SONARR_API_KEY)


def _headers(api_key: str) -> dict:
    return {"X-Api-Key": api_key, "Accept": "application/json"}


def _get(base: str, key: str, path: str, params: dict | None = None):
    try:
        with httpx.Client(timeout=30) as c:
            r = c.get(f"{base}{path}", headers=_headers(key), params=params or {})
            r.raise_for_status()
            return r.json()
    except Exception as e:
        logger.warning(f"Arr GET {path} falhou: {e}")
        return None


def _post(base: str, key: str, path: str, payload: dict):
    try:
        with httpx.Client(timeout=30) as c:
            r = c.post(f"{base}{path}", headers=_headers(key), json=payload)
            r.raise_for_status()
            return True
    except Exception as e:
        logger.warning(f"Arr POST {path} falhou: {e}")
        return False


def _delete(base: str, key: str, path: str, params: dict | None = None):
    try:
        with httpx.Client(timeout=30) as c:
            r = c.delete(f"{base}{path}", headers=_headers(key), params=params or {})
            r.raise_for_status()
            return True
    except Exception as e:
        logger.warning(f"Arr DELETE {path} falhou: {e}")
        return False


def _is_grabbed(event_type) -> bool:
    # A API v3 serializa eventType como string ("grabbed"); aceitamos int 1 por segurança.
    return event_type == "grabbed" or event_type == 1


# ------------------------------------------------------------------ #
# Idioma original                                                      #
# ------------------------------------------------------------------ #

def get_movie_original_language(movie_id: int) -> str | None:
    data = _get(RADARR_URL, RADARR_API_KEY, f"/api/v3/movie/{movie_id}")
    if data:
        name = data.get("originalLanguage", {}).get("name")
        return name.lower() if name else None
    return None


def get_series_original_language(series_id: int) -> str | None:
    data = _get(SONARR_URL, SONARR_API_KEY, f"/api/v3/series/{series_id}")
    if data:
        name = data.get("originalLanguage", {}).get("name")
        return name.lower() if name else None
    return None


def get_movie_runtime(movie_id: int) -> int | None:
    """Runtime do filme em minutos (Radarr)."""
    data = _get(RADARR_URL, RADARR_API_KEY, f"/api/v3/movie/{movie_id}")
    return (data or {}).get("runtime") or None


def get_series_runtime(series_id: int) -> int | None:
    """Runtime médio dos episódios da série em minutos (Sonarr)."""
    data = _get(SONARR_URL, SONARR_API_KEY, f"/api/v3/series/{series_id}")
    return (data or {}).get("runtime") or None


# ------------------------------------------------------------------ #
# Lookup por caminho (varredura proativa)                              #
# ------------------------------------------------------------------ #

def list_movies() -> list:
    """Retorna todos os filmes do Radarr (com path, movieFile, originalLanguage)."""
    return _get(RADARR_URL, RADARR_API_KEY, "/api/v3/movie") or []


def find_movie_by_path(filepath: str, movies: list | None = None) -> dict | None:
    if movies is None:
        movies = list_movies()
    target = os.path.normpath(filepath)
    for m in movies:
        file_path = (m.get("movieFile") or {}).get("path", "")
        folder = m.get("path", "")
        if file_path and os.path.normpath(file_path) == target:
            return m
        if folder and target.startswith(os.path.normpath(folder)):
            return m
    return None


def list_series() -> list:
    """Retorna todas as séries do Sonarr (com originalLanguage)."""
    return _get(SONARR_URL, SONARR_API_KEY, "/api/v3/series") or []


def list_series_episode_files(series_id: int) -> list:
    """Retorna [{path, episode_file_id, episode_id}] dos episódios COM arquivo de uma série."""
    episodes = _get(SONARR_URL, SONARR_API_KEY, "/api/v3/episode", {"seriesId": series_id}) or []
    files = _get(SONARR_URL, SONARR_API_KEY, "/api/v3/episodefile", {"seriesId": series_id}) or []
    file_by_id = {f.get("id"): f for f in files}
    result = []
    for ep in episodes:
        if not ep.get("hasFile"):
            continue
        fid = ep.get("episodeFileId")
        f = file_by_id.get(fid)
        if f and f.get("path"):
            result.append({"path": f["path"], "episode_file_id": fid, "episode_id": ep.get("id")})
    return result


# ------------------------------------------------------------------ #
# Tags (exceções: "manter o áudio como está")                          #
# ------------------------------------------------------------------ #

_tag_id_cache: dict = {}


def _tag_id(base: str, key: str, label: str) -> int | None:
    """Resolve o nome de uma tag para o ID interno do Arr (com cache)."""
    ck = (base, label.lower())
    if ck not in _tag_id_cache:
        tid = None
        for t in (_get(base, key, "/api/v3/tag") or []):
            if str(t.get("label", "")).lower() == label.lower():
                tid = t.get("id")
                break
        _tag_id_cache[ck] = tid
    return _tag_id_cache[ck]


def radarr_tag_id(label: str) -> int | None:
    return _tag_id(RADARR_URL, RADARR_API_KEY, label)


def sonarr_tag_id(label: str) -> int | None:
    return _tag_id(SONARR_URL, SONARR_API_KEY, label)


def movie_has_tag(movie_id: int, label: str) -> bool:
    tid = radarr_tag_id(label)
    if tid is None:
        return False
    d = _get(RADARR_URL, RADARR_API_KEY, f"/api/v3/movie/{movie_id}")
    return bool(d and tid in (d.get("tags") or []))


def series_has_tag(series_id: int, label: str) -> bool:
    tid = sonarr_tag_id(label)
    if tid is None:
        return False
    d = _get(SONARR_URL, SONARR_API_KEY, f"/api/v3/series/{series_id}")
    return bool(d and tid in (d.get("tags") or []))


# ------------------------------------------------------------------ #
# Rejeição: blocklist + re-busca (pega OUTRO release)                  #
# ------------------------------------------------------------------ #

def _grabbed_id_by_download(base: str, key: str, download_id: str) -> int | None:
    if not download_id:
        return None
    data = _get(base, key, "/api/v3/history", {"downloadId": download_id, "pageSize": 50})
    records = (data or {}).get("records", []) if isinstance(data, dict) else (data or [])
    for r in records:
        if _is_grabbed(r.get("eventType")):
            return r.get("id")
    return None


def _grabbed_id_by_movie(movie_id: int) -> int | None:
    data = _get(RADARR_URL, RADARR_API_KEY, "/api/v3/history/movie", {"movieId": movie_id})
    records = data if isinstance(data, list) else (data or {}).get("records", [])
    grabbed = [r for r in records if _is_grabbed(r.get("eventType"))]
    return grabbed[-1]["id"] if grabbed else None


def reject_movie(movie_id: int, file_id: int | None, download_id: str | None) -> bool:
    """Deleta o arquivo, blocklista o release e dispara nova busca no Radarr."""
    if not radarr_enabled():
        logger.warning("RADARR_API_KEY não configurada — não é possível rejeitar/rebaixar.")
        return False

    if file_id:
        _delete(RADARR_URL, RADARR_API_KEY, f"/api/v3/moviefile/{file_id}")

    hist_id = _grabbed_id_by_download(RADARR_URL, RADARR_API_KEY, download_id) \
        or _grabbed_id_by_movie(movie_id)
    if hist_id:
        if _post(RADARR_URL, RADARR_API_KEY, f"/api/v3/history/failed/{hist_id}", {}):
            logger.info(f"Radarr: release blocklistado (history id={hist_id}) e nova busca disparada.")
    # Garante a busca mesmo se não achou o histórico para blocklistar
    _post(RADARR_URL, RADARR_API_KEY, "/api/v3/command", {"name": "MoviesSearch", "movieIds": [movie_id]})
    logger.info(f"Radarr: MoviesSearch disparado para movieId={movie_id}")
    return True


def reject_episode(series_id: int, episode_ids: list, file_id: int | None, download_id: str | None) -> bool:
    """Deleta o arquivo, blocklista o release e dispara nova busca no Sonarr."""
    if not sonarr_enabled():
        logger.warning("SONARR_API_KEY não configurada — não é possível rejeitar/rebaixar.")
        return False

    if file_id:
        _delete(SONARR_URL, SONARR_API_KEY, f"/api/v3/episodefile/{file_id}")

    hist_id = _grabbed_id_by_download(SONARR_URL, SONARR_API_KEY, download_id)
    if hist_id:
        if _post(SONARR_URL, SONARR_API_KEY, f"/api/v3/history/failed/{hist_id}", {}):
            logger.info(f"Sonarr: release blocklistado (history id={hist_id}) e nova busca disparada.")
    if episode_ids:
        _post(SONARR_URL, SONARR_API_KEY, "/api/v3/command",
              {"name": "EpisodeSearch", "episodeIds": episode_ids})
        logger.info(f"Sonarr: EpisodeSearch disparado para episodeIds={episode_ids}")
    return True


# ------------------------------------------------------------------ #
# Fila de downloads (remover stalled e rebaixar)                       #
# ------------------------------------------------------------------ #

def _queue(base: str, key: str) -> list:
    data = _get(base, key, "/api/v3/queue", {"pageSize": 1000})
    if isinstance(data, dict):
        return data.get("records", [])
    return data or []


def radarr_queue() -> list:
    return _queue(RADARR_URL, RADARR_API_KEY) if radarr_enabled() else []


def sonarr_queue() -> list:
    return _queue(SONARR_URL, SONARR_API_KEY) if sonarr_enabled() else []


def _remove_queue(base: str, key: str, item_id: int, blocklist: bool) -> bool:
    """Remove um item da fila: tira do download client, blocklista o release e rebaixa."""
    return _delete(base, key, f"/api/v3/queue/{item_id}", {
        "removeFromClient": "true",
        "blocklist": "true" if blocklist else "false",
        "skipRedownload": "false",   # dispara nova busca (pega OUTRO release)
    })


def radarr_remove_queue(item_id: int, blocklist: bool = True) -> bool:
    return _remove_queue(RADARR_URL, RADARR_API_KEY, item_id, blocklist)


def sonarr_remove_queue(item_id: int, blocklist: bool = True) -> bool:
    return _remove_queue(SONARR_URL, SONARR_API_KEY, item_id, blocklist)
