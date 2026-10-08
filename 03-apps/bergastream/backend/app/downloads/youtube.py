"""Plano B do download: acha a faixa no YouTube / YouTube Music e baixa
com o yt-dlp.

Busca em duas fontes: o YouTube Music (via ytmusicapi, que traz a duração e
costuma achar o áudio oficial) e a busca comum do YouTube. Cada resultado
ganha uma nota (título, artista, canal, duração); os melhores são tentados
em ordem até um baixar.

O YouTube às vezes bloqueia servidores ("Sign in to confirm you're not a
bot"): os pedidos levam um PO Token (prova de que vêm de um "navegador"),
gerado pelo serviço pot-provider (bgutil); se mesmo assim bloquear, o
download tenta outros clientes do yt-dlp (`web_embedded`, `mweb`) e, se
configurado, usa cookies de uma conta (YT_COOKIES_FILE). Vídeos
bloqueados pelo Modo Restrito da rede (DNS com "pesquisa segura", ex.:
AdGuard) não baixam por nenhum cliente: o log avisa.
"""
from __future__ import annotations

import asyncio
import logging
import re
import shutil
import unicodedata
from pathlib import Path

import yt_dlp
from yt_dlp.utils import DownloadError

from app.config import settings

logger = logging.getLogger("bergastream.downloads.youtube")
_CACHE_DIR = Path(settings.music_dir) / "cache"

_PENALTY_WORDS = ["live", "ao vivo", "cover", "remix", "karaoke", "slowed", "sped up",
                  "reverb", "instrumental", "acapella", "8d", "loop",
                  "trap remix", "bass boosted", "nightcore", "acustico", "acoustic"]

# Duração: até _FREE_S de diferença não pesa; depois perde pontos por segundo
# até o limite (o maior entre _MAX_S e _MAX_FRACTION da faixa). Clipes têm
# introduções; versões diferentes passam do limite.
_FREE_S = 3
_MAX_S = 20
_MAX_FRACTION = 0.10
_PENALTY_PER_S = 1.5

# Quantos candidatos tentar baixar antes de desistir.
MAX_ATTEMPTS = 3

def player_clients() -> list[list[str] | None]:
    """Clientes do yt-dlp a tentar, em ordem (None = o padrão dele).

    Com o gerador de PO Tokens, o `mweb` passa pelo "não sou um robô" com o
    áudio bom; sem ele o `mweb` só entrega o formato 18 (qualidade baixa) e o
    "embutido" vem antes. Começar pelo que funciona evita pedidos a mais, que
    fazem o YouTube limitar o servidor (HTTP 429)."""
    if settings.pot_provider_url:
        return [["mweb"], ["web_embedded"], None]
    return [["web_embedded"], ["mweb"], None]

class _YtLogger:
    """Mensagens do yt-dlp só no nível debug: os erros são registrados aqui
    mesmo, com o motivo em português (sem barras de progresso no log)."""

    def debug(self, msg: str) -> None:
        logger.debug("[yt-dlp] %s", msg)

    info = debug
    warning = debug
    error = debug


_YDL_DOWNLOAD_OPTS = {
    "format": "bestaudio/best",
    "quiet": True, "no_warnings": True, "noprogress": True, "logger": _YtLogger(),
    "overwrites": True, "noplaylist": True,
    "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}],
}


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ASCII", "ignore").decode("ASCII")
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9\s]", " ", text.lower())).strip()


def _words(s: str) -> set[str]:
    return set(_normalize(s).split())


_FEAT = re.compile(r"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with|part\.?|participacao)\b[^\)\]]*[\)\]]",
                   re.IGNORECASE)
_SUFFIX = re.compile(r"\s+-\s+(\d{4}\s+)?(remaster(ed)?|radio edit|single version|original mix)\b.*$",
                     re.IGNORECASE)


def clean_title(title: str) -> str:
    """Título sem "(feat. …)" e sem sufixos como "- Remastered 2011"."""
    cleaned = _SUFFIX.sub("", _FEAT.sub("", title)).strip()
    return cleaned or title


def main_artist(artist: str) -> str:
    """Primeiro artista ("Daft Punk, Pharrell Williams" → "Daft Punk")."""
    first = re.split(r",|&| feat\.? | ft\.? | e | x ", artist, maxsplit=1, flags=re.IGNORECASE)[0]
    return first.strip() or artist


def duration_penalty(duration: int, ref_duration: int) -> float | None:
    """Pontos a tirar pela diferença de duração; None = versão diferente."""
    if ref_duration <= 0:
        return 0.0
    if duration <= 0:
        return 10.0  # sem duração: aceita, mas prefere quem tem
    diff = abs(duration - ref_duration)
    if diff <= _FREE_S:
        return 0.0
    if diff > max(_MAX_S, ref_duration * _MAX_FRACTION):
        return None
    return (diff - _FREE_S) * _PENALTY_PER_S


def score_candidate(title: str, uploader: str, duration: int,
                    ref_title: str, ref_artist: str, ref_duration: int) -> float:
    penalty = duration_penalty(duration, ref_duration)
    if penalty is None:
        return -1.0
    score = 50.0 - penalty
    tn = _normalize(title)
    rtn = _normalize(clean_title(ref_title))
    ran = _normalize(ref_artist)
    tw = _words(tn)
    rw = _words(rtn)
    common = tw & rw
    if common:
        score += 20.0 * (len(common) / max(len(rw), 1))
    aw = _words(ran)
    if aw and (aw & tw):
        score += 15.0
    un = _normalize(uploader)
    main = _normalize(main_artist(ref_artist))
    if un and (main in un or un in ran):
        score += 10.0
    elif any(a in un for a in aw if len(a) > 2):
        score += 5.0
    for w in _PENALTY_WORDS:
        if re.search(rf"\b{w}\b", tn) and not re.search(rf"\b{w}\b", rtn):
            score -= 30.0
    if rtn and rtn in tn:
        score += 10.0
    if tn == rtn:
        score += 25.0
    return score


def _search_yt_sync(query: str, ref_title: str, ref_artist: str, ref_duration: int,
                    limit: int = 10) -> list[dict]:
    opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist",
            "ignoreerrors": True, "logger": _YtLogger()}
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch{limit}:{query}", download=False) or {}
    except Exception as exc:
        logger.warning("[yt] busca no YouTube falhou: %s", exc)
        return []
    found = []
    for entry in info.get("entries") or []:
        if not entry or not entry.get("id"):
            continue
        uploader = entry.get("channel") or entry.get("uploader") or ""
        duration = int(entry.get("duration") or 0)
        s = score_candidate(entry.get("title", ""), uploader, duration,
                            ref_title, ref_artist, ref_duration)
        if s > 0:
            found.append({"video_id": entry["id"], "title": entry.get("title", ""),
                          "uploader": uploader, "duration": duration, "score": s, "src": "yt"})
    return found


def _search_ytmusic_sync(query: str, ref_title: str, ref_artist: str, ref_duration: int,
                         limit: int = 8) -> list[dict]:
    """YouTube Music (músicas): áudio oficial, com duração."""
    try:
        from app.search.ytmusic import _yt
        results = _yt().search(query, filter="songs", limit=limit) or []
    except Exception as exc:
        logger.warning("[yt] busca no YouTube Music falhou: %s", exc)
        return []
    found = []
    for r in results:
        video_id = r.get("videoId")
        if not video_id:
            continue
        artists = ", ".join(a.get("name", "") for a in r.get("artists") or [])
        duration = int(r.get("duration_seconds") or 0)
        title = r.get("title", "")
        # O título do YT Music não traz o artista: compara com ele junto.
        s = score_candidate(f"{artists} {title}", artists, duration,
                            ref_title, ref_artist, ref_duration)
        if s > 0:
            # Áudio oficial do catálogo: preferido a clipes e uploads de fãs.
            found.append({"video_id": video_id, "title": f"{artists} - {title}",
                          "uploader": artists, "duration": duration,
                          "score": s + 10.0, "src": "ytmusic"})
    return found


def search_queries(title: str, artist: str) -> list[str]:
    base = clean_title(title)
    queries = [f"{main_artist(artist)} {base}", f"{artist} - {title}"]
    return list(dict.fromkeys(q.strip() for q in queries if q.strip()))


async def find_candidates(title: str, artist: str, duration: int, limit: int = MAX_ATTEMPTS) -> list[dict]:
    """Melhores candidatos (sem repetir vídeo), da maior nota para a menor."""
    best: dict[str, dict] = {}
    for q in search_queries(title, artist):
        for search in (_search_ytmusic_sync, _search_yt_sync):
            for c in await asyncio.to_thread(search, q, title, artist, duration):
                if c["video_id"] not in best or c["score"] > best[c["video_id"]]["score"]:
                    best[c["video_id"]] = c
    ranked = sorted(best.values(), key=lambda c: c["score"], reverse=True)[:limit]
    if ranked:
        for c in ranked:
            logger.info("[yt] candidato: %s (nota %.1f, %ds, %s)", c["title"], c["score"],
                        c["duration"], c["src"])
    else:
        logger.warning("[yt] nenhum candidato para %s - %s", artist, title)
    return ranked


async def find_best_candidate(title: str, artist: str, duration: int) -> dict | None:
    ranked = await find_candidates(title, artist, duration, limit=1)
    return ranked[0] if ranked else None


def _cookie_file() -> str | None:
    """Cookies de uma conta do YouTube (opcional). Copiados para /tmp: o
    yt-dlp regrava o arquivo e o original fica montado só para leitura."""
    source = settings.yt_cookies_file
    if not source or not Path(source).is_file():
        return None
    target = Path("/tmp/bergastream-yt-cookies.txt")
    try:
        if not target.exists() or target.stat().st_mtime < Path(source).stat().st_mtime:
            shutil.copyfile(source, target)
            target.chmod(0o600)
    except OSError as exc:
        logger.warning("[yt] não usou os cookies: %s", exc)
        return None
    return str(target)


def _is_restricted(message: str) -> bool:
    m = message.lower()
    return "restricted" in m and ("network administrator" in m or "workspace" in m)


async def download_video(video_id: str, output_dir: Path | None = None):
    """Baixa o áudio de [video_id]. Devolve (ok, caminho, formato)."""
    dest = output_dir or _CACHE_DIR
    dest.mkdir(parents=True, exist_ok=True)
    url = f"https://www.youtube.com/watch?v={video_id}"
    cookies = _cookie_file()
    for clients in player_clients():
        opts = dict(_YDL_DOWNLOAD_OPTS)
        opts["outtmpl"] = str(dest / "%(id)s.%(ext)s")
        extractor_args: dict = {}
        if clients:
            extractor_args["youtube"] = {"player_client": clients}
        if settings.pot_provider_url:
            extractor_args["youtubepot-bgutilhttp"] = {"base_url": [settings.pot_provider_url]}
        if extractor_args:
            opts["extractor_args"] = extractor_args
        if cookies:
            opts["cookiefile"] = cookies

        def _download_sync(opts=opts):
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.extract_info(url, download=True)

        try:
            # Em thread: o yt-dlp (download + ffmpeg) travava o loop do worker
            # e derrubava a conexão com o Redis.
            await asyncio.to_thread(_download_sync)
        except DownloadError as exc:
            message = str(exc)
            if _is_restricted(message):
                logger.error(
                    "[yt] %s bloqueado pelo Modo Restrito do YouTube imposto pela rede "
                    "(DNS com 'pesquisa segura', ex.: AdGuard). Libere o servidor nessa regra.",
                    video_id)
                return False, None, None
            if "video unavailable" in message.lower() or "private video" in message.lower():
                logger.warning("[yt] %s indisponível: %s", video_id, message.splitlines()[0][:160])
                return False, None, None
            logger.warning("[yt] %s falhou com o cliente %s: %s", video_id,
                           ",".join(clients or ["padrão"]), message.splitlines()[0][:160])
            continue
        except Exception as exc:
            logger.error("[yt] erro no download de %s: %s", video_id, exc)
            continue
        found = _downloaded(dest, video_id)
        if found:
            if clients:
                logger.info("[yt] %s baixado com o cliente %s", video_id, ",".join(clients))
            return found
    return False, None, None


def _downloaded(dest: Path, video_id: str):
    mp3 = dest / f"{video_id}.mp3"
    if mp3.exists():
        return True, mp3, "mp3_192"
    for f in dest.iterdir():
        if f.stem == video_id and f.suffix in (".mp3", ".m4a", ".webm", ".opus"):
            fmt = {".mp3": "mp3_192", ".m4a": "aac", ".webm": "opus", ".opus": "opus"}.get(f.suffix, "mp3_192")
            return True, f, fmt
    return None
