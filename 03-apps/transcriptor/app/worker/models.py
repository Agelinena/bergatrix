"""Baixa os modelos do catálogo (revisão fixa no Hugging Face) e confere o
SHA-256 do model.bin antes de usar. Ficam em ${CACHE_PATH}/transcriptor/models:
apagar a pasta só obriga a baixar de novo."""

from __future__ import annotations

import hashlib
import logging
import shutil
from pathlib import Path

from app.catalog import ModelSpec
from app.config import settings

logger = logging.getLogger("transcriptor.models")

VERIFIED = ".verified"


class ModelError(Exception):
    pass


def model_dir(spec: ModelSpec) -> Path:
    return Path(settings.models_dir) / spec.id / spec.revision


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_ready(spec: ModelSpec) -> bool:
    target = model_dir(spec)
    marker = target / VERIFIED
    return (marker.exists() and marker.read_text().strip() == spec.model_sha256
            and all((target / name).exists() for name in spec.files))


def ensure(spec: ModelSpec) -> Path:
    """Caminho do modelo pronto para uso; baixa e confere se precisar."""
    target = model_dir(spec)
    if is_ready(spec):
        return target
    from huggingface_hub import hf_hub_download

    logger.info("[models] baixando %s (%s@%s, %.1f GB)", spec.id, spec.repo, spec.revision[:10],
                spec.model_bytes / 1e9)
    target.mkdir(parents=True, exist_ok=True)
    (target / VERIFIED).unlink(missing_ok=True)
    for name in spec.files:
        hf_hub_download(repo_id=spec.repo, filename=name, revision=spec.revision, local_dir=target)
    model = target / "model.bin"
    if model.stat().st_size != spec.model_bytes or sha256(model) != spec.model_sha256:
        shutil.rmtree(target, ignore_errors=True)
        raise ModelError(f"o model.bin de {spec.id} não confere com o SHA-256 do catálogo")
    (target / VERIFIED).write_text(spec.model_sha256 + "\n")
    # Versões antigas do mesmo modelo saem (o catálogo mudou de revisão).
    for old in target.parent.iterdir():
        if old != target and old.is_dir():
            shutil.rmtree(old, ignore_errors=True)
    logger.info("[models] %s pronto e conferido", spec.id)
    return target
