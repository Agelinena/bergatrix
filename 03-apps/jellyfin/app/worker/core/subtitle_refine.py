"""
Refino de sincronia por CONTEÚDO.

Caso típico: a legenda PT veio de OUTRO release (HDTV × WEB-DL, cortes de comercial
diferentes, velocidade levemente diferente). O tempo interno dela está bom — o tradutor
cronometrou cada fala para o seu texto —, mas o deslocamento em relação ao vídeo varia ao
longo do episódio (deriva gradual + saltos nos cortes). Copiar o tempo da legenda embutida
fala a fala destrói essa precisão quando o tradutor quebrou as frases em outro ponto.

Por isso o refino estima uma CURVA de deslocamento e a aplica a todas as falas:
  1. Limpa os textos (tags, [SDH], ♪, "NOME:") e gera um embedding por fala (Ollama).
  2. Pré-alinhamento: reta offset(t) = a + b·t a partir de falas longas e distintivas
     (cobre deslocamentos grandes e diferença de velocidade entre releases).
  3. Alinhamento fino (programação dinâmica monotônica, ±REFINE_WINDOW_SECONDS) só para
     achar ÂNCORAS: pares 1:1 com similaridade alta, tamanhos compatíveis e sem sinal de
     que a fala PT contém também a fala vizinha da referência.
  4. Curva: saltos detectados nas âncoras (cortes) + mediana local dentro de cada trecho.
     Cada fala é deslocada pela curva — duração e quebra de frases do tradutor intactas.
  5. Ajuste individual só para âncoras inequívocas que fogem da curva (fala isolada
     adiantada/atrasada).
  6. Tempo de leitura: o fim de falas rápidas demais pode se estender só em silêncio real.
  7. Portões: casamento mínimo, âncoras suficientes, curva consistente, texto idêntico.
     Reprovou → a legenda não é tocada.

Uso manual (dentro do container):
  python -m core.subtitle_refine --video /media/filmes/X/X.mkv            (só relatório)
  python -m core.subtitle_refine --subtitle pt.srt --reference en.srt --apply
"""

import argparse
import bisect
import json
import logging
import math
import operator
from itertools import combinations
import os
import re
import statistics
import threading
import time
from dataclasses import dataclass

import httpx

from .subtitle_sync import Cue, format_timestamp, parse_srt, render_srt

logger = logging.getLogger(__name__)

# off = desligado | audit = só mede e grava relatório | fix = corrige quando passa nos portões
REFINE_MODE = os.environ.get("SUBTITLE_REFINE", "audit").strip().lower()
EMBED_MODEL = os.environ.get("REFINE_EMBED_MODEL", "bge-m3").strip()
# Distância máxima (s) entre a fala PT (já pré-alinhada) e a candidata da referência.
REFINE_WINDOW = float(os.environ.get("REFINE_WINDOW_SECONDS", "12"))
# Deslocamento perceptível: a curva só é aplicada se mover ao menos MIN_PERCEPTIBLE falas
# por pelo menos isto (abaixo disso é ruído das âncoras e reescrever não ajuda).
REFINE_TOLERANCE = float(os.environ.get("REFINE_TOLERANCE_SECONDS", "0.25"))
# Fração mínima das falas PT casadas com confiança para aplicar a correção.
REFINE_MIN_MATCH = float(os.environ.get("REFINE_MIN_MATCH", "0.6"))
# Velocidade máxima de leitura (caracteres/s). 17 é a referência para PT-BR adulto.
REFINE_MAX_CPS = float(os.environ.get("REFINE_MAX_CPS", "17"))
REPORT_FILE = "/app/stats/subtitle_refine.json"

# Calibrados com bge-m3 em pares EN↔PT: traduções ficam em 0,75–0,98; frases sem
# relação, em 0,40–0,65. Interjeições curtas enganam ("Yes." × "Não." = 0,83), por
# isso âncoras exigem texto longo.
MATCH_THRESHOLD = 0.6        # ponto zero do ganho: abaixo disso, pular é melhor que casar
CONFIDENT_SIMILARITY = 0.72  # casamento conta como "casado" (cobertura/qualidade)
MERGE_PENALTY = 0.12         # custo extra por fala adicional num grupo (evita fusões gulosas)
TIME_WEIGHT = 0.1            # leve preferência pela candidata mais próxima no tempo
OFF_THRESHOLD = 0.5          # fala com |delta| acima disto conta como "fora do tempo"
# Pré-alinhamento (releases diferentes: deslocamento grande e diferença de velocidade).
COARSE_WINDOW = 180.0        # s: busca de cada fala amostrada na referência
COARSE_SAMPLES = 80          # falas longas amostradas ao longo do episódio
COARSE_MIN_POINTS = 8        # mínimo de casamentos inequívocos para confiar na reta
COARSE_MARGIN = 0.04         # melhor candidata precisa superar a 2ª por esta margem
MAX_DRIFT = 0.05             # inclinação máxima aceita (5% ≈ 25 × 23,976 fps)
# Âncoras da curva: pares 1:1 que com certeza são a MESMA frase.
ANCHOR_SIMILARITY = 0.8
ANCHOR_MIN_TEXT = 15         # caracteres (texto limpo) dos dois lados
ANCHOR_LENGTH_RATIO = (0.55, 1.8)  # tamanho PT ÷ EN plausível para a mesma frase
NEIGHBOR_GAP = 1.5           # s: fala vizinha da referência "colada" (mesmo diálogo)
OUTLIER_DEVIATION = 0.8      # s: âncora fora disto dos dois lados vira suspeita
MIN_ANCHORS = 12
MAX_ANCHOR_RESIDUAL = 0.6    # s: resíduo mediano máximo das âncoras em relação à curva
# Curva: saltos (cortes) + mediana local.
JUMP_SPAN = 5                # âncoras de cada lado para detectar um salto
JUMP_MIN = 0.7               # s: salto mínimo considerado corte (validação cruzada)
CURVE_NEIGHBORS = 9          # âncoras na mediana local
MICRO_SHIFT = 0.05           # s: deslocamentos menores que isto não são aplicados
MIN_PERCEPTIBLE = 5          # falas com |curva| >= REFINE_TOLERANCE para aplicar a curva
# Ajuste individual de âncora inequívoca que foge da curva.
SNAP_SIMILARITY = 0.85
# Empurrar uma fala para DEPOIS é a direção arriscada: quase sempre é o tradutor que
# começou a fala com o fim da frase anterior. Exige mais certeza.
SNAP_SIMILARITY_LATER = 0.9
SNAP_MIN = 0.6               # s: desvio mínimo em relação à curva
# Tempo de leitura: o fim pode se estender para dar tempo de ler o português, mas só
# em silêncio real (sem fala da referência começando) e sem invadir a próxima fala.
MIN_GAP = 0.083              # s: intervalo mínimo até a próxima fala (~2 quadros)
MIN_DURATION = 5 / 6         # s: duração mínima de uma fala
MAX_DURATION = 7.0           # s: duração máxima ao estender
MOVES = ((1, 1), (1, 2), (2, 1), (2, 2))

_TAGS = re.compile(r"<[^>]+>|\{[^}]*\}")
_SDH = re.compile(r"\[[^\]]*\]|\([^)]*\)|♪[^♪\n]*♪?|#")
_SPEAKER = re.compile(r"^\s*[A-ZÀ-Ý][A-ZÀ-Ý0-9 .'\-]{1,30}:\s*", re.M)
_DASH = re.compile(r"^\s*[-–—]+\s*", re.M)

_report_lock = threading.Lock()


class RefineError(Exception):
    pass


def clean_text(text: str) -> str:
    """Texto só para comparação (o texto gravado nunca passa por aqui)."""
    value = _TAGS.sub(" ", text)
    value = _SDH.sub(" ", value)
    value = _SPEAKER.sub("", value)
    value = _DASH.sub("", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value if sum(ch.isalnum() for ch in value) >= 2 else ""


def _normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vector)) or 1.0
    return [x / norm for x in vector]


def _dot(a: list[float], b: list[float]) -> float:
    return sum(map(operator.mul, a, b))


def _combine(vectors: list[list[float]]) -> list[float]:
    if len(vectors) == 1:
        return vectors[0]
    return _normalize([sum(values) for values in zip(*vectors)])


# ------------------------------------------------------------------ #
# Embeddings (Ollama)                                                  #
# ------------------------------------------------------------------ #
class OllamaEmbedder:
    def __init__(self, base_url: str | None = None, model: str = EMBED_MODEL, batch: int = 32):
        self.base_url = (base_url or os.environ.get("LOCAL_AI_URL", "http://ollama:11434")).rstrip("/")
        self.model = model
        self.batch = batch
        self.timeout = float(os.environ.get("OLLAMA_TIMEOUT", "600"))
        # Libera a VRAM logo após o uso (GPU pequena compartilhada com tradutor e Jellyfin).
        self.keep_alive = os.environ.get("REFINE_EMBED_KEEP_ALIVE", "2m")

    def embed(self, texts: list[str]) -> list[list[float]]:
        unique = list(dict.fromkeys(texts))
        vectors: dict[str, list[float]] = {}
        with httpx.Client(timeout=self.timeout) as client:
            for start in range(0, len(unique), self.batch):
                chunk = unique[start:start + self.batch]
                response = client.post(
                    f"{self.base_url}/api/embed",
                    json={"model": self.model, "input": chunk, "keep_alive": self.keep_alive, "truncate": True},
                )
                if response.status_code == 404:
                    raise RefineError(
                        f"modelo de embedding '{self.model}' não está no Ollama — "
                        f"rode: docker exec ollama ollama pull {self.model}"
                    )
                if response.status_code != 200:
                    raise RefineError(f"Ollama /api/embed HTTP {response.status_code}: {response.text[:200]}")
                embeddings = response.json().get("embeddings") or []
                if len(embeddings) != len(chunk):
                    raise RefineError("Ollama devolveu quantidade de embeddings diferente da enviada")
                for text, vector in zip(chunk, embeddings):
                    vectors[text] = _normalize(vector)
        return [vectors[text] for text in texts]


# ------------------------------------------------------------------ #
# Alinhamento                                                          #
# ------------------------------------------------------------------ #
@dataclass
class Group:
    targets: tuple[int, ...]  # índices na lista de falas PT (ordenada)
    refs: tuple[int, ...]     # índices na lista de referência (ordenada)
    similarity: float


def align(target: list[Cue], reference: list[Cue], target_vecs: dict, ref_vecs: dict,
          window: float = REFINE_WINDOW) -> list[Group]:
    """
    Alinhamento monotônico em faixa (banded DP). `*_vecs` mapeia índice → embedding
    apenas das falas utilizáveis (texto limpo não vazio); as outras ficam de fora.
    """
    tp = sorted(target_vecs)
    rp = sorted(ref_vecs)
    n, m = len(tp), len(rp)
    if not n or not m:
        return []

    r_starts = [reference[k].start for k in rp]
    lo = [bisect.bisect_left(r_starts, target[k].start - window) for k in tp]
    hi = [bisect.bisect_right(r_starts, target[k].end + window) for k in tp]
    for i in range(1, n):  # faixa monotônica
        lo[i] = max(lo[i], lo[i - 1])
        hi[i] = max(hi[i], hi[i - 1])
    for i in range(n):
        hi[i] = max(hi[i], lo[i])

    # Linha i = i falas PT consumidas; colunas = refs consumidas permitidas.
    row_lo = [lo[0]] + [lo[i - 1] for i in range(1, n + 1)]
    row_hi = [hi[i] for i in range(n)] + [m]

    target_group: dict = {}
    ref_group: dict = {}

    def tvec(i, a):
        key = (i, a)
        if key not in target_group:
            target_group[key] = _combine([target_vecs[tp[i + x]] for x in range(a)])
        return target_group[key]

    def rvec(j, b):
        key = (j, b)
        if key not in ref_group:
            ref_group[key] = _combine([ref_vecs[rp[j + x]] for x in range(b)])
        return ref_group[key]

    neg = float("-inf")
    score = [[neg] * (row_hi[i] - row_lo[i] + 1) for i in range(n + 1)]
    back: list[list] = [[None] * (row_hi[i] - row_lo[i] + 1) for i in range(n + 1)]
    score[0][0] = 0.0

    def relax(i, j, value, pointer):
        if j < row_lo[i] or j > row_hi[i]:
            return
        col = j - row_lo[i]
        if value > score[i][col]:
            score[i][col] = value
            back[i][col] = pointer

    for i in range(n + 1):
        for col in range(row_hi[i] - row_lo[i] + 1):
            value = score[i][col]
            if value == neg:
                continue
            j = row_lo[i] + col
            relax(i, j + 1, value, (i, j, 0, 1, 0.0))  # pula referência
            if i == n:
                continue
            relax(i + 1, j, value, (i, j, 1, 0, 0.0))  # pula fala PT
            if j < lo[i]:
                continue
            for a, b in MOVES:
                if i + a > n or j + b > m or j + b > hi[i + a - 1]:
                    continue
                sim = _dot(tvec(i, a), rvec(j, b))
                t_center = (target[tp[i]].start + target[tp[i + a - 1]].end) / 2
                r_center = (reference[rp[j]].start + reference[rp[j + b - 1]].end) / 2
                gain = (
                    (sim - MATCH_THRESHOLD) * (a + b) / 2
                    - MERGE_PENALTY * (a + b - 2)
                    - TIME_WEIGHT * min(abs(t_center - r_center), window) / window
                )
                relax(i + a, j + b, value + gain, (i, j, a, b, sim))

    last = score[n]
    col = max(range(len(last)), key=lambda c: last[c])
    i, j = n, row_lo[n] + col
    groups = []
    while back[i][j - row_lo[i]] is not None:
        pi, pj, a, b, sim = back[i][j - row_lo[i]]
        if a and b:
            groups.append(Group(
                tuple(tp[pi + x] for x in range(a)),
                tuple(rp[pj + x] for x in range(b)),
                round(sim, 4),
            ))
        i, j = pi, pj
    groups.reverse()
    return groups


# ------------------------------------------------------------------ #
# Métricas e tempo de leitura                                          #
# ------------------------------------------------------------------ #
def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def _offset_stats(deltas: list[float]) -> dict:
    absolute = [abs(d) for d in deltas]
    return {
        "mediana_abs": round(statistics.median(absolute), 3) if absolute else 0.0,
        "p90_abs": round(_percentile(absolute, 0.9), 3),
        "max_abs": round(max(absolute, default=0.0), 3),
        "fora_do_tempo": sum(1 for d in absolute if d > OFF_THRESHOLD),
    }


def visible_chars(text: str) -> int:
    """Caracteres que o espectador lê (sem tags; quebra de linha conta como espaço)."""
    return len(re.sub(r"\s+", " ", _TAGS.sub("", text)).strip())


def reading_cps(cue: Cue) -> float:
    return visible_chars(cue.text) / max(0.001, cue.end - cue.start)


def fit_reading_time(cues: list[Cue], speech_starts: list[float]) -> int:
    """
    Dá tempo de leitura a falas rápidas demais estendendo só o FIM, e só em silêncio
    real: nunca passa do início da próxima fala PT nem do início da próxima fala da
    referência (outra pessoa falando). O início nunca se move. Retorna quantas estendeu.
    """
    extended = 0
    for k, cue in enumerate(cues):
        needed = min(MAX_DURATION, max(MIN_DURATION, visible_chars(cue.text) / REFINE_MAX_CPS))
        if cue.end - cue.start >= needed:
            continue
        limit = cues[k + 1].start - MIN_GAP if k + 1 < len(cues) else cue.start + needed
        nxt = bisect.bisect_right(speech_starts, cue.end + 0.001)
        if nxt < len(speech_starts):
            limit = min(limit, speech_starts[nxt] - MIN_GAP)
        new_end = max(cue.end, min(cue.start + needed, limit))
        if new_end > cue.end + 0.001:
            extended += 1
            cue.end = new_end
    return extended


def _short(text: str, limit: int = 70) -> str:
    value = re.sub(r"\s+", " ", _TAGS.sub("", text)).strip()
    return value if len(value) <= limit else value[:limit - 1] + "…"


# ------------------------------------------------------------------ #
# Curva de deslocamento                                                #
# ------------------------------------------------------------------ #
@dataclass
class Anchor:
    target: int      # índice da fala PT
    ref: int         # índice da fala de referência
    offset: float    # início da referência − início da PT (s)
    similarity: float


def estimate_coarse_offset(target: list[Cue], reference: list[Cue], t_vecs: dict, r_vecs: dict,
                           t_clean: dict) -> tuple[float, float, int]:
    """
    Pré-alinhamento offset(t) = a + b·t. Amostra falas PT longas ao longo do episódio,
    procura a melhor candidata da referência em ±COARSE_WINDOW e só aceita casamentos
    inequívocos; a reta sai de Theil–Sen (mediana das inclinações), robusta a erros.
    Retorna (a, b, pontos usados).
    """
    r_order = sorted(r_vecs, key=lambda k: reference[k].start)
    r_starts = [reference[k].start for k in r_order]
    long_targets = [k for k in sorted(t_vecs) if len(t_clean[k]) >= 20]
    step = max(1, len(long_targets) // COARSE_SAMPLES)
    points = []
    for k in long_targets[::step]:
        t = target[k].start
        lo = bisect.bisect_left(r_starts, t - COARSE_WINDOW)
        hi = bisect.bisect_right(r_starts, t + COARSE_WINDOW)
        ranked = sorted(((_dot(t_vecs[k], r_vecs[r_order[j]]), j) for j in range(lo, hi)), reverse=True)
        if not ranked or ranked[0][0] < ANCHOR_SIMILARITY:
            continue
        if len(ranked) > 1 and ranked[0][0] - ranked[1][0] < COARSE_MARGIN:
            continue
        points.append((t, r_starts[ranked[0][1]] - t))
    if len(points) < COARSE_MIN_POINTS:
        return 0.0, 0.0, len(points)
    slopes = [(d2 - d1) / (t2 - t1) for (t1, d1), (t2, d2) in combinations(points, 2) if t2 - t1 >= 60]
    slope = max(-MAX_DRIFT, min(MAX_DRIFT, statistics.median(slopes))) if slopes else 0.0
    intercept = statistics.median(d - slope * t for t, d in points)
    return intercept, slope, len(points)


def _contains_neighbor(k: int, r: int, base: float, reference: list[Cue], t_vecs: dict, r_vecs: dict,
                       r_order: list[int], r_pos: dict) -> bool:
    """
    True se a fala PT parece conter também a fala da referência vizinha (antes ou depois,
    colada): juntar a vizinha não reduz a similaridade. É o caso do tradutor que juntou
    duas falas em uma — o início da fala PT NÃO é o início desta fala da referência.
    """
    pos = r_pos[r]
    for other in (pos - 1, pos + 1):
        if not 0 <= other < len(r_order):
            continue
        nb = r_order[other]
        first, second = (nb, r) if other < pos else (r, nb)
        if reference[second].start - reference[first].end > NEIGHBOR_GAP:
            continue
        if _dot(t_vecs[k], _combine([r_vecs[first], r_vecs[second]])) >= base - 0.01:
            return True
    return False


def split_outliers(anchors: list[Anchor]) -> tuple[list[Anchor], list[Anchor]]:
    """Âncora que destoa das vizinhas dos DOIS lados (num salto, concorda com um lado)."""
    offsets = [a.offset for a in anchors]
    good, suspects = [], []
    for i, anchor in enumerate(anchors):
        left, right = offsets[max(0, i - 5):i], offsets[i + 1:i + 6]
        deviations = [abs(anchor.offset - statistics.median(side)) for side in (left, right) if side]
        if deviations and min(deviations) > OUTLIER_DEVIATION:
            suspects.append(anchor)
        else:
            good.append(anchor)
    return good, suspects


def fit_offset_curve(target: list[Cue], anchors: list[Anchor]) -> tuple[list[float], list[tuple[int, float]]]:
    """
    Deslocamento de cada fala PT. Saltos (cortes) são detectados comparando a mediana
    das JUMP_SPAN âncoras antes e depois; a fronteira fica no maior intervalo entre falas
    PT naquele ponto (cortes caem em pausas). Dentro de cada trecho, a mediana das
    CURVE_NEIGHBORS âncoras mais próximas acompanha a deriva gradual.
    Retorna (deslocamento por fala, [(índice da fala onde começa o trecho, salto)]).
    """
    n = len(anchors)
    offsets = [a.offset for a in anchors]
    scored = []
    for i in range(JUMP_SPAN, n - JUMP_SPAN + 1):
        delta = statistics.median(offsets[i:i + JUMP_SPAN]) - statistics.median(offsets[i - JUMP_SPAN:i])
        scored.append((abs(delta), i, delta))
    # Um salto real aparece como um PLATÔ de posições com o mesmo delta (a mediana tolera
    # algumas âncoras do outro lado). A fronteira é procurada ao longo do platô inteiro.
    by_position = {i: abs(delta) for _, i, delta in scored}
    cuts = []
    for score, i, delta in sorted(scored, key=lambda item: (-item[0], item[1])):
        if score < JUMP_MIN:
            break
        if any(lo - JUMP_SPAN < i < hi + JUMP_SPAN for lo, hi, _ in cuts):
            continue
        lo = hi = i
        while by_position.get(lo - 1, 0.0) >= score - 0.1:
            lo -= 1
        while by_position.get(hi + 1, 0.0) >= score - 0.1:
            hi += 1
        cuts.append((lo, hi, delta))
    cuts.sort()

    boundaries, jumps = [], []
    for lo, hi, delta in cuts:
        first, last = anchors[lo - 1].target + 1, anchors[hi].target
        k = max(range(first, last + 1), key=lambda j: target[j].start - target[j - 1].end)
        boundaries.append(k)
        jumps.append((k, delta))

    segments: list[list[Anchor]] = [[] for _ in range(len(boundaries) + 1)]
    for anchor in anchors:
        segments[bisect.bisect_right(boundaries, anchor.target)].append(anchor)

    curve = []
    for k, cue in enumerate(target):
        segment = segments[bisect.bisect_right(boundaries, k)] or anchors
        times = [target[a.target].start for a in segment]
        pos = bisect.bisect_left(times, cue.start)
        window = segment[max(0, pos - CURVE_NEIGHBORS):pos + CURVE_NEIGHBORS]
        nearest = sorted(window, key=lambda a: abs(target[a.target].start - cue.start))[:CURVE_NEIGHBORS]
        curve.append(statistics.median(a.offset for a in nearest))
    return curve, jumps


# ------------------------------------------------------------------ #
# Correção + métricas                                                  #
# ------------------------------------------------------------------ #
@dataclass
class RefineResult:
    cues: list[Cue]
    verdict: str
    changed: int
    report: dict


def refine_cues(target: list[Cue], reference: list[Cue], embedder, window: float = REFINE_WINDOW) -> RefineResult:
    target = sorted(target, key=lambda c: c.start)
    reference = sorted(reference, key=lambda c: c.start)
    t_clean = {k: clean_text(c.text) for k, c in enumerate(target)}
    r_clean = {k: clean_text(c.text) for k, c in enumerate(reference)}
    t_idx = [k for k, text in t_clean.items() if text]
    r_idx = [k for k, text in r_clean.items() if text]

    base_report = {"falas_pt": len(t_idx), "falas_referencia": len(r_idx)}
    if not t_idx or len(r_idx) < 0.4 * len(t_idx):
        # Referência curta demais: provavelmente faixa "forced"/sinais ou vazia.
        return RefineResult(target, "referencia_incompativel", 0, base_report)

    vectors = embedder.embed([t_clean[k] for k in t_idx] + [r_clean[k] for k in r_idx])
    t_vecs = dict(zip(t_idx, vectors[:len(t_idx)]))
    r_vecs = dict(zip(r_idx, vectors[len(t_idx):]))

    # 1. Pré-alinhamento + alinhamento fino sobre a PT pré-alinhada.
    intercept, slope, coarse_points = estimate_coarse_offset(target, reference, t_vecs, r_vecs, t_clean)
    shifted = [
        Cue(c.start + intercept + slope * c.start, c.end + intercept + slope * c.start, c.text)
        for c in target
    ]
    groups = align(shifted, reference, t_vecs, r_vecs, window)
    confident = [g for g in groups if g.similarity >= CONFIDENT_SIMILARITY]
    matched_ratio = len({k for g in confident for k in g.targets}) / len(t_idx)
    matched_refs = {k for g in confident for k in g.refs}
    similarities = [g.similarity for g in confident]

    # 2. Âncoras: pares 1:1 que com certeza são a mesma frase.
    r_order = sorted(r_idx, key=lambda k: reference[k].start)
    r_pos = {r: i for i, r in enumerate(r_order)}
    anchors = []
    for g in groups:
        if len(g.targets) != 1 or len(g.refs) != 1 or g.similarity < ANCHOR_SIMILARITY:
            continue
        k, r = g.targets[0], g.refs[0]
        t_len, r_len = len(t_clean[k]), len(r_clean[r])
        if min(t_len, r_len) < ANCHOR_MIN_TEXT:
            continue
        if not ANCHOR_LENGTH_RATIO[0] <= t_len / r_len <= ANCHOR_LENGTH_RATIO[1]:
            continue
        if _contains_neighbor(k, r, g.similarity, reference, t_vecs, r_vecs, r_order, r_pos):
            continue
        anchors.append(Anchor(k, r, reference[r].start - target[k].start, g.similarity))
    good, suspects = split_outliers(anchors)

    # 3. Curva aplicada a todas as falas (duração e quebra de frases intactas).
    if good:
        curve, jumps = fit_offset_curve(target, good)
    else:
        curve, jumps = [0.0] * len(target), []
    # Só aplica se o deslocamento for perceptível em várias falas: numa legenda já
    # refinada, a curva é ruído de ±0,2 s e reaplicá-la reescreveria tudo a cada passada.
    perceptible = sum(1 for shift in curve if abs(shift) >= REFINE_TOLERANCE)
    apply_curve = perceptible >= MIN_PERCEPTIBLE
    new_cues = []
    for cue, shift in zip(target, curve):
        shift = shift if apply_curve and abs(shift) >= MICRO_SHIFT else 0.0
        new_cues.append(Cue(cue.start + shift, cue.end + shift, cue.text))

    # 4. Ajuste individual: âncora inequívoca que foge da curva. As falas da referência
    # coladas a ela precisam estar casadas com OUTRAS falas PT: se a vizinha ficou sem
    # par, a fala PT provavelmente a contém (tradutor juntou as duas) e o início dela
    # não é o desta fala da referência.
    covered = {r for g in groups for r in g.refs}

    def neighbors_covered(r: int) -> bool:
        pos = r_pos[r]
        for other in (pos - 1, pos + 1):
            if 0 <= other < len(r_order):
                nb = r_order[other]
                first, second = sorted((nb, r), key=lambda x: reference[x].start)
                if reference[second].start - reference[first].end <= NEIGHBOR_GAP and nb not in covered:
                    return False
        return True

    snapped = []
    for a in suspects:
        k, ref = a.target, reference[a.ref]
        residual = a.offset - curve[k]
        required = SNAP_SIMILARITY_LATER if residual > 0 else SNAP_SIMILARITY
        if a.similarity < required or not SNAP_MIN <= abs(residual) <= window:
            continue
        if not neighbors_covered(a.ref):
            continue
        duration = target[k].end - target[k].start
        lower = new_cues[k - 1].end + MIN_GAP if k else 0.0
        upper = new_cues[k + 1].start - MIN_GAP if k + 1 < len(new_cues) else math.inf
        start, end = ref.start, min(ref.start + duration, upper)
        if start < lower or end - start < MIN_DURATION:
            continue  # não cabe sem atropelar as vizinhas: fica com a curva
        new_cues[k] = Cue(start, end, target[k].text)
        snapped.append((a, residual))

    # 5. Ordem, sobreposição e tempo de leitura.
    for k in range(1, len(new_cues)):
        previous, current = new_cues[k - 1], new_cues[k]
        if current.start < previous.start:
            current.start = previous.start + 0.001
        if previous.end > current.start and current.start - previous.start >= 0.5:
            previous.end = current.start  # só sobreposição real; falas coladas são normais
    for cue in new_cues:
        cue.end = max(cue.end, cue.start + 0.3)
    extended = fit_reading_time(new_cues, [reference[r].start for r in r_order])

    # Métricas: deslocamento das âncoras antes/depois.
    anchor_set = good + [a for a, _ in snapped]
    deltas_before = [a.offset for a in anchor_set]
    deltas_after = [reference[a.ref].start - new_cues[a.target].start for a in anchor_set]
    residuals = [abs(a.offset - curve[a.target]) for a in good]
    residual = statistics.median(residuals) if residuals else 0.0
    changed = sum(
        1 for old, new in zip(target, new_cues)
        if abs(old.start - new.start) >= 0.001 or abs(old.end - new.end) >= 0.001
    )
    shifts = [new.start - old.start for old, new in zip(target, new_cues)]
    max_shift = max((abs(s) for s in shifts), default=0.0)
    kinds: dict[str, int] = {}
    for g in groups:
        kind = f"{len(g.targets)}:{len(g.refs)}"
        kinds[kind] = kinds.get(kind, 0) + 1
    median_sim = statistics.median(similarities) if similarities else 0.0
    quality = 100 * matched_ratio * max(0.0, min(1.0, (median_sim - MATCH_THRESHOLD) / (0.92 - MATCH_THRESHOLD)))

    report = {
        **base_report,
        "casadas_pct": round(100 * matched_ratio, 1),
        "referencia_coberta_pct": round(100 * len(matched_refs) / len(r_idx), 1),
        "similaridade_mediana": round(median_sim, 3),
        "qualidade": round(quality),
        "grupos": kinds,
        "ancoras": len(good),
        "ancoras_suspeitas": len(suspects),
        "residuo_ancoras": round(residual, 3),
        "curva": {
            "pre_alinhamento": round(intercept, 3),
            "deriva_s_por_min": round(slope * 60, 4),
            "pontos_pre_alinhamento": coarse_points,
            "min": round(min(curve, default=0.0), 3),
            "max": round(max(curve, default=0.0), 3),
            "saltos": [{"tempo": format_timestamp(target[k].start), "delta": round(d, 2)} for k, d in jumps],
            "falas_perceptiveis": perceptible,
            "aplicada": apply_curve,
        },
        "offset_antes": _offset_stats(deltas_before),
        "offset_depois": _offset_stats(deltas_after),
        "propostas": changed,  # antes dos portões; "alteradas" = o que foi gravado
        "deslocamento_max": round(max_shift, 3),
        "leitura": {
            "limite_cps": REFINE_MAX_CPS,
            "rapidas_antes": sum(1 for c in target if reading_cps(c) > REFINE_MAX_CPS),
            "rapidas_depois": sum(1 for c in new_cues if reading_cps(c) > REFINE_MAX_CPS),
            "estendidas": extended,
        },
        "ajustes_individuais_total": len(snapped),
        "ajustes_individuais": [
            {
                "tempo": format_timestamp(new_cues[a.target].start),
                "delta": round(res, 2),
                "pt": _short(target[a.target].text),
                "ref": _short(reference[a.ref].text),
                "similaridade": a.similarity,
            }
            for a, res in sorted(snapped, key=lambda item: -abs(item[1]))[:8]
        ],
    }

    # Portões de segurança.
    if [c.text for c in new_cues] != [c.text for c in target]:
        raise RefineError("invariante violada: texto alterado")  # nunca deveria ocorrer
    if matched_ratio < REFINE_MIN_MATCH or len(good) < MIN_ANCHORS or residual > MAX_ANCHOR_RESIDUAL:
        return RefineResult(target, "baixa_confianca", 0, report)
    if max_shift > COARSE_WINDOW + window:
        return RefineResult(target, "deslocamento_excessivo", 0, report)
    if changed == 0:
        return RefineResult(target, "sincronizada", 0, report)
    return RefineResult(new_cues, "corrigivel", changed, report)


# ------------------------------------------------------------------ #
# Arquivos                                                             #
# ------------------------------------------------------------------ #
def read_subtitle(path: str) -> str:
    with open(path, "rb") as f:
        raw = f.read()
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def refine_file(subtitle_path: str, reference_path: str, embedder=None, apply: bool = False) -> dict:
    """Mede (e, com apply=True, corrige) a legenda. Retorna o relatório."""
    target = parse_srt(read_subtitle(subtitle_path))
    reference = parse_srt(read_subtitle(reference_path))
    started = time.monotonic()
    result = refine_cues(target, reference, embedder or OllamaEmbedder())
    verdict = result.verdict
    if apply and verdict == "corrigivel":
        backup = f"{subtitle_path}.pre-refine"
        # Guarda só a PRIMEIRA versão: refinos repetidos não sobrescrevem o original do Bazarr.
        if not os.path.exists(backup):
            with open(subtitle_path, "rb") as src, open(backup, "wb") as dst:
                dst.write(src.read())
        # .tmp não termina em .srt → o watchdog de legendas não reage ao arquivo temporário.
        tmp = f"{subtitle_path}.refine.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(render_srt(result.cues))
        os.replace(tmp, subtitle_path)
        verdict = "corrigida"
    report = {
        "legenda": subtitle_path,
        "veredito": verdict,
        "segundos": round(time.monotonic() - started, 1),
        **result.report,
        "alteradas": result.changed if verdict == "corrigida" else 0,
    }
    if os.path.exists(subtitle_path):
        stat = os.stat(subtitle_path)
        report["legenda_mtime"] = stat.st_mtime
        report["legenda_tamanho"] = stat.st_size
    return report


def select_reference_stream(streams: list, preferred_languages=("eng", "en")) -> dict | None:
    """
    Escolhe a legenda embutida de texto que serve de referência. Embeddings são
    multilíngues, então qualquer idioma serve; prefere inglês, completa e não-SDH.
    """
    text_codecs = {"subrip", "ass", "ssa", "webvtt", "mov_text", "text"}
    pt_tokens = {"por", "pt", "pb", "pob", "bra", "pt-br"}
    excluded_titles = ("commentary", "director", "description", "forced", "signs", "songs")
    candidates = []
    for stream in streams:
        tags = stream.get("tags", {})
        lang = tags.get("language", "").lower()
        title = tags.get("title", "").lower()
        if stream.get("codec_name") not in text_codecs or lang in pt_tokens:
            continue
        if any(x in title for x in excluded_titles) or stream.get("disposition", {}).get("forced"):
            continue
        sdh = "sdh" in title or bool(stream.get("disposition", {}).get("hearing_impaired"))
        frames = 0
        for key, value in tags.items():
            if key.upper().startswith("NUMBER_OF_FRAMES"):
                try:
                    frames = int(value)
                except ValueError:
                    pass
        candidates.append((lang in preferred_languages, not sdh, frames, -stream.get("index", 0), stream))
    if not candidates:
        return None
    return max(candidates, key=lambda c: c[:4])[4]


def load_reports() -> dict:
    try:
        with open(REPORT_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_report(media_path: str, report: dict):
    with _report_lock:
        reports = load_reports()
        reports[media_path] = {**report, "quando": time.strftime("%Y-%m-%dT%H:%M:%S")}
        try:
            os.makedirs(os.path.dirname(REPORT_FILE), exist_ok=True)
            tmp = f"{REPORT_FILE}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(reports, f, ensure_ascii=False, indent=1)
            os.replace(tmp, REPORT_FILE)
        except Exception as e:
            logger.warning(f"Não foi possível salvar relatório de refino: {e}")


def format_report(report: dict) -> str:
    before, after = report.get("offset_antes", {}), report.get("offset_depois", {})
    curve, reading = report.get("curva", {}), report.get("leitura", {})
    jumps = ", ".join(f"{j['tempo'][3:8]} {j['delta']:+.2f}s" for j in curve.get("saltos", [])) or "nenhum"
    lines = [
        f"Veredito: {report.get('veredito')}  |  qualidade {report.get('qualidade', '-')}/100",
        f"Falas: PT={report.get('falas_pt')} referência={report.get('falas_referencia')}  "
        f"casadas={report.get('casadas_pct', 0)}%  ref coberta={report.get('referencia_coberta_pct', 0)}%  "
        f"similaridade mediana={report.get('similaridade_mediana', 0)}",
        f"Âncoras: {report.get('ancoras', 0)} (suspeitas {report.get('ancoras_suspeitas', 0)})  "
        f"resíduo mediano {report.get('residuo_ancoras', 0)}s",
        f"Curva: pré-alinhamento {curve.get('pre_alinhamento', 0):+.2f}s  "
        f"deriva {curve.get('deriva_s_por_min', 0):+.3f}s/min  "
        f"de {curve.get('min', 0):+.2f}s a {curve.get('max', 0):+.2f}s  "
        f"{'aplicada' if curve.get('aplicada') else 'NÃO aplicada (imperceptível)'}",
        f"Saltos (cortes): {jumps}",
        f"Âncoras antes:  mediana {before.get('mediana_abs', 0)}s  p90 {before.get('p90_abs', 0)}s  "
        f"máx {before.get('max_abs', 0)}s  fora do tempo={before.get('fora_do_tempo', 0)}",
        f"Âncoras depois: mediana {after.get('mediana_abs', 0)}s  p90 {after.get('p90_abs', 0)}s  "
        f"máx {after.get('max_abs', 0)}s  fora do tempo={after.get('fora_do_tempo', 0)}",
        f"Alteradas: {report.get('alteradas', 0)} (propostas: {report.get('propostas', 0)})  "
        f"ajustes individuais: {report.get('ajustes_individuais_total', 0)}  ({report.get('segundos', 0)}s)",
        f"Leitura (> {reading.get('limite_cps', REFINE_MAX_CPS):g} car/s): "
        f"rápidas antes={reading.get('rapidas_antes', 0)} depois={reading.get('rapidas_depois', 0)} "
        f"estendidas={reading.get('estendidas', 0)}",
    ]
    for item in report.get("ajustes_individuais", []):
        lines.append(f"  ajuste {item['tempo']}  {item['delta']:+.2f}s  PT: {item['pt']}  |  REF: {item['ref']}")
    return "\n".join(lines)


def main():
    from .utils import extract_subtitle, find_pt_subtitle, get_media_info

    parser = argparse.ArgumentParser(description="Audita/corrige a sincronia da legenda PT pela legenda embutida.")
    parser.add_argument("--video", help="arquivo de vídeo (extrai a referência embutida)")
    parser.add_argument("--subtitle", help="legenda PT (padrão: a PT externa do vídeo)")
    parser.add_argument("--reference", help="legenda de referência .srt (dispensa --video)")
    parser.add_argument("--stream", type=int, help="índice do stream de referência no vídeo")
    parser.add_argument("--apply", action="store_true", help="grava a correção (padrão: só relatório)")
    parser.add_argument("--json", action="store_true", help="imprime o relatório em JSON")
    args = parser.parse_args()

    subtitle = args.subtitle or (find_pt_subtitle(args.video) if args.video else None)
    if not subtitle or not os.path.exists(subtitle):
        parser.error("legenda PT não encontrada (use --subtitle)")
    reference, temp_reference = args.reference, None
    if not reference:
        if not args.video:
            parser.error("informe --reference ou --video")
        streams = [s for s in (get_media_info(args.video) or {}).get("streams", []) if s.get("codec_type") == "subtitle"]
        stream = next((s for s in streams if s.get("index") == args.stream), None) if args.stream is not None \
            else select_reference_stream(streams)
        if not stream:
            parser.error("vídeo sem legenda de texto embutida para referência")
        temp_reference = f"{os.path.splitext(args.video)[0]}.refine.ref.temp.srt"
        if not extract_subtitle(args.video, stream["index"], temp_reference):
            parser.error("falha ao extrair a legenda de referência")
        reference = temp_reference
    try:
        report = refine_file(subtitle, reference, apply=args.apply)
    finally:
        if temp_reference and os.path.exists(temp_reference):
            os.remove(temp_reference)
    print(json.dumps(report, ensure_ascii=False, indent=1) if args.json else format_report(report))


if __name__ == "__main__":
    main()
