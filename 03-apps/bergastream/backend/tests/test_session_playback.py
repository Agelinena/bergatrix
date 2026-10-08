"""Regras da sessão compartilhada (sem banco nem rede).

Uso: docker compose exec -T api python tests/test_session_playback.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.sessions.playback import ActionError, Playback, apply

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def t(name, secs=200):
    return {"provider": "spotify", "external_id": name, "title": name, "artist": "A",
            "duration_seconds": secs}


def titles(pb):
    return [e.track.title for e in pb.queue]


pb = Playback()
print("=== tocar uma lista ===")
apply(pb, {"action": "play_list", "tracks": [t("A"), t("B"), t("C")], "index": 1}, 1000, "lucas")
ok((pb.current().track.title, pb.playing, pb.position_ms, pb.anchor_at, pb.version), ("B", True, 0, 1000, 1),
   "começa em B, tocando, âncora no agora")
ok(pb.position_at(4000), 3000, "posição corre com o relógio")

print("=== fila manual, como no modo normal ===")
apply(pb, {"action": "add", "track": t("D")}, 2000, "marina")
ok((titles(pb), pb.queue[2].added_by, pb.queue[2].manual), (["A", "B", "D", "C"], "marina", True),
   "adicionar entra logo depois da atual")
apply(pb, {"action": "add", "track": t("E")}, 2000, "lucas")
ok(titles(pb), ["A", "B", "D", "E", "C"], "fila manual em ordem de chegada, antes do resto da lista")
apply(pb, {"action": "add_next", "track": t("X")}, 2000, "marina")
ok(titles(pb), ["A", "B", "X", "D", "E", "C"], "tocar em seguida: topo da fila manual")
apply(pb, {"action": "move", "uid": pb.queue[4].uid, "to": 2}, 2000, "lucas")
ok(titles(pb), ["A", "B", "E", "X", "D", "C"], "reordenar dentro da fila manual")
apply(pb, {"action": "move", "uid": pb.queue[5].uid, "to": 2}, 2000, "lucas")
ok(titles(pb), ["A", "B", "E", "X", "D", "C"], "resto da lista não passa à frente da fila manual")
apply(pb, {"action": "clear_manual"}, 2000, "lucas")
ok(titles(pb), ["A", "B", "C"], "limpar a fila manual")

print("=== tocar outra lista preserva a fila manual ===")
other = Playback()
apply(other, {"action": "play_list", "tracks": [t("A"), t("B")], "index": 0}, 1000, "lucas")
apply(other, {"action": "add", "track": t("M")}, 1000, "marina")
apply(other, {"action": "play_list", "tracks": [t("X"), t("Y"), t("Z")], "index": 1}, 2000, "lucas")
ok((titles(other), other.current().track.title, [e.manual for e in other.queue]),
   (["X", "Y", "M", "Z"], "Y", [False, False, True, False]), "M toca logo depois de Y")

print("=== fila compartilhada ===")
apply(pb, {"action": "add", "track": t("D")}, 2000, "marina")
apply(pb, {"action": "add", "track": t("X")}, 2000, "marina")
ok(titles(pb), ["A", "B", "D", "X", "C"], "duas na fila manual")
try:
    apply(pb, {"action": "move", "uid": pb.queue[0].uid, "to": 3}, 2000, "lucas")
    ok(True, False, "não move as já tocadas")
except ActionError:
    ok(True, True, "não move as já tocadas")
apply(pb, {"action": "remove", "uid": pb.queue[0].uid}, 2000, "lucas")
ok((titles(pb), pb.current().track.title), (["B", "D", "X", "C"], "B"), "remover antes da atual mantém a atual")
try:
    apply(pb, {"action": "remove", "uid": pb.current().uid}, 2000, "lucas")
    ok(True, False, "não remove a atual")
except ActionError:
    ok(True, True, "não remove a atual")

print("=== pular, voltar, buscar ===")
apply(pb, {"action": "next"}, 5000, "lucas")
ok((pb.current().track.title, pb.position_at(5000)), ("D", 0), "próxima para todos")
apply(pb, {"action": "seek", "position_ms": 60000}, 6000, "marina")
ok(pb.position_at(7000), 61000, "buscar trecho")
apply(pb, {"action": "previous"}, 7000, "lucas")
ok((pb.current().track.title, pb.position_at(7000)), ("D", 0), "voltar com > 3 s recomeça a faixa")
apply(pb, {"action": "previous"}, 8000, "lucas")
ok(pb.current().track.title, "B", "voltar no começo vai para a anterior")
apply(pb, {"action": "jump", "uid": pb.queue[-1].uid}, 9000, "lucas")
ok(pb.current().track.title, "C", "tocar uma da fila")

print("=== fim da faixa (vários aparelhos avisam) ===")
uid_c = pb.current().uid
apply(pb, {"action": "add", "track": t("E")}, 9000, "lucas")
v = pb.version
ok(apply(pb, {"action": "ended", "uid": uid_c}, 10000, "lucas"), True, "primeiro aviso avança")
ok(apply(pb, {"action": "ended", "uid": uid_c}, 10050, "marina"), False, "segundo aviso é ignorado")
ok((pb.current().track.title, pb.version), ("E", v + 1), "só avançou uma vez")
apply(pb, {"action": "ended", "uid": pb.current().uid}, 11000, "lucas")
ok((pb.current().track.title, pb.playing), ("E", False), "fim da fila: para na última")

print("=== pausa ===")
apply(pb, {"action": "jump", "uid": pb.current().uid}, 12000, "lucas")
apply(pb, {"action": "pause"}, 15000, "marina")
ok((pb.playing, pb.position_at(99000)), (False, 3000), "pausa para todos: posição congela")
apply(pb, {"action": "resume"}, 20000, "lucas")
ok((pb.playing, pb.position_at(21000)), (True, 4000), "retoma de onde parou")
ok(apply(pb, {"action": "pause"}, 22000, "marina", pause_mode="individual"), False,
   "modo individual: o servidor não pausa ninguém")
ok(pb.playing, True, "continua tocando para os outros")

print("=== nada tocando ===")
empty = Playback()
apply(empty, {"action": "add", "track": t("Z")}, 1000, "lucas")
ok((empty.current().track.title, empty.playing), ("Z", True), "primeira adicionada começa a tocar")
try:
    apply(empty, {"action": "voar"}, 1000, "x")
    ok(True, False, "ação desconhecida")
except ActionError:
    ok(True, True, "ação desconhecida recusada")

print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
