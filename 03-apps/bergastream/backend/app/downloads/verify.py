"""Confere se cada arquivo baixado é da faixa a que está ligado (título nas
tags) e, com --fix, apaga os trocados para serem baixados de novo.

Uso (dentro do container da API ou do worker):
    python -m app.downloads.verify          # só relata
    python -m app.downloads.verify --fix    # apaga os trocados e os órfãos

Necessário depois do bug em que downloads simultâneos do Deemix trocavam
os arquivos entre faixas (corrigido em downloads/deemix.py).
"""
from __future__ import annotations

import argparse
import asyncio
import time
from pathlib import Path

from app.config import settings
from app.core.db import close_pool, create_pool
from app.downloads.tags import read_title, titles_match

_DEEMIX_DL = Path(settings.music_dir) / "deemix_dl"


async def main(fix: bool) -> None:
    pool = await create_pool()
    try:
        rows = await pool.fetch(
            """SELECT f.track_id, f.path, t.title, t.artist
               FROM files f JOIN tracks t ON t.id = f.track_id ORDER BY t.artist, t.title""")
        wrong, missing, unchecked = [], [], 0
        for r in rows:
            path = Path(r["path"])
            if not path.exists():
                missing.append(r)
                continue
            title = await asyncio.to_thread(read_title, path)
            if title is None:
                unchecked += 1
            elif not titles_match(r["title"], title):
                wrong.append((r, title))
        print(f"Arquivos: {len(rows)} | trocados: {len(wrong)} | sumidos: {len(missing)} | sem tag: {unchecked}")
        for r, title in wrong:
            print(f"  TROCADO  {r['artist']} - {r['title']}  →  arquivo tem {title!r}")
        for r in missing:
            print(f"  SUMIDO   {r['artist']} - {r['title']}")

        stray = [p for p in _DEEMIX_DL.glob("**/*")
                 if p.is_file() and time.time() - p.stat().st_mtime > 600]
        if stray:
            print(f"Órfãos na pasta do Deemix (mais de 10 min): {len(stray)}")

        if not fix:
            if wrong or missing or stray:
                print("Rode com --fix para corrigir.")
            return
        for r, _ in wrong:
            Path(r["path"]).unlink(missing_ok=True)
        for r in [*(w[0] for w in wrong), *missing]:
            await pool.execute("DELETE FROM files WHERE track_id = $1", r["track_id"])
        for p in stray:
            p.unlink(missing_ok=True)
        print(f"Corrigido: {len(wrong) + len(missing)} faixas voltam a ser baixadas no próximo play; "
              f"{len(stray)} órfãos apagados.")
    finally:
        await close_pool()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog="python -m app.downloads.verify")
    parser.add_argument("--fix", action="store_true")
    asyncio.run(main(parser.parse_args().fix))
