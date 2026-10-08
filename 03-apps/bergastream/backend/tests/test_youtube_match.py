"""Escolha do vídeo no plano B do YouTube (sem rede).

Uso: docker compose exec -T api python tests/test_youtube_match.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.config import settings
from app.downloads.youtube import (_is_restricted, clean_title, duration_penalty, main_artist,
                                   player_clients, score_candidate, search_queries)

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


print("=== limpeza da busca ===")
ok(clean_title("Get Lucky (Radio Edit) [feat. Pharrell Williams and Nile Rodgers]"), "Get Lucky (Radio Edit)",
   "tira o feat.")
ok(clean_title("Help! - Remastered 2009"), "Help!", "tira o remaster")
ok(clean_title("Minha alma (A paz que eu não quero)"), "Minha alma (A paz que eu não quero)",
   "parênteses que fazem parte do nome ficam")
ok(main_artist("Daft Punk, Pharrell Williams, Nile Rodgers"), "Daft Punk", "primeiro artista")
ok(main_artist("Mc Daniel, DJ WN, Dj GM"), "Mc Daniel", "primeiro MC")
ok(search_queries("Vamo de Pagodin", "Mc Daniel, DJ WN, Dj GM"),
   ["Mc Daniel Vamo de Pagodin", "Mc Daniel, DJ WN, Dj GM - Vamo de Pagodin"], "buscas")

print("=== duração ===")
ok(duration_penalty(161, 160), 0.0, "1 s não pesa")
ok(duration_penalty(177, 168), 9.0, "clipe 9 s maior: aceito com desconto")
ok(duration_penalty(251, 247), 1.5, "4 s: quase nada")
ok(duration_penalty(271, 303), None, "32 s a menos: outra versão")
ok(duration_penalty(0, 200), 10.0, "sem duração: aceito com desconto")
ok(duration_penalty(200, 0), 0.0, "faixa sem duração: não filtra")

print("=== nota ===")
oficial = score_candidate("Vamo de Pagodin", "MC Daniel", 161, "Vamo de Pagodin", "Mc Daniel, DJ WN, Dj GM", 160)
clipe = score_candidate("VAMO DE PAGODIN - MC Daniel (Clipe Oficial) DJ WN e DJ GM", "Love Funk", 165,
                        "Vamo de Pagodin", "Mc Daniel, DJ WN, Dj GM", 160)
ao_vivo = score_candidate("Vamo de Pagodin (Ao Vivo)", "MC Daniel", 162, "Vamo de Pagodin", "Mc Daniel", 160)
ok(oficial > clipe > 0, True, "áudio oficial vence o clipe, que também vale")
ok(ao_vivo < oficial - 20, True, "ao vivo perde pontos")
bentivi = score_candidate("Bentivi • ÀVUÀ (Clipe Oficial)", "ÀVUÀ", 177, "Bentivi", "ÀVUÀ, Jota.pê, Bruna Black", 168)
ok(bentivi > 0, True, "Bentivi (clipe 9 s maior) agora é aceito")

print("=== erros ===")
ok(_is_restricted("ERROR: [youtube] x: Video unavailable. This video is restricted. Please check the "
                  "Google Workspace administrator and/or network administrator restrictions."), True,
   "Modo Restrito da rede reconhecido")
ok(_is_restricted("Sign in to confirm you're not a bot"), False, "bloqueio de robô é outro caso")

print("=== clientes do yt-dlp ===")
settings.pot_provider_url = "http://bergastream-pot:4416"
ok(player_clients()[0], ["mweb"], "com PO Token: mweb primeiro")
settings.pot_provider_url = ""
ok(player_clients()[0], ["web_embedded"], "sem PO Token: embutido primeiro")

print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
