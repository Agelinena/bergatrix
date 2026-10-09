"""
Cenário realista para o refino: diálogo EN (referência embutida, tempo correto) e a
tradução PT feita para OUTRO release, com os defeitos típicos das legendas do Bazarr.

Cada linha: (início, fim, texto EN, texto PT, erro do tradutor em s).
- texto PT None  → tradutor omitiu a fala;
- texto PT "+"   → fala PT juntou esta EN com a ANTERIOR (1 PT : 2 EN);
- texto PT lista → fala EN dividida em várias falas PT (quebra diferente do inglês:
                   as partes começam no MEIO da fala EN, onde o trecho é dito).
O erro do tradutor é o deslocamento daquela fala no trabalho original (±0,1 s é estilo
de cronometragem; ±1,6–2,4 s são falas isoladas erradas).
"""

import random

from core.subtitle_refine import _normalize, clean_text
from core.subtitle_sync import Cue

LINES = [
    (12.0, 14.2, "<i>Previously on The Harbor...</i>", "<i>Anteriormente em The Harbor...</i>", 0.05),
    (15.1, 17.4, "We need to get out of here, now!", "Precisamos sair daqui, agora!", 0.0),
    (17.6, 19.0, "[door slams]", None, 0.0),
    (19.5, 21.8, "MARTHA: Where were you last night?", "Onde você estava ontem à noite?", -0.08),
    (22.0, 23.1, "Working.", "Trabalhando.", 0.1),
    (23.5, 26.9, "Working? The office was closed, I checked.", "Trabalhando? O escritório estava fechado, eu conferi.", 1.9),
    (27.2, 28.0, "Yeah.", None, 0.0),
    (28.4, 31.5, "I was at the warehouse with Daniel, going over the shipments.", "Eu estava no depósito com o Daniel, revisando os carregamentos.", 0.0),
    (32.0, 33.2, "I don't know.", "Eu não sei. Talvez amanhã.", 0.12),
    (33.3, 34.6, "Maybe tomorrow.", "+", 0.0),
    (35.5, 39.8, "He said he'd call me after the meeting, but he never did, and now nobody can find him.",
     ["Ele disse que ia me ligar depois da reunião,", "mas nunca ligou, e agora ninguém o encontra."], 0.0),
    (40.5, 42.0, "♪ Soft music playing ♪", None, 0.0),
    (42.5, 44.6, "Did you call the police?", "Você chamou a polícia?", -1.6),
    (45.0, 46.2, "No.", "Não.", 0.0),
    (46.5, 49.3, "Why not? He could be hurt!", "Por que não? Ele pode estar machucado!", 0.07),
    (49.8, 53.0, "Because the police are the ones looking for him.", "Porque é a polícia que está procurando por ele.", 0.0),
    (54.0, 56.1, "What?", "O quê?", 2.4),
    (56.5, 60.2, "I can't tell you. Not here.", "Não posso te contar. Aqui não.", 0.0),
    (61.0, 63.4, "- Then where?\n- Somewhere they can't hear us.", "- Então onde?\n- Num lugar onde não possam nos ouvir.", -0.1),
    (64.0, 65.1, "Okay.", "Tá bom.", 0.0),
    (66.0, 69.5, "Meet me at the old lighthouse at midnight. Come alone.", "Me encontre no velho farol à meia-noite. Venha sozinha.", 0.0),
    (70.0, 72.4, "And Martha? Don't trust anyone.", "E, Martha? Não confie em ninguém.", -2.1),
    (73.0, 75.5, "Not even you?", "Nem em você?", 0.0),
    (76.0, 78.8, "Especially not me.", "Principalmente em mim.", 0.09),
    (80.0, 82.2, "[thunder rumbles]", None, 0.0),
    (83.0, 86.1, "The storm is getting worse. We should close the shutters.", "A tempestade está piorando. Devíamos fechar as janelas.", 0.0),
    (86.5, 88.0, "I'll get the ladder.", "Vou pegar a escada.", 1.7),
    (88.5, 91.9, "Be careful, the steps are still broken from last winter.", "Cuidado, os degraus ainda estão quebrados desde o inverno passado.", 0.0),
    (92.5, 94.0, "I know, I know.", "Eu sei, eu sei.", 0.0),
    (95.0, 98.2, "Hey, have you seen my keys? I left them on the table.", "Ei, você viu minhas chaves? Deixei em cima da mesa.", -0.05),
]

# Falas cujo erro do tradutor o refino NÃO corrige, de propósito:
# - curta demais para ser âncora;
# - vizinha de uma fala EN omitida ("Yeah."): não dá para saber se a PT a contém.
UNFIXABLE = {"O quê?", "Trabalhando? O escritório estava fechado, eu conferi."}


def _tag(text: str, tag: str) -> str:
    return text + tag if tag and clean_text(text) else text


def build(base: float = 0.0, tag: str = ""):
    """
    Um bloco do diálogo começando em `base`. Retorna (referência, legenda PT como o
    tradutor entregou, tempos corretos da PT). `tag` deixa os textos únicos por bloco.
    """
    reference, subtitle, expected = [], [], []
    for start, end, en, pt, error in LINES:
        start, end = start + base, end + base
        reference.append(Cue(start, end, _tag(en, tag)))
        if pt is None:
            continue
        if pt == "+":
            # junta com a fala PT anterior: o fim esperado passa a ser o desta EN
            prev_sub, prev_exp = subtitle[-1], expected[-1]
            subtitle[-1] = Cue(prev_sub.start, end + error, prev_sub.text)
            expected[-1] = Cue(prev_exp.start, end, prev_exp.text)
            continue
        if isinstance(pt, list):
            step = (end - start) / len(pt)
            for n, part in enumerate(pt):
                text = _tag(part, tag)
                subtitle.append(Cue(start + n * step + error, start + (n + 1) * step + error, text))
                expected.append(Cue(start + n * step, start + (n + 1) * step, text))
            continue
        text = _tag(pt, tag)
        subtitle.append(Cue(start + error, end + error, text))
        expected.append(Cue(start, end, text))
    return reference, subtitle, expected


def release_offset(t: float, offset: float, drift: float, cut_at: float, cut: float) -> float:
    """Deslocamento verdadeiro (início da referência − início da PT) no instante t."""
    return offset + drift * t + (cut if t >= cut_at else 0.0)


def build_release(blocks: int = 6, period: float = 100.0, offset: float = -23.5,
                  drift: float = 0.0021, cut_at: float = 300.0, cut: float = 1.7):
    """
    Episódio de `blocks` blocos com a PT feita para outro release: deslocamento grande,
    deriva de velocidade (0,0021 ≈ 0,13 s/min) e um corte de comercial em `cut_at`.
    Retorna (referência, legenda PT como chega, tempos corretos da PT).
    """
    reference, subtitle, expected = [], [], []
    for b in range(blocks):
        ref_b, sub_b, exp_b = build(b * period, f" take{b}")
        reference += ref_b
        expected += exp_b
        for cue in sub_b:
            shift = release_offset(cue.start, offset, drift, cut_at, cut)
            subtitle.append(Cue(cue.start - shift, cue.end - shift, cue.text))
    return reference, subtitle, expected


class ConceptEmbedder:
    """Embedder falso: cada fala do cenário é um 'conceito' (vetor one-hot) por bloco."""

    def __init__(self, blocks: int = 6):
        self.size = len(LINES) * blocks + 1
        self.concepts = {}
        for b in range(blocks):
            tag, pt_lines = f" take{b}", []
            for index, (_, _, en, pt, _) in enumerate(LINES):
                concept = b * len(LINES) + index
                for variant in ({en, _tag(en, tag)} if b == 0 else {_tag(en, tag)}):
                    self.concepts[clean_text(variant)] = {concept}
                if pt == "+":
                    pt_lines[-1][1].add(concept)
                elif isinstance(pt, list):
                    pt_lines.extend((part, {concept}) for part in pt)
                elif pt:
                    pt_lines.append((pt, {concept}))
            for text, concept in pt_lines:
                for variant in ({text, _tag(text, tag)} if b == 0 else {_tag(text, tag)}):
                    self.concepts[clean_text(variant)] = concept

    def embed(self, texts):
        vectors = []
        for text in texts:
            vector = [0.0] * self.size
            for index in self.concepts.get(text, {self.size - 1}):
                vector[index] = 1.0
            vectors.append(_normalize(vector))
        return vectors


class UnrelatedEmbedder:
    """Conteúdo sem relação: vetor pseudoaleatório fixo por texto (quase ortogonais)."""

    def embed(self, texts):
        return [_normalize([random.Random(f"{text}:{i}").gauss(0, 1) for i in range(256)]) for text in texts]
