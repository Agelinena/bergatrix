#!/usr/bin/env python3
"""
Generate all BergaStream platform icon PNGs from the SVG source.

Usage (run from the `frontend/` directory):
    python3 scripts/generate_icons.py
    dart run flutter_launcher_icons

Dependencies are installed automatically inside a local venv.
If you prefer apt packages (Debian/Ubuntu):
    sudo apt install -y python3-cairosvg python3-pil
"""

import os
import sys
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT       = os.path.dirname(SCRIPT_DIR)   # frontend/
VENV_DIR   = os.path.join(SCRIPT_DIR, ".venv")
VENV_PY    = os.path.join(VENV_DIR, "bin", "python3")  # Linux/macOS
VENV_PY_WIN = os.path.join(VENV_DIR, "Scripts", "python.exe")  # Windows


# ── Bootstrap: re-launch inside venv if needed ───────────────────────────────

def _in_venv() -> bool:
    return (
        sys.prefix != sys.base_prefix
        or os.environ.get("VIRTUAL_ENV") is not None
        or hasattr(sys, "real_prefix")
    )

def _bootstrap():
    """Create a local venv, install deps, and re-launch this script inside it."""
    print("[icons] Creating local venv in scripts/.venv …")
    subprocess.check_call([sys.executable, "-m", "venv", VENV_DIR])

    venv_py = VENV_PY_WIN if sys.platform == "win32" else VENV_PY
    pip     = [venv_py, "-m", "pip", "install", "--quiet", "--upgrade", "pip"]
    deps    = [venv_py, "-m", "pip", "install", "--quiet", "cairosvg", "pillow"]
    print("[icons] Installing cairosvg + pillow …")
    subprocess.check_call(pip)
    subprocess.check_call(deps)

    print("[icons] Re-launching inside venv …\n")
    os.execv(venv_py, [venv_py] + sys.argv)  # replace current process


def _try_import():
    try:
        import cairosvg  # noqa: F401
        from PIL import Image  # noqa: F401
        return True
    except ImportError:
        return False


if not _in_venv() or not _try_import():
    # Check if venv already exists with the right packages
    venv_py = VENV_PY_WIN if sys.platform == "win32" else VENV_PY
    if os.path.isfile(venv_py):
        print("[icons] Re-using existing venv …")
        os.execv(venv_py, [venv_py] + sys.argv)
    else:
        _bootstrap()
    sys.exit(0)  # unreachable after execv, but keeps linters happy


# ── Main generation (runs inside venv) ───────────────────────────────────────

import io
import cairosvg
from PIL import Image

SVG_PATH = os.path.join(ROOT, "assets", "images", "logo.svg")
IMG_DIR  = os.path.join(ROOT, "assets", "images")
WEB_DIR  = os.path.join(ROOT, "web", "icons")

os.makedirs(IMG_DIR, exist_ok=True)
os.makedirs(WEB_DIR, exist_ok=True)


def svg_to_png(svg_path: str, size: int) -> Image.Image:
    png_bytes = cairosvg.svg2png(url=svg_path, output_width=size, output_height=size)
    return Image.open(io.BytesIO(png_bytes)).convert("RGBA")


def save(img: Image.Image, path: str):
    img.save(path, "PNG")
    print(f"  ✓  {os.path.relpath(path, ROOT)}")


def make_maskable(img: Image.Image, size: int) -> Image.Image:
    """Android maskable: icon at 72% of canvas, green background fills the rest."""
    icon_size = int(size * 0.72)
    icon      = img.resize((icon_size, icon_size), Image.LANCZOS)
    canvas    = Image.new("RGBA", (size, size), (29, 185, 84, 255))
    off       = (size - icon_size) // 2
    canvas.paste(icon, (off, off), icon)
    return canvas


print("\n━━  BergaStream icon generator  ━━\n")

# Base 1024×1024 (flutter_launcher_icons source)
img1024 = svg_to_png(SVG_PATH, 1024)
save(img1024, os.path.join(IMG_DIR, "icon_1024.png"))

# Android adaptive foreground (transparent canvas, icon at 66% to stay in safe zone)
fg_size   = 1024
icon_fg   = int(fg_size * 0.66)
fg_canvas = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
icon_fg_img = img1024.resize((icon_fg, icon_fg), Image.LANCZOS)
off = (fg_size - icon_fg) // 2
fg_canvas.paste(icon_fg_img, (off, off), icon_fg_img)
save(fg_canvas, os.path.join(IMG_DIR, "icon_adaptive_fg.png"))

# Web PWA icons
for sz in (192, 512):
    save(svg_to_png(SVG_PATH, sz), os.path.join(WEB_DIR, f"Icon-{sz}.png"))
    save(make_maskable(svg_to_png(SVG_PATH, sz), sz),
         os.path.join(WEB_DIR, f"Icon-maskable-{sz}.png"))

# Windows ICO (multi-size)
sizes_ico = [16, 24, 32, 48, 64, 128, 256]
ico_frames = [svg_to_png(SVG_PATH, s) for s in sizes_ico]
ico_target = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
if os.path.isdir(os.path.dirname(ico_target)):
    ico_frames[0].save(ico_target, format="ICO",
                       sizes=[(s, s) for s in sizes_ico],
                       append_images=ico_frames[1:])
    print(f"  ✓  {os.path.relpath(ico_target, ROOT)}")
else:
    ico_frames[0].save(os.path.join(IMG_DIR, "icon.ico"), format="ICO",
                       sizes=[(s, s) for s in sizes_ico],
                       append_images=ico_frames[1:])

# Linux PNG
linux_runner = os.path.join(ROOT, "linux", "runner")
if os.path.isdir(linux_runner):
    save(svg_to_png(SVG_PATH, 256),
         os.path.join(linux_runner, "my_application.png"))

print("\n✅  Done! Now run:\n")
print("    dart run flutter_launcher_icons\n")
