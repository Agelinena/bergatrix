import os

import httpx
import pytest

from core.subtitle_refine import (
    MAX_LEAD_IN,
    MIN_GAP,
    REFINE_MAX_CPS,
    OllamaEmbedder,
    _normalize,
    clean_text,
    fit_reading_time,
    refine_cues,
    refine_file,
    select_reference_stream,
    visible_chars,
)
from core.subtitle_sync import Cue, parse_srt, render_srt
from refine_scenario import LINES, build


class ConceptEmbedder:
    """Embedder falso: cada fala do cenário é um 'conceito' (vetor one-hot)."""

    def __init__(self):
        self.concepts = {}
        pt_lines = []
        for index, (_, _, en, pt, _) in enumerate(LINES):
            self.concepts[clean_text(en)] = {index}
            if pt == "+":
                pt_lines[-1][1].add(index)
            elif isinstance(pt, list):
                pt_lines.extend((part, {index}) for part in pt)
            elif pt:
                pt_lines.append((pt, {index}))
        for text, concept in pt_lines:
            self.concepts[clean_text(text)] = concept

    def embed(self, texts):
        vectors = []
        for text in texts:
            vector = [0.0] * (len(LINES) + 1)
            for index in self.concepts.get(text, {len(LINES)}):
                vector[index] = 1.0
            vectors.append(_normalize(vector))
        return vectors


class UnrelatedEmbedder:
    def embed(self, texts):
        return [_normalize([1.0 if i == n % 64 else 0.0 for i in range(64)]) for n, _ in enumerate(texts)]


def _timing_errors(result, expected, tolerance=0.3):
    return [
        (got.text, round(got.start - want.start, 2))
        for got, want in zip(result.cues, expected)
        if abs(got.start - want.start) > tolerance
    ]


def test_clean_text_removes_sdh_tags_and_speakers():
    assert clean_text("[door slams]") == ""
    assert clean_text("♪ Soft music playing ♪") == ""
    assert clean_text("<i>Hello there</i>") == "Hello there"
    assert clean_text("MARTHA: Where were you?") == "Where were you?"
    assert clean_text("- Then where?\n- Somewhere safe.") == "Then where? Somewhere safe."


def test_fixes_shifted_lines_without_touching_text():
    reference, subtitle, expected = build()
    result = refine_cues(subtitle, reference, ConceptEmbedder())

    assert result.verdict == "corrigivel"
    assert [c.text for c in result.cues] == [c.text for c in sorted(subtitle, key=lambda c: c.start)]
    assert _timing_errors(result, expected) == []
    assert result.report["offset_antes"]["fora_do_tempo"] == 5
    assert result.report["offset_depois"]["fora_do_tempo"] == 0
    assert result.report["grupos"].get("1:2") == 1
    assert result.report["grupos"].get("2:1") == 1


def test_small_jitter_is_left_alone():
    reference, subtitle, _ = build()
    result = refine_cues(subtitle, reference, ConceptEmbedder())
    jittered = next(c for c in subtitle if c.text == "Trabalhando.")  # +0,1 s
    assert next(c for c in result.cues if c.text == "Trabalhando.").start == jittered.start


def test_global_offset_plus_defects():
    reference, subtitle, expected = build()
    shifted = [Cue(c.start + 4, c.end + 4, c.text) for c in subtitle]
    result = refine_cues(shifted, reference, ConceptEmbedder())
    assert _timing_errors(result, expected) == []


def test_unrelated_reference_is_not_applied():
    reference, subtitle, _ = build()
    result = refine_cues(subtitle, reference, UnrelatedEmbedder())
    assert result.verdict == "baixa_confianca"
    assert result.changed == 0
    assert [(c.start, c.end) for c in result.cues] == [(c.start, c.end) for c in sorted(subtitle, key=lambda c: c.start)]


def test_short_reference_is_incompatible():
    reference, subtitle, _ = build()
    result = refine_cues(subtitle, reference[:5], ConceptEmbedder())
    assert result.verdict == "referencia_incompativel"


def test_already_synced_subtitle_keeps_starts():
    reference, _, expected = build()
    result = refine_cues(expected, reference, ConceptEmbedder())
    # Já sincronizada: os inícios não mudam; só falas rápidas demais ganham fim mais longo.
    assert [c.start for c in result.cues] == [c.start for c in expected]
    assert all(new.end >= old.end for new, old in zip(result.cues, expected))
    assert result.changed == result.report["leitura"]["estendidas"]
    assert refine_cues(result.cues, reference, ConceptEmbedder()).verdict == "sincronizada"


def test_refine_file_apply_keeps_backup_and_text(tmp_path):
    reference, subtitle, expected = build()
    pt_path = tmp_path / "Filme.pt-BR.srt"
    en_path = tmp_path / "ref.srt"
    pt_path.write_bytes(render_srt(subtitle).encode("cp1252"))  # Bazarr às vezes entrega ANSI
    en_path.write_text(render_srt(reference), encoding="utf-8")

    report = refine_file(str(pt_path), str(en_path), embedder=ConceptEmbedder(), apply=True)

    assert report["veredito"] == "corrigida"
    assert (tmp_path / "Filme.pt-BR.srt.pre-refine").read_bytes() == render_srt(subtitle).encode("cp1252")
    fixed = parse_srt(pt_path.read_text(encoding="utf-8"))
    assert [c.text for c in fixed] == [c.text for c in subtitle]
    assert max(abs(g.start - w.start) for g, w in zip(fixed, expected)) <= 0.3
    assert not list(tmp_path.glob("*.tmp"))


def test_refine_file_keeps_first_backup(tmp_path):
    reference, subtitle, _ = build()
    pt_path = tmp_path / "Filme.por.srt"
    en_path = tmp_path / "ref.srt"
    backup = tmp_path / "Filme.por.srt.pre-refine"
    pt_path.write_text(render_srt(subtitle), encoding="utf-8")
    en_path.write_text(render_srt(reference), encoding="utf-8")
    backup.write_text("original do Bazarr", encoding="utf-8")

    report = refine_file(str(pt_path), str(en_path), embedder=ConceptEmbedder(), apply=True)

    assert report["veredito"] == "corrigida"
    assert backup.read_text(encoding="utf-8") == "original do Bazarr"


def test_rejected_refine_reports_zero_changes(tmp_path):
    reference, subtitle, _ = build()
    pt_path = tmp_path / "Filme.por.srt"
    en_path = tmp_path / "ref.srt"
    pt_path.write_text(render_srt(subtitle), encoding="utf-8")
    en_path.write_text(render_srt(reference), encoding="utf-8")

    report = refine_file(str(pt_path), str(en_path), embedder=UnrelatedEmbedder(), apply=True)

    assert report["veredito"] == "baixa_confianca"
    assert report["alteradas"] == 0


def test_refine_file_audit_does_not_write(tmp_path):
    reference, subtitle, _ = build()
    pt_path = tmp_path / "Filme.por.srt"
    en_path = tmp_path / "ref.srt"
    original = render_srt(subtitle)
    pt_path.write_text(original, encoding="utf-8")
    en_path.write_text(render_srt(reference), encoding="utf-8")

    report = refine_file(str(pt_path), str(en_path), embedder=ConceptEmbedder(), apply=False)

    assert report["veredito"] == "corrigivel"
    assert pt_path.read_text(encoding="utf-8") == original
    assert not (tmp_path / "Filme.por.srt.pre-refine").exists()


def test_select_reference_stream_prefers_full_english_text():
    streams = [
        {"index": 2, "codec_name": "hdmv_pgs_subtitle", "tags": {"language": "eng"}},
        {"index": 3, "codec_name": "subrip", "tags": {"language": "eng", "title": "Forced"}},
        {"index": 4, "codec_name": "subrip", "tags": {"language": "por"}},
        {"index": 5, "codec_name": "subrip", "tags": {"language": "eng", "title": "SDH"}},
        {"index": 6, "codec_name": "subrip", "tags": {"language": "eng", "title": "English"}},
        {"index": 7, "codec_name": "subrip", "tags": {"language": "spa"}},
    ]
    assert select_reference_stream(streams)["index"] == 6
    assert select_reference_stream(streams[:4])["index"] == 5  # só SDH: serve (limpamos as marcações)
    assert select_reference_stream([streams[5]])["index"] == 7  # embeddings são multilíngues
    assert select_reference_stream(streams[:3]) is None


def _ollama_ready() -> bool:
    url = os.environ.get("LOCAL_AI_URL", "http://localhost:11434").rstrip("/")
    try:
        tags = httpx.get(f"{url}/api/tags", timeout=2).json()
    except Exception:
        return False
    return any(m.get("name", "").split(":")[0] == OllamaEmbedder().model for m in tags.get("models", []))


@pytest.mark.skipif(not _ollama_ready(), reason="Ollama com o modelo de embedding indisponível")
def test_real_embeddings_fix_scenario():
    os.environ.setdefault("LOCAL_AI_URL", "http://localhost:11434")
    reference, subtitle, expected = build()
    result = refine_cues(subtitle, reference, OllamaEmbedder(base_url=os.environ["LOCAL_AI_URL"]))
    assert result.verdict == "corrigivel"
    assert _timing_errors(result, expected) == []


# ------------------------------------------------------------------ #
# Tempo de leitura                                                     #
# ------------------------------------------------------------------ #
LONG_PT = "Tudo bem, então tá certo, a gente se vê amanhã."  # 47 caracteres → 2,76 s a 17 car/s


def test_reading_time_extends_end_into_free_gap():
    cues = [Cue(10.0, 10.8, LONG_PT), Cue(20.0, 21.0, "Oi.")]
    original = [Cue(10.0, 11.0, LONG_PT), Cue(20.0, 21.0, "Oi.")]

    extended = fit_reading_time(cues, original, [True, False])

    assert extended == 1
    assert cues[0].start == 10.0  # início (a sincronia) não muda quando há espaço depois
    assert cues[0].end == pytest.approx(10.0 + visible_chars(LONG_PT) / REFINE_MAX_CPS)
    assert (cues[1].start, cues[1].end) == (20.0, 21.0)


def test_reading_time_never_invades_next_cue_and_leads_in_at_most_02s():
    cues = [Cue(5.0, 8.0, "Antes."), Cue(8.5, 9.3, LONG_PT), Cue(10.0, 11.0, "Depois.")]
    original = [Cue(c.start, c.end, c.text) for c in cues]

    fit_reading_time(cues, original, [False, True, False])

    assert cues[1].end == pytest.approx(10.0 - MIN_GAP)
    assert cues[1].start == pytest.approx(8.5 - MAX_LEAD_IN)
    assert cues[1].start >= cues[0].end + MIN_GAP


def test_reading_time_keeps_input_duration_and_never_shrinks():
    cues = [Cue(30.0, 30.9, "Sim, claro."), Cue(40.0, 41.0, "Não.")]
    original = [Cue(29.0, 31.5, "Sim, claro."), Cue(40.0, 41.0, "Não.")]

    fit_reading_time(cues, original, [True, False])

    assert cues[0].end == pytest.approx(32.5)  # duração que a fala tinha (2,5 s)
    assert cues[1].end == 41.0  # já tinha tempo de sobra: não encurta


def test_reading_time_on_unmoved_cue_only_extends_end():
    cues = [Cue(9.0, 9.95, "Antes."), Cue(10.0, 10.5, LONG_PT), Cue(11.0, 12.0, "Depois.")]
    original = [Cue(c.start, c.end, c.text) for c in cues]

    fit_reading_time(cues, original, [False, False, False])

    assert cues[1].start == 10.0  # início não foi movido nesta passada: nunca recua
    assert cues[1].end == pytest.approx(11.0 - MIN_GAP)
    assert (cues[0].start, cues[0].end) == (9.0, 9.95)  # já tinha tempo de leitura


def test_reading_time_is_stable_across_passes():
    cues = [Cue(5.0, 8.0, "Antes."), Cue(8.5, 9.3, LONG_PT), Cue(10.0, 11.0, "Depois.")]
    fit_reading_time(cues, [Cue(c.start, c.end, c.text) for c in cues], [False, True, False])
    snapshot = [(c.start, c.end) for c in cues]

    fit_reading_time(cues, [Cue(c.start, c.end, c.text) for c in cues], [False, False, False])

    assert [(c.start, c.end) for c in cues] == snapshot


def test_refine_is_idempotent():
    reference, subtitle, _ = build()
    first = refine_cues(subtitle, reference, ConceptEmbedder())
    second = refine_cues(first.cues, reference, ConceptEmbedder())
    assert second.verdict == "sincronizada"
    assert second.changed == 0
