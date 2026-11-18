"""Monta uma leva da rádio.

Sementes: a música que começou a rádio (âncora, metade do peso) e até duas
recentes que a pessoa ouviu sem pular (o resto do peso). A âncora segura o
tema; as recentes trazem novidade. Toda candidata é medida contra esse
perfil, e não só contra a música que está tocando, para a rádio não ir
derivando (SOAD -> nu metal -> rap metal -> rap).

Para cada semente, as fontes rodam em paralelo (cada uma com prazo). As
candidatas ganham pontos quando:
- aparecem em mais de uma fonte (o que mais pesa);
- o artista é dado como parecido por alguma fonte de artistas (Last.fm,
  Deezer, ListenBrainz) ou é o artista de uma semente;
- as tags do artista (Last.fm) batem com as do perfil.
Candidata cujo artista nenhuma fonte valida (e que só uma fonte sugeriu)
fica de fora, assim como versões ao vivo/karaokê/remix/cover (a não ser que
a âncora seja uma delas) e o que a pessoa já ouviu.
"""
from __future__ import annotations

import asyncio
import logging
import random
from dataclasses import dataclass, field

from app.config import settings
from app.core.db import get_pool
from app.radio import guard, match, sources
from app.search.models import SearchResult

logger = logging.getLogger("bergastream.radio")

# Sorteio da ordem (os testes trocam por um com semente fixa).
_rng = random.Random()

DAY = 24 * 3600
WEEK = 7 * DAY


@dataclass
class Candidate:
    artist: str
    title: str
    track: dict | None = None          # SearchResult pronto para tocar
    duration: int = 0
    track_sources: set[str] = field(default_factory=set)
    score: float = 0.0

    @property
    def artist_key(self) -> str:
        return match.norm_artist(self.artist)


@dataclass
class Batch:
    tracks: list[SearchResult]
    sources: dict[str, str]           # fonte -> "ok" | "fora" | "erro" | "sem chave"


async def _source(status: dict, name: str, cache_key: str, ttl: int, fn) -> dict | list | None:
    """Uma fonte para uma semente: cache, uma chamada só, prazo e disjuntor."""
    src = guard.SOURCES[name]
    if name == "lastfm" and not settings.lastfm_api_key:
        status.setdefault(name, "sem chave")
        return None
    if src.is_open:
        status.setdefault(name, "fora")
        return None
    try:
        value = await guard.cached(cache_key, ttl, lambda: src.call(fn))
        status[name] = "ok"
        return value
    except guard.SourceDown:
        status.setdefault(name, "fora")
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        status.setdefault(name, "erro")
        logger.info("[rádio] %s falhou (%s): %s", name, cache_key, exc)
    return None


async def _seed_data(seed: SearchResult, status: dict) -> dict:
    """Tudo que as fontes dizem sobre uma semente."""
    skey = match.key(seed.artist, seed.title)
    akey = match.norm_artist(seed.artist)
    yt, lf_tracks, lf_artist, dz = await asyncio.gather(
        _source(status, "ytmusic", f"radio:yt:{skey}", DAY, lambda: sources.ytmusic_radio(seed)),
        _source(status, "lastfm", f"radio:lft:{skey}", WEEK,
                lambda: sources.lastfm_similar_tracks(seed.artist, seed.title)),
        _source(status, "lastfm", f"radio:lfa:{akey}", WEEK, lambda: sources.lastfm_artist(seed.artist)),
        _source(status, "deezer", f"radio:dz:{akey}", DAY, lambda: sources.deezer_radio(seed)),
    )
    lb = None
    mbid = (lf_artist or {}).get("mbid")
    if mbid:
        lb = await _source(status, "listenbrainz", f"radio:lb:{mbid}", WEEK,
                           lambda: sources.listenbrainz_similar(mbid))
    return {"yt": yt, "lf_tracks": lf_tracks, "lf_artist": lf_artist, "dz": dz, "lb": lb}


async def _recent_history(user_id: str, limit: int = 50) -> set[str]:
    rows = await get_pool().fetch(
        """SELECT t.artist, t.title FROM play_history h JOIN tracks t ON t.id = h.track_id
           WHERE h.user_id = $1 ORDER BY h.played_at DESC LIMIT $2""", user_id, limit)
    return {match.key(r["artist"], r["title"]) for r in rows}


async def _cached_tags(artist_keys: list[str]) -> dict[str, list[str]]:
    from app.core.redis import get_redis
    import json
    if not artist_keys:
        return {}
    redis = await get_redis()
    raws = await redis.mget([f"radio:tags:{a}" for a in artist_keys])
    return {a: json.loads(r) for a, r in zip(artist_keys, raws) if r is not None}


async def _warm_tags(artists: dict[str, str]) -> None:
    """Busca, sem segurar a resposta, as tags dos artistas que ainda não têm
    (a próxima leva já filtra por elas)."""
    if not settings.lastfm_api_key:
        return
    for akey, name in artists.items():
        try:
            await guard.cached(f"radio:tags:{akey}", 30 * DAY,
                               lambda name=name: guard.SOURCES["lastfm"].call(
                                   lambda: sources.lastfm_tags(name)))
        except Exception:
            return  # fonte fora: tenta numa próxima leva


_background: set[asyncio.Task] = set()


def _spawn(coro) -> None:
    task = asyncio.ensure_future(coro)
    _background.add(task)
    task.add_done_callback(_background.discard)


def _tag_affinity(profile: dict[str, float], tags: list[str] | None) -> float | None:
    """Quanto as tags do artista batem com o perfil (0..1); None = sem tags."""
    if not tags or not profile:
        return None
    total = sum(profile.values()) or 1
    return sum(profile.get(t, 0) for t in tags) / total


def _spread(cands: list[Candidate], last_artist: str | None) -> list[Candidate]:
    """Sorteia a ordem: quem tem mais pontos tende a vir antes, mas não é uma
    lista fixa. Cada música a mais de um artista na leva pesa menos (o
    artista com muitas músicas aparece espalhado, sem padrão), nunca o mesmo
    artista seguido, e a distância até ele voltar também é sorteada."""
    out: list[Candidate] = []
    pending = list(cands)
    used: dict[str, int] = {}
    recent: list[str] = [match.norm_artist(last_artist)] if last_artist else []
    while pending:
        gap = _rng.choice((1, 2, 2, 3, 4))
        blocked = set(recent[-gap:])
        options = [c for c in pending if c.artist_key not in blocked]
        if not options:
            options = [c for c in pending if not recent or c.artist_key != recent[-1]]
        if not options:  # só sobrou o mesmo artista: deixa para a próxima leva
            break
        weights = [max(c.score, 0.05) * (0.6 ** used.get(c.artist_key, 0)) for c in options]
        pick = _rng.choices(options, weights=weights)[0]
        out.append(pick)
        pending.remove(pick)
        used[pick.artist_key] = used.get(pick.artist_key, 0) + 1
        recent.append(pick.artist_key)
    return out


async def build(user_id: str, seed: SearchResult, recent: list[SearchResult],
                skipped: dict[str, int], exclude: set[str], last_artist: str | None,
                count: int) -> Batch:
    status: dict[str, str] = {}
    seeds = [(seed, 1.0)] if not recent else [(seed, 0.5)] + [(r, 0.5 / len(recent)) for r in recent[:2]]
    data = await asyncio.gather(*(_seed_data(s, status) for s, _ in seeds))
    seen = exclude | await _recent_history(user_id)
    seen |= {match.key(s.artist, s.title) for s, _ in seeds}

    pool: dict[str, Candidate] = {}
    artist_votes: dict[str, float] = {}
    artist_names: dict[str, str] = {}
    profile_tags: dict[str, float] = {}
    artist_source_ok = False

    def vote(name: str, value: float) -> None:
        a = match.norm_artist(name)
        if a:
            artist_votes[a] = artist_votes.get(a, 0) + value
            artist_names.setdefault(a, name)

    def add(artist: str, title: str, src: str, value: float, track: dict | None = None,
            duration: int = 0) -> None:
        k = match.key(artist, title)
        if not k or k.endswith("|"):
            return
        c = pool.get(k)
        if c is None:
            c = pool[k] = Candidate(artist=artist, title=title, duration=duration)
        c.track_sources.add(src)
        c.score += value
        # A mesma música em outra versão (remaster, ao vivo...) cai na mesma
        # chave e conta como uma só; fica a versão normal, se alguma fonte a
        # trouxer.
        if track and (c.track is None or match.plainness(title, track.get("album", ""))
                      < match.plainness(c.title, c.track.get("album", ""))):
            c.track = track
            c.title = title

    for (s, w), d in zip(seeds, data):
        vote(s.artist, w * 1.0)
        yt = (d["yt"] or {}).get("tracks") or []
        for rank, t in enumerate(yt):
            add(t["artist"], t["title"], "ytmusic", w * (1.5 - rank / max(len(yt), 1)), track=t)
        for t in (d["lf_tracks"] or {}).get("tracks") or []:
            add(t["artist"], t["title"], "lastfm", w * (0.5 + t["match"]), duration=t.get("duration") or 0)
        for t in (d["dz"] or {}).get("tracks") or []:
            add(t["artist"], t["title"], "deezer", w * 0.8, track=t)
        if d["lf_artist"]:
            artist_source_ok = True
            for a in d["lf_artist"]["artists"]:
                vote(a["name"], w * a["match"])
            for i, tag in enumerate(d["lf_artist"]["tags"]):
                profile_tags[tag] = profile_tags.get(tag, 0) + w * (1 - i / 20)
        if d["dz"] and d["dz"].get("artists"):
            artist_source_ok = True
            for i, name in enumerate(d["dz"]["artists"]):
                vote(name, w * (0.7 - i / 100))
        if d["lb"]:
            artist_source_ok = True
            for a in d["lb"]["artists"]:
                vote(a["name"], w * 0.7 * a["match"])

    anchor_versions = match.versions(seed.title, seed.album)
    skipped_keys: dict[str, int] = {}
    for name, n in skipped.items():
        k = match.norm_artist(name)
        skipped_keys[k] = skipped_keys.get(k, 0) + n

    tags = await _cached_tags(list({c.artist_key for c in pool.values()}))
    missing_tags: dict[str, str] = {}
    chosen: list[Candidate] = []
    for k, c in pool.items():
        if k in seen:
            continue
        info = c.track or {}
        if match.versions(c.title, info.get("album", "")) - anchor_versions:
            continue
        if skipped_keys.get(c.artist_key, 0) >= 2:
            continue
        votes = artist_votes.get(c.artist_key, 0)
        # Sem confirmação de nenhuma fonte de artistas e só uma fonte sugeriu:
        # é o "estranho" que entra numa rádio sem ter nada a ver.
        if artist_source_ok and votes <= 0 and len(c.track_sources) < 2:
            continue
        affinity = _tag_affinity(profile_tags, tags.get(c.artist_key))
        if affinity is None and c.artist_key not in tags:
            missing_tags[c.artist_key] = c.artist
        if affinity is not None and affinity == 0 and len(c.track_sources) < 2:
            continue  # gênero nada a ver com o perfil
        c.score += 2.5 * (len(c.track_sources) - 1)
        c.score += 1.5 * min(votes, 1.5)
        if affinity is not None:
            c.score += 2.0 * affinity
        c.score -= 1.5 * skipped_keys.get(c.artist_key, 0)
        chosen.append(c)

    chosen.sort(key=lambda c: c.score, reverse=True)
    if missing_tags:
        _spawn(_warm_tags(dict(list(missing_tags.items())[:12])))

    ordered = _spread(chosen[: count * 3], last_artist)
    tracks = await _resolve(ordered, count, status)
    logger.info("[rádio] %s: %d candidatas, %d na leva, fontes %s",
                seed.title, len(pool), len(tracks), status)
    return Batch(tracks=tracks, sources=status)


async def _resolve(ordered: list[Candidate], count: int, status: dict) -> list[SearchResult]:
    """As primeiras [count] tocáveis. As que vieram só com nome (Last.fm) são
    procuradas no YT Music, uma de cada vez e só as que vão entrar."""
    out: list[SearchResult] = []
    prev = None
    for c in ordered:
        if len(out) >= count:
            break
        track = c.track
        if track is None:
            try:
                track = await guard.cached(
                    f"radio:res:{match.key(c.artist, c.title)}", WEEK,
                    lambda c=c: guard.SOURCES["ytmusic"].call(
                        lambda: sources.resolve(c.artist, c.title, c.duration) or {}))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.info("[rádio] não achou %s - %s: %s", c.artist, c.title, exc)
                track = None
        if not track:
            continue
        if prev == c.artist_key:  # a que ficaria no meio sumiu: não juntar o mesmo artista
            continue
        out.append(SearchResult(**track))
        prev = c.artist_key
    return out
