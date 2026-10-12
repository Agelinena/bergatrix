"""Backend do Bergastream.

Ao importar o pacote: se o teste diário do Spotify instalou uma SpotifyScraper
mais nova na pasta persistente (PYDEPS_DIR/active), ela passa na frente da
versão da imagem. Uma imagem reconstruída com versão igual ou maior volta a
valer sozinha.
"""
from __future__ import annotations

import os
import sys
from importlib import metadata
from pathlib import Path


def version_tuple(version: str) -> tuple[int, ...]:
    parts = []
    for piece in version.split("."):
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def _folder_version(folder: Path) -> str | None:
    for info in folder.glob("spotifyscraper-*.dist-info"):
        return info.name[len("spotifyscraper-"):-len(".dist-info")]
    return None


def _activate_pydeps() -> None:
    forced = os.environ.get("BERGASTREAM_PYDEPS_FORCE")  # verificação de uma versão nova
    if forced:
        sys.path.insert(0, forced)
        return
    active = Path(os.environ.get("PYDEPS_DIR", "/data/pydeps")) / "active"
    if not active.is_dir():
        return
    downloaded = _folder_version(active)
    try:
        bundled = metadata.version("spotifyscraper")
    except metadata.PackageNotFoundError:
        bundled = "0"
    if downloaded and version_tuple(downloaded) > version_tuple(bundled):
        sys.path.insert(0, str(active.resolve()))


_activate_pydeps()
