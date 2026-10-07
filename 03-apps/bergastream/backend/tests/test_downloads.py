"""Testes da escolha do arquivo do Deemix e da conferência de tags (sem rede).

Uso: docker compose exec -T api python tests/test_downloads.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.downloads import deemix
from app.downloads.tags import normalize_title, titles_match

P = F = 0


def ok(a, b, m):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def item(id_, status, files=None, errors=None):
    return {"id": id_, "status": status, "files": files or [], "errors": errors or []}


print("=== arquivo vem do item da faixa, não do mais novo da pasta ===")
queue = {
    "track_1_1": item("1", "completed", [{"data": {"id": "1"}, "path": "/downloads//Queen - Death On Two Legs.mp3"}]),
    "track_2_1": item("2", "completed", [{"data": {"id": "2"}, "path": "/downloads//Queen - Lazing On A Sunday Afternoon.mp3"}]),
    "track_3_1": item("3", "downloading"),
    "track_4_1": item("4", "failed", errors=[{"message": "Cannot read properties of undefined (reading 'HREF')"}]),
}
state, path = deemix.queue_state(queue, "2")
ok((state, path.name), ("concluido", "Queen - Lazing On A Sunday Afternoon.mp3"), "faixa 2 recebe o arquivo dela")
state, path = deemix.queue_state(queue, "1")
ok(path.name, "Queen - Death On Two Legs.mp3", "faixa 1 recebe o arquivo dela (mesmo com a 2 concluída depois)")
ok(str(path).startswith(str(deemix._DEEMIX_DL_DIR)), True, "caminho mapeado para o volume do worker")
ok(deemix.queue_state(queue, "3"), ("baixando", None), "em andamento")
ok(deemix.queue_state(queue, "4")[0], "falhou", "falha do Deemix")
ok(deemix.queue_state(queue, "9"), ("ausente", None), "não está na fila")
other = {"track_5_1": item("5", "completed", [{"data": {"id": "6"}, "path": "/downloads/x.mp3"}])}
ok(deemix.queue_state(other, "5")[0], "falhou", "item concluído com arquivo de outra faixa é recusado")
as_text = {"track_7_1": item("7", "completed", str([{"data": {"id": "7"}, "path": "/downloads/a/b.mp3"}]))}
ok(deemix.queue_state(as_text, "7")[1].relative_to(deemix._DEEMIX_DL_DIR).as_posix(), "a/b.mp3", "files em texto e subpasta")

print("=== conferência de título ===")
ok(normalize_title("Bohemian Rhapsody (Remastered 2011)"), "bohemianrhapsody", "tira parênteses")
ok(titles_match("Bohemian Rhapsody", "Bohemian Rhapsody - Remastered 2011"), True, "sufixo depois de ' - '")
ok(titles_match("Ação", "Acao"), True, "acentos")
ok(titles_match("Lazing On A Sunday Afternoon", "Death On Two Legs (Dedicated To...)"), False, "título trocado é detectado")
ok(titles_match("Get Lucky", "Get Lucky (feat. Pharrell Williams)"), True, "participação")

print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
