"""Testes do reconhecimento de links (sem rede).

Uso: docker compose exec -T api python tests/test_resolve.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.search.resolve import ParsedLink, parse_link

CASES = [
    ("https://open.spotify.com/track/2JiDi0qAXsPwhPqA2qaKGt?si=abc", ParsedLink("spotify", "track", "2JiDi0qAXsPwhPqA2qaKGt")),
    ("https://open.spotify.com/intl-pt/album/1GbtB4zTqAsyfZEsm1RZfx", ParsedLink("spotify", "album", "1GbtB4zTqAsyfZEsm1RZfx")),
    ("open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M", ParsedLink("spotify", "playlist", "37i9dQZF1DXcBWIGoYBM5M")),
    ("spotify:track:2JiDi0qAXsPwhPqA2qaKGt", ParsedLink("spotify", "track", "2JiDi0qAXsPwhPqA2qaKGt")),
    ("https://www.deezer.com/br/track/3541552051", ParsedLink("deezer", "track", "3541552051")),
    ("https://www.deezer.com/album/12047952", ParsedLink("deezer", "album", "12047952")),
    ("https://deezer.com/playlist/908622995", ParsedLink("deezer", "playlist", "908622995")),
    ("https://www.youtube.com/watch?v=fJ9rUzIMcZQ&list=RDfJ9", ParsedLink("youtube", "track", "fJ9rUzIMcZQ")),
    ("https://youtu.be/fJ9rUzIMcZQ?t=10", ParsedLink("youtube", "track", "fJ9rUzIMcZQ")),
    ("https://m.youtube.com/shorts/fJ9rUzIMcZQ", ParsedLink("youtube", "track", "fJ9rUzIMcZQ")),
    ("https://music.youtube.com/watch?v=BSTsnWoslP4", ParsedLink("youtube", "track", "BSTsnWoslP4", True)),
    ("https://www.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG", ParsedLink("youtube", "playlist", "PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG")),
    ("https://music.youtube.com/browse/MPREb_eEpQf8QskKl", ParsedLink("youtube", "album", "MPREb_eEpQf8QskKl", True)),
    ("https://open.spotify.com/artist/1dfeR4HaWDbWqFHLkxsg1d", None),
    ("https://www.youtube.com/watch?v=curto", None),
    ("https://example.com/track/123", None),
    ("não é link", None),
]

failures = 0
for url, expected in CASES:
    got = parse_link(url)
    if got == expected:
        print(f"  OK {url}")
    else:
        failures += 1
        print(f"  FAIL {url}: {got} != {expected}")
print(f"\n{len(CASES) - failures}/{len(CASES)} verificações passaram")
sys.exit(1 if failures else 0)
