"""
Refino de sincronia por CONTEÚDO.

Casa cada fala da legenda PT (Bazarr) com a(s) fala(s) da legenda embutida
(referência, já sincronizada com o vídeo) usando embeddings multilíngues, e
corrige SÓ os tempos. O texto nunca é alterado — a invariante é verificada antes
de gravar.

Fluxo:
  1. Limpa os textos (tags, [SDH], ♪, "NOME:") e gera um embedding por fala (Ollama).
  2. Programação dinâmica monotônica numa janela de ±REFINE_WINDOW_SECONDS:
     casamentos 1:1, 1:2, 2:1 e 2:2 (frases quebradas de outro jeito), pulos
     permitidos (falas omitidas de um dos lados).
  3. Falas casadas com confiança recebem o tempo da referência; as demais são
     deslocadas pelo offset mediano dos vizinhos confiáveis.
  4. Portões: cobertura mínima de casamento, texto idêntico, ordem preservada,
     deslocamento limitado. Reprovou → a legenda não é tocada.

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
# Distância máxima (s) entre a fala PT e a fala de referência candidata. Legendas
# "quase certas" erram por poucos segundos; janela curta evita casamentos espúrios.
REFINE_WINDOW = float(os.environ.get("REFINE_WINDOW_SECONDS", "12"))
# Diferenças menores que isto não são tocadas (evita reescrever o que já está bom).
REFINE_TOLERANCE = float(os.environ.get("REFINE_TOLERANCE_SECONDS", "0.3"))
# Fração mínima das falas PT casadas com confiança para aplicar a correção.
REFINE_MIN_MATCH = float(os.environ.get("REFINE_MIN_MATCH", "0.6"))
REPORT_FILE = "/app/stats/subtitle_refine.json"

# Calibrados com bge-m3 em pares EN↔PT: traduções ficam em 0,75–0,98; frases sem
# relação, em 0,40–0,65. Interjeições curtas enganam ("Yes." × "Não." = 0,83), por
# isso falas curtas só viram âncora se concordarem com o offset dos vizinhos longos.
MATCH_THRESHOLD = 0.6        # ponto zero do ganho: abaixo disso, pular é melhor que casar
CONFIDENT_SIMILARITY = 0.72  # casamento usado para corrigir tempo
SHORT_TEXT = 12              # caracteres (texto limpo) abaixo dos quais a fala é "curta"
SHORT_MAX_DEVIATION = 1.5    # s: desvio máximo de uma fala curta em relação aos vizinhos
MERGE_PENALTY = 0.12         # custo extra por fala adicional num grupo (evita fusões gulosas)
TIME_WEIGHT = 0.1            # leve preferência pela candidata mais próxima no tempo
NEIGHBOR_SPAN = 60.0         # vizinhança (s) para o offset das falas não casadas
OFF_THRESHOLD = 0.5          # fala com |delta| acima disto conta como "fora do tempo"
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
# Correção + métricas                                                  #
# ------------------------------------------------------------------ #
@dataclass
class RefineResult:
    cues: list[Cue]
    verdict: str
    changed: int
    report: dict


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


def _short(text: str, limit: int = 70) -> str:
    value = re.sub(r"\s+", " ", text).strip()
    return value if len(value) <= limit else value[:limit - 1] + "…"


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
    groups = align(target, reference, t_vecs, r_vecs, window)

    def group_offset(g):
        return reference[g.refs[0]].start - target[g.targets[0]].start

    def is_short(g):
        return (
            sum(len(t_clean[k]) for k in g.targets) < SHORT_TEXT
            or sum(len(r_clean[k]) for k in g.refs) < SHORT_TEXT
        )

    candidates = [g for g in groups if g.similarity >= CONFIDENT_SIMILARITY]
    long_anchors = sorted((target[g.targets[0]].start, group_offset(g)) for g in candidates if not is_short(g))
    long_times = [t for t, _ in long_anchors]

    def consistent_with_neighbors(g):
        start = target[g.targets[0]].start
        pos = bisect.bisect_left(long_times, start)
        near = [d for t, d in long_anchors[max(0, pos - 3):pos + 3] if abs(t - start) <= NEIGHBOR_SPAN]
        return bool(near) and abs(group_offset(g) - statistics.median(near)) <= SHORT_MAX_DEVIATION

    confident = [g for g in candidates if not is_short(g) or consistent_with_neighbors(g)]
    confident_targets = {k for g in confident for k in g.targets}
    matched_ratio = len(confident_targets) / len(t_idx)
    matched_refs = {k for g in confident for k in g.refs}
    similarities = [g.similarity for g in confident]

    # Novo tempo das falas casadas com confiança: herdam o tempo da referência.
    proposed: dict[int, tuple[float, float]] = {}
    for g in confident:
        refs = [reference[k] for k in g.refs]
        if len(g.targets) == len(refs):
            for k, ref in zip(g.targets, refs):
                proposed[k] = (ref.start, ref.end)
        elif len(g.targets) == 1:
            proposed[g.targets[0]] = (refs[0].start, refs[-1].end)
        else:  # 2 falas PT para 1 da referência: divide o tempo pelo tamanho do texto
            span_start, span_end = refs[0].start, refs[-1].end
            weights = [max(1, len(t_clean[k])) for k in g.targets]
            cursor = span_start
            for k, weight in zip(g.targets, weights):
                length = (span_end - span_start) * weight / sum(weights)
                proposed[k] = (cursor, cursor + length)
                cursor += length

    # Falas sem casamento confiável: deslocadas pelo offset mediano dos vizinhos confiáveis.
    anchors = sorted((target[k].start, proposed[k][0] - target[k].start) for k in proposed)
    anchor_times = [t for t, _ in anchors]
    for k, cue in enumerate(target):
        if k in proposed:
            continue
        pos = bisect.bisect_left(anchor_times, cue.start)
        near = [
            delta for t, delta in anchors[max(0, pos - 4):pos + 4]
            if abs(t - cue.start) <= NEIGHBOR_SPAN
        ]
        if near:
            shift = statistics.median(near)
            proposed[k] = (cue.start + shift, cue.end + shift)

    new_cues = []
    for k, cue in enumerate(target):
        start, end = proposed.get(k, (cue.start, cue.end))
        if abs(start - cue.start) < REFINE_TOLERANCE and abs(end - cue.end) < REFINE_TOLERANCE:
            start, end = cue.start, cue.end
        new_cues.append(Cue(start, end, cue.text))

    # Ordem e sobreposição.
    for k in range(1, len(new_cues)):
        previous, current = new_cues[k - 1], new_cues[k]
        if current.start < previous.start:
            current.start = previous.start + 0.001
        if previous.end > current.start and current.start - previous.start >= 0.5:
            previous.end = current.start - 0.001
    for cue in new_cues:
        if cue.end < cue.start + 0.3:
            cue.end = cue.start + 0.3

    deltas_before, deltas_after, worst = [], [], []
    for g in confident:
        for k in g.targets:
            ref_start = proposed[k][0]
            before = target[k].start - ref_start
            deltas_before.append(before)
            deltas_after.append(new_cues[k].start - ref_start)
            worst.append((abs(before), k, g))
    worst.sort(key=lambda item: item[0], reverse=True)

    changed = sum(
        1 for old, new in zip(target, new_cues)
        if abs(old.start - new.start) >= 0.001 or abs(old.end - new.end) >= 0.001
    )
    max_shift = max((abs(o.start - n.start) for o, n in zip(target, new_cues)), default=0.0)
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
        "offset_antes": _offset_stats(deltas_before),
        "offset_depois": _offset_stats(deltas_after),
        "alteradas": changed,
        "deslocamento_max": round(max_shift, 3),
        "piores": [
            {
                "tempo": format_timestamp(target[k].start),
                "delta": round(target[k].start - proposed[k][0], 2),
                "pt": _short(target[k].text),
                "ref": _short(" / ".join(reference[r].text for r in g.refs)),
                "similaridade": g.similarity,
            }
            for delta, k, g in worst[:8] if delta > OFF_THRESHOLD
        ],
    }

    # Portões de segurança.
    if [c.text for c in new_cues] != [c.text for c in target]:
        raise RefineError("invariante violada: texto alterado")  # nunca deveria ocorrer
    if matched_ratio < REFINE_MIN_MATCH:
        return RefineResult(target, "baixa_confianca", 0, report)
    if max_shift > window + 1:
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
    lines = [
        f"Veredito: {report.get('veredito')}  |  qualidade {report.get('qualidade', '-')}/100",
        f"Falas: PT={report.get('falas_pt')} referência={report.get('falas_referencia')}  "
        f"casadas={report.get('casadas_pct', 0)}%  ref coberta={report.get('referencia_coberta_pct', 0)}%  "
        f"similaridade mediana={report.get('similaridade_mediana', 0)}",
        f"Grupos: {report.get('grupos', {})}",
        f"Offset antes:  mediana {before.get('mediana_abs', 0)}s  p90 {before.get('p90_abs', 0)}s  "
        f"máx {before.get('max_abs', 0)}s  fora do tempo={before.get('fora_do_tempo', 0)}",
        f"Offset depois: mediana {after.get('mediana_abs', 0)}s  p90 {after.get('p90_abs', 0)}s  "
        f"máx {after.get('max_abs', 0)}s  fora do tempo={after.get('fora_do_tempo', 0)}",
        f"Alteradas: {report.get('alteradas', 0)}  deslocamento máx: {report.get('deslocamento_max', 0)}s  "
        f"({report.get('segundos', 0)}s)",
    ]
    for item in report.get("piores", []):
        lines.append(f"  {item['tempo']}  {item['delta']:+.2f}s  PT: {item['pt']}  |  REF: {item['ref']}")
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
