"""Estado compartilhado da sessão e as ações sobre ele (sem banco nem rede).

A reprodução é uma fila única com a faixa atual em `index` (as anteriores
ficam para "voltar"). A posição é uma âncora: `position_ms` valia no
instante `anchor_at` (relógio do servidor, ms); tocando, a posição agora é
`position_ms + (agora - anchor_at)`. Cada aparelho calcula o mesmo valor e
toca o áudio por conta própria — só "o quê" e "de onde" são compartilhados.
"""
from __future__ import annotations

import secrets
from typing import Any

from pydantic import BaseModel, Field


class SessionTrack(BaseModel):
    """Mesmos campos de um SearchResult do app."""
    provider: str
    external_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    isrc: str | None = None
    cover_url: str | None = None
    artist_id: str | None = None
    album_id: str | None = None


class QueueEntry(BaseModel):
    uid: str
    track: SessionTrack
    added_by: str | None = None  # username


class Playback(BaseModel):
    queue: list[QueueEntry] = []
    index: int = -1             # faixa atual (-1: nada)
    playing: bool = False
    position_ms: int = 0
    anchor_at: int = 0          # ms (relógio do servidor)
    version: int = 0

    def current(self) -> QueueEntry | None:
        return self.queue[self.index] if 0 <= self.index < len(self.queue) else None

    def position_at(self, now_ms: int) -> int:
        if not self.playing:
            return self.position_ms
        return self.position_ms + max(0, now_ms - self.anchor_at)


class ActionError(ValueError):
    pass


MAX_QUEUE = 2000
PREVIOUS_RESTART_MS = 3000


def _uid() -> str:
    return secrets.token_hex(6)


def _entry(track: dict, by: str | None) -> QueueEntry:
    return QueueEntry(uid=_uid(), track=SessionTrack.model_validate(track), added_by=by)


def _index_of(pb: Playback, uid: Any) -> int:
    for i, e in enumerate(pb.queue):
        if e.uid == uid:
            return i
    raise ActionError("Música não está na fila")


def _start(pb: Playback, index: int, now: int, playing: bool = True) -> None:
    pb.index = index
    pb.position_ms = 0
    pb.anchor_at = now
    pb.playing = playing and pb.current() is not None


def apply(pb: Playback, action: dict, now: int, by: str | None,
          pause_mode: str = "all") -> bool:
    """Aplica [action] em [pb] (no lugar). Devolve se mudou algo.
    Lança [ActionError] para ação inválida."""
    kind = action.get("action")
    before = pb.model_dump()

    if kind == "play_list":
        tracks = action.get("tracks") or []
        if not tracks:
            raise ActionError("Lista vazia")
        index = int(action.get("index") or 0)
        if not 0 <= index < len(tracks):
            raise ActionError("Posição inválida")
        pb.queue = [_entry(t, by) for t in tracks[:MAX_QUEUE]]
        _start(pb, index, now)

    elif kind in ("add", "add_next"):
        if len(pb.queue) >= MAX_QUEUE:
            raise ActionError("Fila cheia")
        entry = _entry(action.get("track") or {}, by)
        if kind == "add_next" and pb.current() is not None:
            pb.queue.insert(pb.index + 1, entry)
        else:
            pb.queue.append(entry)
        if pb.current() is None:
            # Nada tocando: a primeira adicionada começa.
            _start(pb, len(pb.queue) - 1, now)

    elif kind == "remove":
        i = _index_of(pb, action.get("uid"))
        if i == pb.index:
            raise ActionError("Não dá para remover a que está tocando")
        pb.queue.pop(i)
        if i < pb.index:
            pb.index -= 1

    elif kind == "move":
        # Só entre as próximas (as já tocadas ficam onde estão).
        i = _index_of(pb, action.get("uid"))
        to = int(action.get("to", -1))
        if i <= pb.index or not pb.index < to < len(pb.queue):
            raise ActionError("Só dá para mover as próximas")
        pb.queue.insert(to, pb.queue.pop(i))

    elif kind == "jump":
        _start(pb, _index_of(pb, action.get("uid")), now, playing=True)

    elif kind == "next":
        if pb.index + 1 < len(pb.queue):
            _start(pb, pb.index + 1, now, playing=True)
        else:
            _start(pb, pb.index, now, playing=False)  # acabou a fila

    elif kind == "previous":
        if pb.position_at(now) > PREVIOUS_RESTART_MS or pb.index <= 0:
            pb.position_ms, pb.anchor_at = 0, now
        else:
            _start(pb, pb.index - 1, now, playing=pb.playing or True)

    elif kind == "ended":
        # Vários aparelhos avisam o fim da mesma faixa: só o primeiro conta.
        current = pb.current()
        if current is None or current.uid != action.get("uid"):
            return False
        if pb.index + 1 < len(pb.queue):
            _start(pb, pb.index + 1, now)
        else:
            _start(pb, pb.index, now, playing=False)

    elif kind == "seek":
        if pb.current() is None:
            raise ActionError("Nada tocando")
        pb.position_ms = max(0, int(action.get("position_ms") or 0))
        pb.anchor_at = now

    elif kind in ("pause", "resume"):
        if pause_mode == "individual":
            return False  # cada um pausa no próprio aparelho
        if pb.current() is None:
            return False
        if kind == "pause" and pb.playing:
            pb.position_ms, pb.anchor_at, pb.playing = pb.position_at(now), now, False
        elif kind == "resume" and not pb.playing:
            pb.anchor_at, pb.playing = now, True

    else:
        raise ActionError(f"Ação desconhecida: {kind}")

    changed = pb.model_dump() != before
    if changed:
        pb.version += 1
    return changed
