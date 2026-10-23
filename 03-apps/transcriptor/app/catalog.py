"""Modelos que o Transcriptor sabe usar.

Cada um vem de um repositório do Hugging Face numa revisão fixa, e o
SHA-256 do model.bin está aqui: o worker baixa, confere e só usa o modelo se
o hash bater. Trocar de modelo ou de versão é mudar esta tabela.

A GPU do servidor é uma GTX 1060 6 GB (Pascal): int8 é o tipo rápido nela
(float16 é lento em Pascal) e cabe com folga na VRAM, que é dividida com o
Jellyfin e o Ollama. Os tamanhos de lote são um ponto de partida: se faltar
memória na GPU, o worker tenta de novo com metade do lote.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelSpec:
    id: str
    label: str
    description: str
    repo: str
    revision: str
    model_sha256: str
    model_bytes: int
    files: tuple[str, ...]
    beam_size: int
    batch_size: int


_COMMON_FILES = ("config.json", "model.bin", "tokenizer.json")

CATALOG: dict[str, ModelSpec] = {
    "small": ModelSpec(
        id="small",
        label="Rápido",
        description="O mais rápido. Bom para rascunho; erra mais nomes e termos técnicos.",
        repo="Systran/faster-whisper-small",
        revision="536b0662742c02347bc0e980a01041f333bce120",
        model_sha256="3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671",
        model_bytes=483_546_902,
        files=_COMMON_FILES + ("vocabulary.txt",),
        beam_size=5,
        batch_size=16,
    ),
    "turbo": ModelSpec(
        id="turbo",
        label="Preciso",
        description="Whisper Large v3 Turbo: quase a qualidade do Large v3, bem mais rápido. O padrão.",
        repo="dropbox-dash/faster-whisper-large-v3-turbo",
        revision="0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf",
        model_sha256="e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da",
        model_bytes=1_617_884_929,
        files=_COMMON_FILES + ("vocabulary.json", "preprocessor_config.json"),
        beam_size=5,
        batch_size=8,
    ),
    "large-v3": ModelSpec(
        id="large-v3",
        label="Máximo",
        description="Whisper Large v3 completo: o mais preciso, e o mais lento. Para áudio difícil.",
        repo="Systran/faster-whisper-large-v3",
        revision="edaa852ec7e145841d8ffdb056a99866b5f0a478",
        model_sha256="69f74147e3334731bc3a76048724833325d2ec74642fb52620eda87352e3d4f1",
        model_bytes=3_087_284_237,
        files=_COMMON_FILES + ("vocabulary.json", "preprocessor_config.json"),
        beam_size=5,
        batch_size=4,
    ),
}

# Idiomas oferecidos na tela (o Whisper entende ~100; estes cobrem o uso real).
LANGUAGES: dict[str, str] = {
    "pt": "Português",
    "en": "Inglês",
    "es": "Espanhol",
    "fr": "Francês",
    "it": "Italiano",
    "de": "Alemão",
}


def available(enabled: list[str]) -> list[ModelSpec]:
    return [CATALOG[name] for name in enabled if name in CATALOG]
