"""Idioma do artigo: decide o botão de traduzir e a busca (português ou inglês).

Só os idiomas que fazem sentido aqui, para o detector ficar leve e certeiro.
O <language> do feed vale quando o texto é curto demais para detectar.
"""
from __future__ import annotations

from functools import lru_cache

_CODES = {"PORTUGUESE": "pt", "ENGLISH": "en", "SPANISH": "es", "FRENCH": "fr",
          "GERMAN": "de", "ITALIAN": "it"}


@lru_cache(maxsize=1)
def _detector():
    from lingua import Language, LanguageDetectorBuilder
    langs = [getattr(Language, name) for name in _CODES]
    return LanguageDetectorBuilder.from_languages(*langs).with_minimum_relative_distance(0.15).build()


def normalize(code: str | None) -> str | None:
    """'pt-BR', 'en_US', 'EN' → 'pt', 'en'."""
    if not code:
        return None
    code = code.strip().lower().replace("_", "-").split("-")[0]
    return code if 2 <= len(code) <= 3 and code.isalpha() else None


def detect(text: str, feed_language: str | None = None) -> str | None:
    text = (text or "").strip()
    if len(text) >= 80:
        found = _detector().detect_language_of(text[:3000])
        if found is not None:
            return _CODES.get(found.name)
    return normalize(feed_language)
