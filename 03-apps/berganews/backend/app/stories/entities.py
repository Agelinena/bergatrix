"""Nomes próprios e siglas de um texto, sem modelo: sequências de palavras com
inicial maiúscula (fora o começo de frase) e siglas (STF, PIB, EUA).

É uma checagem barata para o agrupamento: dois textos de assuntos parecidos
("reforma tributária" e "reforma administrativa") ficam próximos no
embedding, mas raramente citam as mesmas pessoas, órgãos e lugares.
"""
from __future__ import annotations

import re
import unicodedata

_STOP = {
    # português
    "a", "o", "as", "os", "um", "uma", "de", "da", "do", "das", "dos", "em", "no", "na", "nos", "nas",
    "e", "ou", "mas", "que", "se", "por", "para", "com", "sem", "sob", "sobre", "entre", "ao", "aos",
    "à", "às", "pelo", "pela", "este", "esta", "esse", "essa", "isso", "isto", "ele", "ela", "eles",
    "elas", "seu", "sua", "segundo", "após", "antes", "depois", "hoje", "ontem", "amanhã", "veja",
    "leia", "entenda", "saiba", "vídeo", "foto", "fotos", "ao vivo", "exclusivo", "novo", "nova",
    "segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo",
    "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro",
    "outubro", "novembro", "dezembro", "brasil",
    # inglês
    "the", "an", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "by", "from",
    "is", "are", "was", "were", "it", "its", "this", "that", "he", "she", "they", "his", "her",
    "how", "what", "why", "when", "who", "after", "before", "new", "live", "watch", "breaking",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december",
}
# Ligações dentro de um nome: "Banco do Brasil", "Supremo Tribunal Federal", "Bank of England".
_JOINERS = {"de", "da", "do", "das", "dos", "of", "the"}
_WORD = re.compile(r"[\wÀ-ÿ][\wÀ-ÿ'’.-]*", re.UNICODE)
_SENTENCE_END = re.compile(r"[.!?:;\"“”]\s*$")


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    return "".join(ch for ch in text if not unicodedata.combining(ch)).strip(".-'’")


def _capitalized(word: str) -> bool:
    return word[:1].isupper()


def _acronym(word: str) -> bool:
    letters = [c for c in word if c.isalpha()]
    return 2 <= len(letters) <= 6 and all(c.isupper() for c in letters)


def extract(text: str, limit: int = 30) -> list[str]:
    found: list[str] = []
    for sentence in re.split(r"(?<=[.!?])\s+|\n+", text or ""):
        words = [(m.group(), m.start()) for m in _WORD.finditer(sentence)]
        i = 0
        while i < len(words):
            word, _ = words[i]
            if _acronym(word):
                found.append(_norm(word))
                i += 1
                continue
            if _capitalized(word) and _norm(word) not in _STOP:
                parts, j = [word], i + 1
                while j < len(words):
                    nxt = words[j][0]
                    if _capitalized(nxt) and not _acronym(nxt):
                        parts.append(nxt)
                        j += 1
                    elif nxt.lower() in _JOINERS and j + 1 < len(words) and _capitalized(words[j + 1][0]):
                        parts += [nxt, words[j + 1][0]]
                        j += 2
                    else:
                        break
                # A palavra do começo da frase também conta ("Lula diz…"): a
                # lista de palavras comuns tira o "O", "Segundo", "Após"…
                name = _norm(" ".join(parts))
                if name and name not in _STOP and len(name) > 2:
                    found.append(name)
                i = j
                continue
            i += 1
    unique = list(dict.fromkeys(found))
    return unique[:limit]


def overlap(a: list[str] | set[str], b: list[str] | set[str]) -> bool:
    """Um nome em comum, inteiro ou como parte ("lula" ~ "luiz inácio lula da silva")."""
    a, b = set(a), set(b)
    if a & b:
        return True
    tokens_a = {t for name in a for t in name.split() if len(t) > 3 and t not in _JOINERS}
    tokens_b = {t for name in b for t in name.split() if len(t) > 3 and t not in _JOINERS}
    return bool(tokens_a & tokens_b)
