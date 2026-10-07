"""Gera os ícones do Bergastream (Android, web, Windows e Linux).

Desenho: quadrado com o gradiente de 135° das capas de playlist (Seção 5.3,
laranja HSL(24, 85%, 50%) → verde HSL(140, 60%, 28%)) e um "B" branco na
Bricolage Grotesque ExtraBold.

Uso (na pasta frontend/, precisa de Pillow):
    docker run --rm -v "$PWD:/app" -w /app python:3.12-slim \
        sh -c "pip install -q pillow && python tool/make_icons.py"
"""

import colorsys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "assets/fonts/BricolageGrotesque-ExtraBold.ttf"
RES = ROOT / "android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def hsl(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h / 360, l, s)
    return round(r * 255), round(g * 255), round(b * 255)


START = hsl(24, 0.85, 0.50)
END = hsl(140, 0.60, 0.28)


def gradient(size):
    """Gradiente diagonal (canto superior esquerdo → inferior direito)."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(START, END))
    return img


def letter(size, scale, color=(255, 255, 255, 255), shadow=True):
    """"B" centrado numa camada transparente; [scale] = altura da letra / lado."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    font = ImageFont.truetype(str(FONT), round(size * scale / 0.72))
    draw = ImageDraw.Draw(layer)
    box = draw.textbbox((0, 0), "B", font=font)
    x = (size - (box[2] - box[0])) / 2 - box[0]
    y = (size - (box[3] - box[1])) / 2 - box[1]
    if shadow:
        draw.text((x, y + size * 0.012), "B", font=font, fill=(0, 0, 0, 70))
    draw.text((x, y), "B", font=font, fill=color)
    return layer


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, img.size[0] - 1, img.size[1] - 1), radius=radius, fill=255
    )
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def full_icon(size, radius_ratio=0.22, scale=0.5):
    base = gradient(size).convert("RGBA")
    base.alpha_composite(letter(size, scale))
    return rounded(base, round(size * radius_ratio)) if radius_ratio else base


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print("gerado", path.relative_to(ROOT))


def android():
    for name, d in DENSITIES.items():
        # Ícone clássico (Android < 8) de 48 dp.
        save(full_icon(round(48 * d), 0.2), RES / f"mipmap-{name}/ic_launcher.png")
        # Ícone adaptativo: camadas de 108 dp, letra dentro da zona segura de 66 dp.
        side = round(108 * d)
        save(gradient(side), RES / f"mipmap-{name}/ic_launcher_background.png")
        save(letter(side, 0.30), RES / f"mipmap-{name}/ic_launcher_foreground.png")
        save(
            letter(side, 0.30, shadow=False),
            RES / f"mipmap-{name}/ic_launcher_monochrome.png",
        )
        # Ícone pequeno da notificação (24 dp, branco sobre transparente).
        save(
            letter(round(24 * d), 0.72, shadow=False),
            RES / f"drawable-{name}/ic_stat_bergastream.png",
        )
    xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""
    path = RES / "mipmap-anydpi-v26/ic_launcher.xml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(xml)
    print("gerado", path.relative_to(ROOT))


def web():
    save(full_icon(32, 0.2), ROOT / "web/favicon.png")
    for size in (192, 512):
        save(full_icon(size, 0.2), ROOT / f"web/icons/Icon-{size}.png")
        # Maskable: sem cantos e com a letra dentro da zona segura (80%).
        save(full_icon(size, 0, 0.36), ROOT / f"web/icons/Icon-maskable-{size}.png")


def desktop():
    big = full_icon(256, 0.2)
    ico = ROOT / "windows/runner/resources/app_icon.ico"
    if ico.parent.exists():
        big.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
        print("gerado", ico.relative_to(ROOT))
    save(full_icon(512, 0.2), ROOT / "linux/runner/resources/app_icon.png")


if __name__ == "__main__":
    android()
    web()
    desktop()
