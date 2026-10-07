"""Testes do proxy de imagens (Passo 12).

Uso: docker compose exec -T api python tests/test_images.py
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import httpx

from app.images.routes import allowed
from app.main import app

P = F = 0


def ok(a, b, m):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


print("=== hosts permitidos ===")
ok(allowed("https://i.scdn.co/image/abc"), True, "Spotify")
ok(allowed("https://lh3.googleusercontent.com/x=w544-h544"), True, "YT Music")
ok(allowed("https://i.ytimg.com/vi/x/hq.jpg"), True, "YouTube")
ok(allowed("https://cdn-images.dzcdn.net/images/cover/x.jpg"), True, "Deezer")
ok(allowed("http://i.scdn.co/image/abc"), False, "só https")
ok(allowed("https://evil.com/i.scdn.co"), False, "host de fora")
ok(allowed("https://i.scdn.co.evil.com/x"), False, "sufixo enganoso")
ok(allowed("https://169.254.169.254/latest"), False, "IP interno")


async def live():
    print("=== busca e cache (rede) ===")
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        url = "https://i.scdn.co/image/ab67616d0000b273fdab4a163ab9f6db72c952ee"
        r = await c.get("/api/images", params={"url": url})
        ok((r.status_code, r.headers.get("content-type")), (200, "image/jpeg"), "serve a capa")
        ok("max-age" in (r.headers.get("cache-control") or ""), True, "com cache")
        r2 = await c.get("/api/images", params={"url": url})
        ok(r2.content == r.content, True, "segunda vez vem do disco")
        r = await c.get("/api/images", params={"url": "https://example.com/x.jpg"})
        ok(r.status_code, 400, "origem fora da lista: 400")

asyncio.run(live())
print(f"\n{P}/{P + F} verificações passaram")
sys.exit(1 if F else 0)
