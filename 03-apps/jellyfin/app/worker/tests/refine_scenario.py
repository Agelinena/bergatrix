"""
Cenário realista para o refino: diálogo EN (referência embutida, tempo correto) e
tradução PT "quase certa" com os defeitos típicos das legendas do Bazarr.

Cada linha: (início, fim, texto EN, texto PT, deslocamento PT em s).
- texto EN None  → fala só existe na PT (não ocorre aqui, reservado);
- texto PT None  → tradutor omitiu a fala;
- texto PT "+"   → fala PT juntou esta EN com a ANTERIOR (1 PT : 2 EN);
- texto PT lista → fala EN dividida em várias falas PT (2 PT : 1 EN).
"""

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
    (54.0, 56.1, "What did he do?", "O que ele fez?", 2.4),
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


def build():
    """Retorna (referência, legenda PT deslocada, tempos corretos esperados da PT)."""
    reference, subtitle, expected = [], [], []
    for start, end, en, pt, shift in LINES:
        reference.append(Cue(start, end, en))
        if pt is None:
            continue
        if pt == "+":
            # junta com a fala PT anterior: o fim esperado passa a ser o desta EN
            prev_sub, prev_exp = subtitle[-1], expected[-1]
            subtitle[-1] = Cue(prev_sub.start, end + shift, prev_sub.text)
            expected[-1] = Cue(prev_exp.start, end, prev_exp.text)
            continue
        if isinstance(pt, list):
            step = (end - start) / len(pt)
            for n, part in enumerate(pt):
                subtitle.append(Cue(start + n * step + shift, start + (n + 1) * step + shift, part))
                expected.append(Cue(start + n * step, start + (n + 1) * step, part))
            continue
        subtitle.append(Cue(start + shift, end + shift, pt))
        expected.append(Cue(start, end, pt))
    return reference, subtitle, expected
