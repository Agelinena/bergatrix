import os

import httpx
import pytest

from core.subtitle_refine import (
    MIN_GAP,
    REFINE_MAX_CPS,
    OllamaEmbedder,
    clean_text,
    fit_reading_time,
    read_subtitle,
    refine_cues,
    refine_file,
    select_reference_stream,
    visible_chars,
)
from core.subtitle_sync import Cue, parse_srt, render_srt
from refine_scenario import UNFIXABLE, ConceptEmbedder, UnrelatedEmbedder, build, build_release


def _start_errors(cues, expected, tolerance=0.2, skip=()):
    """Falas cujo início ficou longe do momento em que são ditas."""
    return [
        (got.text[:40], round(got.start - want.start, 2))
        for got, want in zip(sorted(cues, key=lambda c: c.start), expected)
        if abs(got.start - want.start) > tolerance and not any(got.text.startswith(s) for s in skip)
    ]


def test_clean_text_removes_sdh_tags_and_speakers():
    assert clean_text("[door slams]") == ""
    assert clean_text("♪ Soft music playing ♪") == ""
    assert clean_text("<i>Hello there</i>") == "Hello there"
    assert clean_text("MARTHA: Where were you?") == "Where were you?"
    assert clean_text("- Then where?\n- Somewhere safe.") == "Then where? Somewhere safe."


# ------------------------------------------------------------------ #
# Legenda de outro release                                             #
# ------------------------------------------------------------------ #
def test_other_release_follows_offset_drift_and_cut():
    reference, subtitle, expected = build_release()
    result = refine_cues(subtitle, reference, ConceptEmbedder())

    assert result.verdict == "corrigivel"
    assert result.report["curva"]["aplicada"]
    assert [c.text for c in result.cues] == [c.text for c in sorted(subtitle, key=lambda c: c.start)]
    assert _start_errors(result.cues, expected, skip=UNFIXABLE) == []
    jumps = result.report["curva"]["saltos"]
    assert len(jumps) == 1 and jumps[0]["delta"] == pytest.approx(1.7, abs=0.2)


def test_split_lines_keep_translator_timing():
    # Quebra diferente do inglês: a 2ª parte é dita no MEIO da fala EN e deve ficar lá,
    # não ser puxada para o início dela.
    reference, subtitle, expected = build_release()
    result = refine_cues(subtitle, reference, ConceptEmbedder())
    second_parts = [c for c in result.cues if c.text.startswith("mas nunca ligou")]
    wanted = [c for c in expected if c.text.startswith("mas nunca ligou")]
    assert len(second_parts) == 6
    for got, want in zip(second_parts, wanted):
        assert got.start == pytest.approx(want.start, abs=0.2)


def test_merged_line_starts_with_first_reference_line():
    reference, subtitle, _ = build_release()
    result = refine_cues(subtitle, reference, ConceptEmbedder())
    merged = [c for c in result.cues if c.text.startswith("Eu não sei. Talvez amanhã.")]
    starts = [c.start for c in reference if c.text.startswith("I don't know.")]
    assert len(merged) == len(starts) == 6
    for cue, start in zip(merged, starts):
        assert cue.start == pytest.approx(start, abs=0.25)


def test_isolated_wrong_lines_are_adjusted_individually():
    reference, subtitle, expected = build_release()
    result = refine_cues(subtitle, reference, ConceptEmbedder())
    for text in ("Você chamou a polícia?", "E, Martha? Não confie em ninguém.", "Vou pegar a escada."):
        got = [c for c in result.cues if c.text.startswith(text)]
        want = [c for c in expected if c.text.startswith(text)]
        assert len(got) == 6
        assert all(abs(g.start - w.start) <= 0.05 for g, w in zip(got, want)), text
    assert result.report["ajustes_individuais_total"] == 18


def test_unfixable_lines_keep_translator_error():
    # Curta demais / vizinha de fala EN omitida: fica com o erro do tradutor (conservador).
    reference, subtitle, expected = build_release()
    result = refine_cues(subtitle, reference, ConceptEmbedder())
    for text, error in (("O quê?", 2.4), ("Trabalhando? O escritório", 1.9)):
        got = [c for c in result.cues if c.text.startswith(text)]
        want = [c for c in expected if c.text.startswith(text)]
        assert len(got) == 6
        assert all(abs(g.start - w.start - error) <= 0.2 for g, w in zip(got, want))


def test_already_synced_subtitle_keeps_starts():
    reference, _, expected = build_release()
    result = refine_cues(expected, reference, ConceptEmbedder())
    assert not result.report["curva"]["aplicada"]
    assert [c.start for c in result.cues] == [c.start for c in expected]
    assert result.changed == result.report["leitura"]["estendidas"]


def test_refine_is_idempotent():
    reference, subtitle, _ = build_release()
    first = refine_cues(subtitle, reference, ConceptEmbedder())
    second = refine_cues(first.cues, reference, ConceptEmbedder())
    assert second.verdict == "sincronizada"
    assert second.changed == 0


def test_unrelated_reference_is_not_applied():
    reference, subtitle, _ = build_release()
    result = refine_cues(subtitle, reference, UnrelatedEmbedder())
    assert result.verdict == "baixa_confianca"
    assert result.changed == 0
    assert [(c.start, c.end) for c in result.cues] == [(c.start, c.end) for c in sorted(subtitle, key=lambda c: c.start)]


def test_short_reference_is_incompatible():
    reference, subtitle, _ = build_release()
    result = refine_cues(subtitle, reference[:20], ConceptEmbedder())
    assert result.verdict == "referencia_incompativel"


def test_too_few_anchors_is_low_confidence():
    reference, subtitle, _ = build()  # trecho curto: poucas âncoras para estimar uma curva
    result = refine_cues(subtitle[:8], reference[:10], ConceptEmbedder())
    assert result.verdict == "baixa_confianca"


# ------------------------------------------------------------------ #
# Arquivos                                                             #
# ------------------------------------------------------------------ #
def _write_case(tmp_path, subtitle, reference, name="Filme.pt-BR.srt", encoding="utf-8"):
    pt_path, en_path = tmp_path / name, tmp_path / "ref.srt"
    pt_path.write_bytes(render_srt(subtitle).encode(encoding))
    en_path.write_text(render_srt(reference), encoding="utf-8")
    return pt_path, en_path


def test_refine_file_apply_keeps_backup_and_text(tmp_path):
    reference, subtitle, expected = build_release()
    pt_path, en_path = _write_case(tmp_path, subtitle, reference, encoding="cp1252")  # Bazarr às vezes entrega ANSI

    report = refine_file(str(pt_path), str(en_path), embedder=ConceptEmbedder(), apply=True)

    assert report["veredito"] == "corrigida"
    assert (tmp_path / "Filme.pt-BR.srt.pre-refine").read_bytes() == render_srt(subtitle).encode("cp1252")
    fixed = parse_srt(pt_path.read_text(encoding="utf-8"))
    assert [c.text for c in fixed] == [c.text for c in sorted(subtitle, key=lambda c: c.start)]
    assert _start_errors(fixed, expected, skip=UNFIXABLE) == []
    assert not list(tmp_path.glob("*.tmp"))


def test_refine_file_keeps_first_backup(tmp_path):
    reference, subtitle, _ = build_release()
    pt_path, en_path = _write_case(tmp_path, subtitle, reference, name="Filme.por.srt")
    backup = tmp_path / "Filme.por.srt.pre-refine"
    backup.write_text("original do Bazarr", encoding="utf-8")

    report = refine_file(str(pt_path), str(en_path), embedder=ConceptEmbedder(), apply=True)

    assert report["veredito"] == "corrigida"
    assert backup.read_text(encoding="utf-8") == "original do Bazarr"


def test_rejected_refine_reports_zero_changes(tmp_path):
    reference, subtitle, _ = build_release()
    pt_path, en_path = _write_case(tmp_path, subtitle, reference, name="Filme.por.srt")

    report = refine_file(str(pt_path), str(en_path), embedder=UnrelatedEmbedder(), apply=True)

    assert report["veredito"] == "baixa_confianca"
    assert report["alteradas"] == 0


def test_refine_file_audit_does_not_write(tmp_path):
    reference, subtitle, _ = build_release()
    pt_path, en_path = _write_case(tmp_path, subtitle, reference, name="Filme.por.srt")
    original = pt_path.read_text(encoding="utf-8")

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


# ------------------------------------------------------------------ #
# Tempo de leitura                                                     #
# ------------------------------------------------------------------ #
LONG_PT = "Tudo bem, então tá certo, a gente se vê amanhã."  # 47 caracteres → 2,76 s a 17 car/s


def test_reading_time_extends_end_into_silence():
    cues = [Cue(10.0, 10.8, LONG_PT), Cue(20.0, 21.0, "Oi.")]

    extended = fit_reading_time(cues, [10.0, 20.0])

    assert extended == 1
    assert cues[0].start == 10.0  # o início (a sincronia) nunca muda
    assert cues[0].end == pytest.approx(10.0 + visible_chars(LONG_PT) / REFINE_MAX_CPS)
    assert (cues[1].start, cues[1].end) == (20.0, 21.0)


def test_reading_time_stops_where_someone_else_speaks():
    # Silêncio na legenda PT não é silêncio no vídeo: outra fala da referência começa em 11,5.
    cues = [Cue(10.0, 10.8, LONG_PT), Cue(20.0, 21.0, "Oi.")]
    fit_reading_time(cues, [10.0, 11.5, 20.0])
    assert cues[0].end == pytest.approx(11.5 - MIN_GAP)


def test_reading_time_never_invades_next_cue():
    cues = [Cue(10.0, 10.8, LONG_PT), Cue(11.0, 12.0, "Depois.")]
    fit_reading_time(cues, [10.0, 11.0])
    assert cues[0].end == pytest.approx(11.0 - MIN_GAP)


def test_reading_time_never_shrinks_and_is_stable():
    cues = [Cue(5.0, 9.0, "Sim."), Cue(10.0, 10.5, LONG_PT), Cue(30.0, 31.0, "Não.")]
    fit_reading_time(cues, [5.0, 10.0, 30.0])
    snapshot = [(c.start, c.end) for c in cues]
    assert snapshot[0] == (5.0, 9.0)

    assert fit_reading_time(cues, [5.0, 10.0, 30.0]) == 0
    assert [(c.start, c.end) for c in cues] == snapshot


# ------------------------------------------------------------------ #
# Integração com o Ollama (opcional)                                   #
# ------------------------------------------------------------------ #
def _ollama_ready() -> bool:
    url = os.environ.get("LOCAL_AI_URL", "http://localhost:11434").rstrip("/")
    try:
        tags = httpx.get(f"{url}/api/tags", timeout=2).json()
    except Exception:
        return False
    return any(m.get("name", "").split(":")[0] == OllamaEmbedder().model for m in tags.get("models", []))


def _embedder():
    return OllamaEmbedder(base_url=os.environ.get("LOCAL_AI_URL", "http://localhost:11434"))


@pytest.mark.skipif(not _ollama_ready(), reason="Ollama com o modelo de embedding indisponível")
def test_real_embeddings_follow_other_release():
    reference, subtitle, expected = build_release(blocks=4, cut_at=200.0)
    result = refine_cues(subtitle, reference, _embedder())
    assert result.verdict == "corrigivel"
    errors = _start_errors(result.cues, expected, tolerance=0.3, skip=UNFIXABLE)
    assert len(errors) <= 0.05 * len(expected), errors


# Episódio real (Dietland S01E04): legenda PT do release HDTV × legenda embutida do WEB-DL.
# Aponte REFINE_REAL_CASE para uma pasta com orig.srt (PT do Bazarr, sem refino) e en.srt.
# Cada item: começo do texto PT e o instante em que a fala é dita no WEB-DL.
REAL_CHECKPOINTS = [
    ("Em últimas notícias", "01:45.540"), ("Eu teria comprado algo", "06:39.399"),
    ("A questão é, resumindo", "08:36.341"), ("O que é pior?", "09:28.916"),
    ("Eu me sinto tonta", "10:38.072"), ("Eu entendo, mas é besteira", "12:19.477"),
    ("Que seja. Assim que eu", "12:44.807"), ("Pó, bronzeador, pincéis", "16:34.776"),
    ("Entendo. Eu vou me limpar", "18:12.961"), ("Guarde um pouco para o bolo", "19:41.571"),
    ("Está tudo bem. Estou bem", "21:20.191"), ("Você deveria andar de bicicleta", "25:05.416"),
    ("Com todo respeito a sua", "34:15.183"), ("Eu queria te perguntar uma", "36:30.666"),
    ("Parei de transar com você antes", "40:36.129"), ("Naquela época", "41:53.075"),
    ("Obrigada, Frank", "38:19.906"), ("Dinheiro do setor privado", "06:46.231"),
    ("A World Daily Media divulgou", "00:53.618"), ("O que ela disse?", "00:18.453"),
    ("Não ligo se são estupradores", "02:14.917"),
]
# Quebra diferente do inglês: o trecho é dito no meio da fala EN que começa no instante dado.
REAL_SPLITS = [
    ("mas os deles são piores", "00:46.742"), ("É impossível que seja", "03:08.275"),
    ("não parecia uma realidade", "03:56.932"), ("com a minha relação com Ameixa", "27:59.721"),
    ("os dos professores", "25:31.225"),
]


@pytest.mark.skipif(
    not os.environ.get("REFINE_REAL_CASE") or not _ollama_ready(),
    reason="defina REFINE_REAL_CASE (pasta com orig.srt e en.srt) e tenha o Ollama disponível",
)
def test_real_episode_other_release():
    folder = os.environ["REFINE_REAL_CASE"]
    original = parse_srt(read_subtitle(os.path.join(folder, "orig.srt")))
    reference = parse_srt(read_subtitle(os.path.join(folder, "en.srt")))
    result = refine_cues(original, reference, _embedder())

    def seconds(value):
        minutes, rest = value.split(":")
        return int(minutes) * 60 + float(rest)

    def find(prefix):
        hits = [c for c in result.cues if clean_text(c.text).startswith(prefix)]
        assert len(hits) == 1, prefix
        return hits[0]

    assert result.verdict == "corrigivel"
    misses = [(p, round(find(p).start - seconds(t), 2)) for p, t in REAL_CHECKPOINTS
              if abs(find(p).start - seconds(t)) > 0.4]
    assert len(misses) <= 2, misses
    snapped = [p for p, t in REAL_SPLITS if abs(find(p).start - seconds(t)) < 0.5]
    assert snapped == []
