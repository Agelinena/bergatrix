#!/usr/bin/env python3
"""
Generate all BergaStream platform icon PNGs using Pillow only — no cairosvg /
libcairo native dependency. Works on Windows out of the box.

This reproduces the same icon that `lib/widgets/berga_logo.dart` renders
programmatically: a green (#1DB954) rounded square with 5 black equalizer
bars (heights 96, 176, 272, 176, 96 in a 512×512 master).

Usage (run from the `frontend/` directory):
    python scripts/generate_icons_pillow.py
    dart run flutter_launcher_icons
"""

import os
import sys
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT       = os.path.dirname(SCRIPT_DIR)   # frontend/
VENV_DIR   = os.path.join(SCRIPT_DIR, ".venv")
VENV_PY    = os.path.join(VENV_DIR, "Scripts" if sys.platform == "win32" else "bin",
                          "python.exe" if sys.platform == "win32" else "python3")


# ── Bootstrap: re-launch inside venv if needed ───────────────────────────────

def _in_venv() -> bool:
    return (
        sys.prefix != sys.base_prefix
        or os.environ.get("VIRTUAL_ENV") is not None
        or hasattr(sys, "real_prefix")
    )


def _try_import() -> bool:
    try:
        from PIL import Image  # noqa: F401
        return True
    except ImportError:
        return False


def _bootstrap():
    print("[icons] Creating local venv in scripts/.venv …")
    if not os.path.isdir(VENV_DIR):
        subprocess.check_call([sys.executable, "-m", "venv", VENV_DIR])
    subprocess.check_call([VENV_PY, "-m", "pip", "install", "--quiet", "--upgrade", "pip"])
    subprocess.check_call([VENV_PY, "-m", "pip", "install", "--quiet", "pillow"])
    os.execv(VENV_PY, [VENV_PY] + sys.argv)


if not _try_import():
    if os.path.isfile(VENV_PY):
        os.execv(VENV_PY, [VENV_PY] + sys.argv)
    else:
        _bootstrap()
    sys.exit(0)


# ── Main generation (runs inside venv with Pillow available) ─────────────────

from PIL import Image, ImageDraw

IMG_DIR  = os.path.join(ROOT, "assets", "images")
WEB_DIR  = os.path.join(ROOT, "web", "icons")
os.makedirs(IMG_DIR, exist_ok=True)
os.makedirs(WEB_DIR, exist_ok=True)

GREEN = (29, 185, 84, 255)  # #1DB954
BLACK = (0, 0, 0, 255)


def _draw_pill(draw: ImageDraw.ImageDraw, x: int, y: int, w: int, h: int, fill):
    """Pill (rounded rectangle with radius = w/2)."""
    radius = min(w // 2, h // 2)
    # Pillow ≥ 8.2 has rounded_rectangle natively.
    draw.rounded_rectangle((x, y, x + w, y + h), radius=radius, fill=fill)


def render_icon(size: int, *, transparent_bg: bool = False) -> Image.Image:
    """
    Render the BergaStream icon at the requested size.

    `transparent_bg=True` skips the green rounded square so the result is
    suitable as an Android adaptive-icon foreground layer (the system
    composites it over the platform's adaptive background).
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Master geometry is 512×512; scale to the actual size.
    sc = size / 512.0

    if not transparent_bg:
        # Background rounded square (radius ≈ 0.219 × side)
        bg_radius = int(0.219 * size)
        draw.rounded_rectangle((0, 0, size, size), radius=bg_radius, fill=GREEN)

    # Equalizer bars: 5 bars, heights [96, 176, 272, 176, 96] at master scale.
    start_x = 116
    bar_w   = 40
    gap     = 20
    centre_y = 256
    heights = [96, 176, 272, 176, 96]

    for i, h in enumerate(heights):
        x = int((start_x + i * (bar_w + gap)) * sc)
        w = int(bar_w * sc)
        bh = int(h * sc)
        y = int((centre_y - h / 2) * sc)
        _draw_pill(draw, x, y, w, bh, BLACK)

    return img


def save(img: Image.Image, path: str):
    img.save(path, "PNG")
    print(f"  OK{os.path.relpath(path, ROOT)}")


def make_maskable(img: Image.Image, size: int) -> Image.Image:
    """PWA maskable: icon at 72% on a green background."""
    icon_size = int(size * 0.72)
    icon = img.resize((icon_size, icon_size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), GREEN)
    off = (size - icon_size) // 2
    canvas.paste(icon, (off, off), icon)
    return canvas


print("\n==  BergaStream icon generator (Pillow)  ==\n")

# Source for flutter_launcher_icons.
img1024 = render_icon(1024)
save(img1024, os.path.join(IMG_DIR, "icon_1024.png"))

# Android adaptive-foreground: icon-only (no background), centred at 66%
# to stay inside the system's safe zone.
fg_size = 1024
inner_size = int(fg_size * 0.66)
fg_canvas = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
inner = render_icon(inner_size, transparent_bg=True)
off = (fg_size - inner_size) // 2
fg_canvas.paste(inner, (off, off), inner)
save(fg_canvas, os.path.join(IMG_DIR, "icon_adaptive_fg.png"))

# Web PWA icons.
for sz in (192, 512):
    base = render_icon(sz)
    save(base, os.path.join(WEB_DIR, f"Icon-{sz}.png"))
    save(make_maskable(base, sz), os.path.join(WEB_DIR, f"Icon-maskable-{sz}.png"))

# Windows ICO (multi-size).
sizes_ico = [16, 24, 32, 48, 64, 128, 256]
ico_frames = [render_icon(s) for s in sizes_ico]
ico_target = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
if os.path.isdir(os.path.dirname(ico_target)):
    ico_frames[0].save(ico_target, format="ICO",
                       sizes=[(s, s) for s in sizes_ico],
                       append_images=ico_frames[1:])
    print(f"  OK{os.path.relpath(ico_target, ROOT)}")
else:
    ico_frames[0].save(os.path.join(IMG_DIR, "icon.ico"), format="ICO",
                       sizes=[(s, s) for s in sizes_ico],
                       append_images=ico_frames[1:])
    print(f"  OKassets/images/icon.ico (windows/ runner folder not found)")

# Linux PNG.
linux_runner = os.path.join(ROOT, "linux", "runner")
if os.path.isdir(linux_runner):
    save(render_icon(256), os.path.join(linux_runner, "my_application.png"))

print("\n[OK] Done! Next:\n")
print("    dart run flutter_launcher_icons\n")
