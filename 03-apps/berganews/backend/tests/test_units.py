"""Testes sem banco nem rede: python -m pytest tests"""
from __future__ import annotations

import os

os.environ.setdefault("JWT_SECRET", "teste")
os.environ.setdefault("TRANSLATE_LANGUAGES", "pt,en")

import pytest  # noqa: E402

from app.articles.routes import _cursor, _parse_cursor, translate_target  # noqa: E402
from app.core import html as h, http, keys, lang  # noqa: E402
from app.feeds import discovery, opml, parse  # noqa: E402
from app.prefs.routes import merge  # noqa: E402
from worker.ai import leaf_blocks, replace_text  # noqa: E402

RSS = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"
     xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel><title>Jornal Teste</title><link>https://jornal.example.com/</link>
<language>pt-br</language>
<item><title>Senado aprova projeto</title><link>/politica/1</link><guid>abc-1</guid>
<pubDate>Thu, 05 Nov 2026 12:00:00 -0300</pubDate>
<description>&lt;p&gt;O Senado aprovou &lt;b&gt;ontem&lt;/b&gt; o projeto.&lt;/p&gt;&lt;script&gt;x()&lt;/script&gt;</description>
<media:content url="https://img.example.com/1.jpg" medium="image"/></item>
<item><title>Sem link</title><guid>abc-2</guid></item>
</channel></rss>"""


def test_parse_rss():
    feed = parse.parse(RSS, "https://jornal.example.com/feed")
    assert feed.title == "Jornal Teste"
    assert feed.language == "pt-br"
    first = feed.entries[0]
    assert first.url == "https://jornal.example.com/politica/1"
    assert first.guid == "abc-1"
    assert first.image_url == "https://img.example.com/1.jpg"
    assert "x()" not in (first.summary or "")
    assert first.published_at.isoformat() == "2026-11-05T15:00:00+00:00"
    assert feed.entries[1].title == "Sem link"


def test_not_a_feed():
    with pytest.raises(parse.NotAFeed):
        parse.parse(b"<html><body>oi</body></html>", "https://x.example.com")


def test_sanitize_removes_scripts_and_fixes_images():
    dirty = ('<div onclick="x()"><p style="color:red">Texto <a href="/a">link</a></p>'
             '<script>alert(1)</script><img data-src="/i.jpg" src="data:image/gif;base64,AA">'
             '<iframe src="https://ads.example.com"></iframe><p></p></div>')
    clean = h.sanitize(dirty, "https://site.example.com/materia")
    assert "script" not in clean and "alert" not in clean and "iframe" not in clean
    assert "onclick" not in clean and "style" not in clean
    assert 'href="https://site.example.com/a"' in clean
    assert 'src="https://site.example.com/i.jpg"' in clean
    assert 'rel="noopener noreferrer nofollow"' in clean
    assert "<p></p>" not in clean


def test_serialize_escapes_leading_text():
    assert "&lt;b&gt;" in h.serialize_children(h.fragment("1 &lt;b&gt; 2<p>x</p>"))


def test_to_text_and_images():
    html = "<h2>Título</h2><p>Um   parágrafo.</p><ul><li>a</li><li>b</li></ul>"
    assert h.to_text(html) == "Título\nUm parágrafo.\na\nb"
    proxied = h.proxy_images('<p><img src="https://img.example.com/x.png"></p>')
    assert "/api/img?u=https%3A%2F%2Fimg.example.com%2Fx.png&amp;s=" in proxied


def test_image_signature():
    url = "https://img.example.com/x.png"
    assert keys.verify("img", url, keys.sign("img", url))
    assert not keys.verify("img", url + "?", keys.sign("img", url))


def test_check_url():
    assert http.check_url(" https://a.example.com/feed ") == "https://a.example.com/feed"
    for bad in ("file:///etc/passwd", "ftp://x", "https://user:pw@x.example.com", "javascript:x"):
        with pytest.raises(http.FetchError):
            http.check_url(bad)


def test_feed_links():
    page = b"""<html><head>
      <link rel="alternate" type="application/rss+xml" href="/rss.xml">
      <link rel="alternate" type="text/html" href="/outra">
      <link rel="alternate" type="application/atom+xml" href="https://b.example.com/atom">
    </head></html>"""
    assert discovery.feed_links(page, "https://a.example.com/x") == [
        "https://a.example.com/rss.xml", "https://b.example.com/atom"]


def test_opml_roundtrip():
    src = b"""<?xml version="1.0"?><opml version="2.0"><head/><body>
      <outline text="Brasil"><outline text="G1" xmlUrl="https://g1.example.com/rss"/>
        <outline text="Sub"><outline text="Folha" xmlUrl="https://folha.example.com/rss"/></outline>
      </outline>
      <outline text="Solto" xmlUrl="https://solto.example.com/feed"/>
      <outline text="Ruim" xmlUrl="file:///etc/passwd"/>
    </body></opml>"""
    items = opml.parse(src)
    assert [(i.url, i.folder) for i in items] == [
        ("https://g1.example.com/rss", "Brasil"),
        ("https://folha.example.com/rss", "Brasil"),
        ("https://solto.example.com/feed", None),
    ]
    out = opml.parse(opml.build("Lucas", [(i.folder, i.title, i.url, None) for i in items]))
    assert [(i.url, i.folder) for i in out] == [(i.url, i.folder) for i in items]


def test_opml_rejects_entities():
    bomb = b"""<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]>
      <opml><body><outline text="&a;" xmlUrl="https://x.example.com"/></body></opml>"""
    with pytest.raises(opml.OpmlError):
        opml.parse(bomb)


def test_prefs_merge():
    prefs = merge({"tabs": [{"id": "saved", "enabled": True}, {"id": "stories", "enabled": True},
                            {"id": "nope", "enabled": True}], "theme": "dark"})
    ids = [t.id for t in prefs.tabs]
    assert ids[:2] == ["saved", "stories"] and set(ids) == {"all", "sources", "folders",
                                                            "stories", "saved"}
    assert prefs.tabs[1].enabled and prefs.tabs[1].available  # histórias (fase 2)
    assert prefs.theme == "dark" and prefs.language == "pt"
    # Tudo desligado: a primeira aba volta a ligar (o app nunca fica sem aba).
    none = merge({"tabs": [{"id": t, "enabled": False}
                           for t in ("sources", "all", "folders", "stories", "saved")]})
    assert none.tabs[0].id == "sources" and none.tabs[0].enabled
    assert sum(t.enabled for t in none.tabs) == 1


def test_translate_target():
    assert translate_target("en", "pt") == "pt"
    assert translate_target("pt", "pt") == "en"
    assert translate_target(None, "pt") == "pt"


def test_cursor_roundtrip():
    from datetime import datetime, timezone
    when = datetime(2026, 11, 6, 10, 0, tzinfo=timezone.utc)
    assert _parse_cursor(_cursor(when, 42)) == (when, 42)


def test_language_detection():
    assert lang.detect("O governo federal anunciou nesta quinta-feira um novo pacote de medidas "
                       "para conter a alta dos preços dos alimentos.") == "pt"
    assert lang.detect("The federal government announced on Thursday a new package of measures "
                       "to curb rising food prices across the country.") == "en"
    assert lang.detect("curto", "en-US") == "en"


def test_translation_blocks_keep_images():
    root = h.fragment('<ul><li><p>Um</p></li></ul><figure><img src="https://i.example.com/a.jpg">'
                      '<figcaption>Legenda</figcaption></figure><p>Dois <b>negrito</b>'
                      '<img src="https://i.example.com/b.jpg"></p><p>2026</p>')
    blocks = leaf_blocks(root)
    assert [b.tag for b in blocks] == ["p", "figcaption", "p"]
    replace_text(blocks[2], "Two bold")
    out = h.serialize_children(root)
    assert "Two bold<img" in out and "a.jpg" in out


def test_extract_full_text():
    from worker.fetcher import _extract
    para = ("O Congresso Nacional aprovou nesta quarta-feira a proposta que muda as regras do "
            "orçamento, depois de uma longa negociação entre governo e oposição. ")
    page = f"""<html><head><title>Notícia</title></head><body>
      <nav><a href="/">Início</a><a href="/politica">Política</a></nav>
      <div class="ad">ANÚNCIO COMPRE JÁ</div>
      <article><h1>Congresso aprova orçamento</h1>
        <p>{para * 3}</p><figure><img src="/fotos/plenario.jpg" alt="Plenário">
        <figcaption>Plenário da Câmara</figcaption></figure><p>{para * 3}</p></article>
      <footer>Todos os direitos reservados</footer></body></html>""".encode()
    html, text = _extract(page, "https://jornal.example.com/politica/1")
    assert "Congresso Nacional aprovou" in text and len(text) > 600
    assert "ANÚNCIO" not in text and "direitos reservados" not in text
    assert "script" not in html


# ── Fase 2: histórias ───────────────────────────────────────────────

def test_entities():
    from app.stories.entities import extract, overlap
    names = extract("Lula e Haddad discutem reforma no Supremo Tribunal Federal. O STF decide "
                    "amanhã. Segundo o Banco do Brasil, a taxa sobe.")
    assert "lula" in names and "haddad" in names
    assert "supremo tribunal federal" in names and "stf" in names
    assert "banco do brasil" in names
    assert "o" not in names and "segundo" not in names
    assert overlap(["luiz inacio lula da silva"], ["lula"])
    assert not overlap(["haddad"], ["tarcisio"])


def _cand(story, sim, lang="pt", entities=()):
    return {"story_id": story, "similarity": sim, "language": lang, "entities": list(entities)}


def test_decide():
    from app.stories.cluster import decide
    # Abaixo do limite: história nova.
    assert decide([_cand(1, 0.70, entities=["lula"])], "pt", ["lula"]).story_id is None
    # Acima do limite, mesmo idioma, nome em comum: entra, sem virar base.
    d = decide([_cand(1, 0.80, entities=["lula", "stf"])], "pt", ["stf"])
    assert d.story_id == 1 and not d.seed
    # Mesmo idioma sem nome em comum: não entra (efeito corrente).
    assert decide([_cand(1, 0.80, entities=["haddad"])], "pt", ["tarcisio"]).story_id is None
    # Muito parecido: entra sem checar entidade, e vira base.
    d = decide([_cand(1, 0.92, entities=["haddad"])], "pt", ["tarcisio"])
    assert d.story_id == 1 and d.seed
    # Outro idioma: não dá para comparar os nomes ("EUA" × "United States").
    assert decide([_cand(1, 0.80, lang="en", entities=["united states"])], "pt", ["eua"]).story_id == 1
    # Pega a primeira candidata que passa (a lista vem da mais parecida).
    d = decide([_cand(1, 0.85, entities=["x"]), _cand(2, 0.81, entities=["lula"])], "pt", ["lula"])
    assert d.story_id == 2


def test_calibration_score():
    from app.stories.routes import score
    pairs = [(0.95, True), (0.85, True), (0.80, False), (0.70, False), (0.82, True)]
    table = {round(r.threshold, 2): r for r in score(pairs)}
    assert table[0.81].precision == 1.0 and table[0.81].recall == 1.0
    assert table[0.75].precision == 0.75
    assert table[0.90].recall == round(1 / 3, 3)


def test_embed_text_and_vector():
    from app.stories.embed import text_for, vector_literal
    row = {"title": "Manchete", "summary": "trecho", "content_text": "x" * 2000}
    text = text_for(row)
    assert text.startswith("Manchete\nxxx") and len(text) == len("Manchete\n") + 900
    assert vector_literal([0.1, -0.25]) == "[0.100000,-0.250000]"
