"""Normalização no servidor (?norm=): com áudio de verdade, gerado pelo ffmpeg.

Uso: docker compose exec -T api python tests/test_normalize.py
"""
from __future__ import annotations

import asyncio
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from app.downloads import audio_info, loudness, variants

P = F = 0


def ok(a, b, m=""):
    global P, F
    if a == b:
        P += 1
        print(f"  OK {m}")
    else:
        F += 1
        print(f"  FAIL {m}: {a!r} != {b!r}")


def tone(path: Path, volume_db: float, codec_args: list[str]) -> None:
    """20 s de ruído rosa com um tom por cima, em [volume_db] dB."""
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anoisesrc=c=pink:d=20:a=0.5",
         "-f", "lavfi", "-i", "sine=f=440:d=20",
         "-filter_complex", f"amix=inputs=2,volume={volume_db}dB", "-ac", "2", "-ar", "44100",
         *codec_args, str(path)], check=True)


def clicky(path: Path) -> None:
    """Música baixa com estalos fortes: subir o volume passaria do pico."""
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anoisesrc=c=pink:d=20:a=0.5",
         "-f", "lavfi", "-i", "aevalsrc=0.9*lt(mod(t\\,0.5)\\,0.003):d=20:s=44100",
         "-filter_complex", "[0]volume=-18dB[n];[n][1]amix=inputs=2:normalize=0",
         "-ac", "2", "-ar", "44100", "-c:a", "flac", str(path)], check=True)


def main():
    work = Path(tempfile.mkdtemp())
    variants.VARIANTS_DIR = work / "variants"
    try:
        print("=== cálculo do ganho ===")
        ok(variants.norm_gain(-20, -8, -10), (10.0, True), "baixa sobe 10 dB; pico passaria: limitador")
        ok(variants.norm_gain(-20, -15, -10), (10.0, False), "baixa sobe e o pico cabe: sem limitador")
        ok(variants.norm_gain(-30, -20, -10), (12.0, False), "sobe no máximo +12 dB")
        ok(variants.norm_gain(-6, -0.5, -10), (-4.0, False), "alta desce, sem limitador")

        async def run(master: Path, level: str, norm):
            info = audio_info.probe(master)
            loud = loudness.measure(master)
            return await variants.path_for(str(uuid.uuid4()), master, info, level,
                                           loudness=loud, norm=norm), loud

        print("=== música baixa em FLAC, alvo -10 ===")
        quiet = work / "baixa.flac"
        clicky(quiet)
        (path, delivery, normalized), before = asyncio.run(run(quiet, "original", -10))
        after = loudness.measure(path)
        print(f"    antes {before}, depois {after}, {delivery.label}")
        ok((normalized, path.suffix), (True, ".flac"), "sai normalizada e continua FLAC")
        # Os estalos dominam o volume medido; com eles limitados, o volume
        # sobe menos que o ganho. O que importa: subiu e o pico real ficou no teto.
        ok(after[0] > before[0], True, "subiu o volume")
        ok(after[1] <= variants.NORM_PEAK_DB, True, "pico real segurado pelo limitador (≤ -1,5 dBTP)")

        print("=== música baixa sem picos: sobe o ganho todo, sem limitador ===")
        soft = work / "suave.flac"
        tone(soft, 4, ["-c:a", "flac"])
        (path, delivery, normalized), before = asyncio.run(run(soft, "original", -14))
        after = loudness.measure(path)
        print(f"    antes {before}, depois {after}")
        ok(abs(after[0] - (-14)) <= 1.0, True, "chegou ao alvo")
        ok(after[1] <= variants.NORM_PEAK_DB, True, "sem passar do pico")

        print("=== música alta em MP3 no nível normal (AAC 160), alvo -14 ===")
        loud_mp3 = work / "alta.mp3"
        tone(loud_mp3, -2, ["-c:a", "libmp3lame", "-b:a", "320k"])
        (path, delivery, normalized), before = asyncio.run(run(loud_mp3, "normal", -14))
        after = loudness.measure(path)
        print(f"    antes {before}, depois {after}, {delivery.label}")
        ok((normalized, delivery.label), (True, "AAC 160"), "normalizada no formato do nível")
        ok(abs(after[0] - (-14)) <= 1.0, True, "desceu até o alvo")

        print("=== já no alvo: não converte ===")
        (path, delivery, normalized), _ = asyncio.run(run(path, "original", round(after[0])))
        ok((normalized, path.parent.name), (True, "variants"), "vale como normalizada")

        print("=== sem pedir norm: como antes ===")
        (path, delivery, normalized), _ = asyncio.run(run(quiet, "original", None))
        ok((normalized, path), (False, quiet), "o mestre como está")

        print("=== sem medição: não normaliza ===")

        async def unmeasured():
            return await variants.path_for(str(uuid.uuid4()), quiet, audio_info.probe(quiet),
                                           "original", loudness=None, norm=-10)
        path, _, normalized = asyncio.run(unmeasured())
        ok((normalized, path), (False, quiet), "o app ajusta no aparelho")
    finally:
        subprocess.run(["rm", "-rf", str(work)])
    print(f"\n{P}/{P + F} verificações passaram")
    sys.exit(1 if F else 0)


if __name__ == "__main__":
    main()
