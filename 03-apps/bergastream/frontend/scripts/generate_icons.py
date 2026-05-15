#!/usr/bin/env python3
"""
Generate all BergaStream platform icon PNGs from the SVG source.

Requirements:
    pip install cairosvg pillow

Usage (run from the `frontend/` directory):
    python scripts/generate_icons.py
    dart run flutter_launcher_icons
"""

import os
import sys
import shutil
import subprocess

try:
    import cairosvg
    from PIL import Image
    import io
except ImportError:
    print("[ERROR] Missing dependencies. Install with:")
    print("        pip install cairosvg pillow")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)        # frontend/
SVG_PATH = os.path.join(ROOT, "assets", "images", "logo.svg")
IMG_DIR  = os.path.join(ROOT, "assets", "images")
WEB_DIR  = os.path.join(ROOT, "web", "icons")

os.makedirs(IMG_DIR, exist_ok=True)
os.makedirs(WEB_DIR, exist_ok=True)


def svg_to_png(svg_path: str, size: int) -> Image.Image:
    """Render SVG at `size`×`size` and return a Pillow Image."""
    png_bytes = cairosvg.svg2png(
        url=svg_path,
        output_width=size,
        output_height=size,
    )
    return Image.open(io.BytesIO(png_bytes)).convert("RGBA")


def save(img: Image.Image, path: str):
    img.save(path, "PNG")
    print(f"  ✓  {os.path.relpath(path, ROOT)}")


def make_maskable(img: Image.Image, size: int) -> Image.Image:
    """
    Android maskable icon: the safe zone is the inner 72% of the canvas.
    We add green padding so the icon fills 80% of the canvas (safe for all
    mask shapes — circle, squircle, rounded square, etc.).
    """
    canvas_size = size
    icon_size   = int(size * 0.72)
    icon_resized = img.resize((icon_size, icon_size), Image.LANCZOS)

    canvas = Image.new("RGBA", (canvas_size, canvas_size), (29, 185, 84, 255))
    offset = (canvas_size - icon_size) // 2
    canvas.paste(icon_resized, (offset, offset), icon_resized)
    return canvas


print("\n━━  BergaStream icon generator  ━━\n")

# ── Base 1024×1024 (flutter_launcher_icons source) ────────────────────────
img1024 = svg_to_png(SVG_PATH, 1024)
save(img1024, os.path.join(IMG_DIR, "icon_1024.png"))

# Adaptive foreground: icon on transparent background at 108dp safe zone
# 108dp canvas, icon fills 66dp → inner 61% → use 72% of 1024
fg_size   = 1024
icon_fg   = int(fg_size * 0.66)
fg_canvas = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
icon_fg_img = img1024.resize((icon_fg, icon_fg), Image.LANCZOS)
off = (fg_size - icon_fg) // 2
fg_canvas.paste(icon_fg_img, (off, off), icon_fg_img)
save(fg_canvas, os.path.join(IMG_DIR, "icon_adaptive_fg.png"))

# ── Web PWA icons ──────────────────────────────────────────────────────────
for sz in (192, 512):
    img = svg_to_png(SVG_PATH, sz)
    save(img, os.path.join(WEB_DIR, f"Icon-{sz}.png"))
    maskable = make_maskable(svg_to_png(SVG_PATH, sz), sz)
    save(maskable, os.path.join(WEB_DIR, f"Icon-maskable-{sz}.png"))

# ── Windows ICO (multi-size) ───────────────────────────────────────────────
sizes_ico = [16, 24, 32, 48, 64, 128, 256]
ico_frames = [svg_to_png(SVG_PATH, s) for s in sizes_ico]
ico_path = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
if os.path.isdir(os.path.dirname(ico_path)):
    ico_frames[0].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in sizes_ico],
        append_images=ico_frames[1:],
    )
    print(f"  ✓  {os.path.relpath(ico_path, ROOT)}")
else:
    # Flutter hasn't created the windows target yet — save alongside SVG
    ico_path = os.path.join(IMG_DIR, "icon.ico")
    ico_frames[0].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in sizes_ico],
        append_images=ico_frames[1:],
    )
    save(ico_frames[0], ico_path.replace(".ico", "_256.png"))

# ── Linux PNG (256×256) ────────────────────────────────────────────────────
linux_data_dir = os.path.join(
    ROOT, "linux", "flutter", "ephemeral", ".plugin_symlinks"
)
linux_icon_dir = os.path.join(ROOT, "linux", "runner")
if os.path.isdir(linux_icon_dir):
    linux_icon_path = os.path.join(linux_icon_dir, "my_application.png")
    save(svg_to_png(SVG_PATH, 256), linux_icon_path)

print("\n✅  Done! Now run:\n")
print("    dart run flutter_launcher_icons\n")
