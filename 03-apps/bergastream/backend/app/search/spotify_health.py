"""Teste diário do Spotify (caminho anônimo) com atualização automática.

O worker roda `check_and_heal` ao subir e depois a cada SPOTIFY_CHECK_HOURS:

1. Testa busca, faixa, álbum, playlist editorial (SpotifyScraper) e o ISRC
   (endpoint interno, `spotify_meta`) com itens conhecidos.
2. Se a parte da biblioteca falhar e houver versão mais nova da SpotifyScraper
   no PyPI, instala em PYDEPS_DIR/<versão> (só o pacote, `--no-deps`), roda
   os mesmos testes num processo separado com a versão nova e, se passarem,
   aponta PYDEPS_DIR/active para ela e reinicia (o worker sai e o Docker sobe
   de novo; a API vê a versão nova no Redis e reinicia também).
3. O resultado fica no Redis e aparece em GET /api/server/status.

Falha do ISRC não se resolve atualizando a biblioteca (é um endpoint que ela
não usa): fica registrada, e o download acha a faixa no Deezer por artista +
título + duração enquanto isso.

Manual (dentro do container): python -m app.search.spotify_health
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx

from app import version_tuple
from app.config import settings

logger = logging.getLogger("bergastream.search.spotify_health")

HEALTH_KEY = "bergastream:spotify:health"
LIBRARY_KEY = "bergastream:spotify:library"  # versão ativa (a API reinicia se mudar)

# Itens conhecidos e estáveis.
_TRACK_ID = "4uLU6hMCjMI75M1A2tKUQC"      # Rick Astley — Never Gonna Give You Up
_TRACK_ISRC = "GBARL9300135"
_ALBUM_ID = "3SrW9PsWq7ipPERLgck3tA"      # Djavan — Djavan (1989)
_PLAYLIST_ID = "37i9dQZF1DXcBWIGoYBM5M"   # Today's Top Hits (editorial do Spotify)
_QUERY = "Coldplay Yellow"


def library_version() -> str:
    import spotify_scraper
    return getattr(spotify_scraper, "__version__", "0")


def run_library_checks() -> dict[str, str | None]:
    """Cada teste da biblioteca: None = passou; texto = motivo da falha."""
    from spotify_scraper import SpotifyClient

    results: dict[str, str | None] = {}

    def check(name, fn):
        try:
            problem = fn()
            results[name] = problem
        except Exception as exc:
            results[name] = f"{type(exc).__name__}: {exc}"[:300]

    with SpotifyClient(timeout=20) as sp:
        check("busca", lambda: None if sp.search(_QUERY, types=("track",), limit=5).tracks
              else "nenhuma faixa encontrada")
        check("faixa", lambda: None if "never gonna" in (sp.get_track(_TRACK_ID).name or "").lower()
              else "faixa com dados errados")
        check("álbum", lambda: None if len(sp.get_album(_ALBUM_ID).tracks) >= 5
              else "álbum sem faixas")
        check("playlist", lambda: None if len(sp.get_playlist(_PLAYLIST_ID, max_tracks=20).tracks) >= 10
              else "playlist sem faixas")
    return results


async def run_isrc_check() -> str | None:
    from app.search.spotify_meta import track_details

    details = await track_details(_TRACK_ID)
    if details is None:
        return "sem resposta dos metadados do Spotify"
    if details.isrc != _TRACK_ISRC:
        return f"ISRC inesperado: {details.isrc!r}"
    return None


async def run_canary() -> dict:
    library = await asyncio.to_thread(run_library_checks)
    isrc = await run_isrc_check()
    checks = {**library, "isrc": isrc}
    return {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "library_version": library_version(),
        "library_ok": all(v is None for v in library.values()),
        "isrc_ok": isrc is None,
        "ok": all(v is None for v in checks.values()),
        "failures": {k: v for k, v in checks.items() if v},
    }


async def latest_pypi_version() -> str | None:
    try:
        async with httpx.AsyncClient(timeout=20) as cli:
            r = await cli.get("https://pypi.org/pypi/spotifyscraper/json")
            r.raise_for_status()
            return r.json()["info"]["version"]
    except Exception as exc:
        logger.warning("[spotify-health] não consultou o PyPI: %s", exc)
        return None


async def _run(*args: str, env: dict | None = None, timeout: int = 300) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *args, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return 1, "tempo esgotado"
    return proc.returncode or 0, out.decode(errors="replace")


async def install_and_verify(version: str) -> tuple[bool, str]:
    """Instala a versão na pasta persistente e roda os testes nela, num
    processo separado (o processo atual segue com a versão antiga)."""
    base = Path(settings.pydeps_dir)
    target = base / f"spotifyscraper-{version}"
    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    base.mkdir(parents=True, exist_ok=True)
    code, out = await _run(sys.executable, "-m", "pip", "install", "--no-deps", "--no-cache-dir",
                           "--disable-pip-version-check", "--target", str(target),
                           f"spotifyscraper=={version}")
    if code != 0:
        return False, f"pip falhou: {out[-300:]}"
    env = {**os.environ, "BERGASTREAM_PYDEPS_FORCE": str(target)}
    code, out = await _run(sys.executable, "-m", "app.search.spotify_health", "--library-only",
                           env=env, timeout=180)
    if code != 0:
        return False, f"a versão {version} também falhou nos testes: {out[-300:]}"
    active = base / "active"
    tmp_link = base / "active.new"
    tmp_link.unlink(missing_ok=True)
    tmp_link.symlink_to(target.name)
    os.replace(tmp_link, active)  # troca atômica do link
    return True, f"SpotifyScraper {version} instalada e aprovada nos testes"


async def check_and_heal(redis) -> dict:
    """Roda o teste; se a biblioteca falhar, tenta atualizar. Devolve o
    resultado (com `restart=True` quando uma versão nova foi ativada)."""
    result = await run_canary()
    if not result["library_ok"]:
        logger.warning("[spotify-health] falhou: %s", result["failures"])
        latest = await latest_pypi_version()
        current = result["library_version"]
        if not settings.pydeps_dir:
            result["update"] = "atualização automática desligada (PYDEPS_DIR vazio)"
        elif latest and version_tuple(latest) > version_tuple(current):
            ok, message = await install_and_verify(latest)
            result["update"] = message
            if ok:
                result["updated_to"] = latest
                result["restart"] = True
                await redis.set(LIBRARY_KEY, latest)
                logger.warning("[spotify-health] %s — reiniciando para usar", message)
            else:
                logger.error("[spotify-health] %s", message)
        else:
            result["update"] = (f"nenhuma versão mais nova que {current} no PyPI ainda; "
                                "tento de novo na próxima verificação")
    elif not result["isrc_ok"]:
        logger.warning("[spotify-health] ISRC falhou: %s (downloads usam a busca do Deezer)",
                       result["failures"].get("isrc"))
    else:
        logger.info("[spotify-health] ok (SpotifyScraper %s)", result["library_version"])
    await redis.set(HEALTH_KEY, json.dumps(result, ensure_ascii=False))
    return result


async def read_health(redis) -> dict | None:
    raw = await redis.get(HEALTH_KEY)
    return json.loads(raw) if raw else None


async def api_restart_watch(redis, interval: int = 300) -> None:
    """Na API: reinicia o processo quando o worker ativar outra versão da
    biblioteca (o Docker sobe de novo e carrega a versão nova)."""
    import signal

    loaded = library_version()
    while True:
        await asyncio.sleep(interval)
        try:
            wanted = await redis.get(LIBRARY_KEY)
        except Exception:
            continue
        if wanted and version_tuple(wanted) > version_tuple(loaded):
            logger.warning("[spotify-health] SpotifyScraper %s ativada pelo worker; reiniciando a API", wanted)
            os.kill(os.getpid(), signal.SIGTERM)
            return


def _main() -> int:
    library_only = "--library-only" in sys.argv
    if library_only:
        checks = run_library_checks()
        print(json.dumps({"version": library_version(), "checks": checks}, ensure_ascii=False))
        return 0 if all(v is None for v in checks.values()) else 1
    result = asyncio.run(run_canary())
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(_main())
