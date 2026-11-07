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


def test_feed_guesses():
    g1 = discovery.guesses("https://g1.globo.com/")
    assert "https://g1.globo.com/rss/g1/" in g1
    bbc = discovery.guesses("https://www.bbc.com/portuguese")
    assert bbc[0] == "https://www.bbc.com/portuguese/index.xml"
    folha = discovery.guesses("https://www.folha.uol.com.br/")
    assert folha[0] == "https://feeds.folha.uol.com.br/emcimadahora/rss091.xml"
    assert len(folha) == len(set(folha))


def test_drop_leading_title():
    html = "<h1>Congresso aprova o orçamento</h1><p>Texto da matéria.</p>"
    assert h.drop_leading_title(html, "Congresso aprova o orçamento") == "<p>Texto da matéria.</p>"
    # Outro título no começo fica; parágrafo só sai se for igual.
    assert h.drop_leading_title("<h2>Entenda</h2><p>x</p>", "Congresso aprova") .startswith("<h2>")
    assert h.drop_leading_title("<p>Ministros do STF articulam</p><p>y</p>",
                                "Ministros do STF articulam") == "<p>y</p>"


def test_item_without_title_uses_description():
    rss = b"""<?xml version="1.0"?><rss version="2.0"><channel><title>UOL</title>
      <item><description><![CDATA[ Ministros do STF articulam reeleicao. Mais detalhes aqui. ]]></description>
      <link>https://noticias.uol.com.br/x.htm</link><guid>https://noticias.uol.com.br/x.htm</guid></item>
      </channel></rss>"""
    feed = parse.parse(rss, "https://www.uol.com.br/feed")
    assert feed.entries[0].title == "Ministros do STF articulam reeleicao."


def test_canonical_url():
    from app.core.urls import canonical
    folha = ("https://redir.folha.com.br/redir/online/emcimadahora/rss091/*"
             "https://www1.folha.uol.com.br/colunas/x/2026/11/eleicao.shtml")
    assert canonical(folha) == "https://www1.folha.uol.com.br/colunas/x/2026/11/eleicao.shtml"
    assert canonical("https://Site.example.com/a?utm_source=rss&id=3#topo") == "https://site.example.com/a?id=3"


def test_publish_dates():
    from datetime import datetime, timedelta, timezone
    from types import SimpleNamespace
    from app.feeds.store import publish_dates
    now = datetime(2026, 11, 7, 12, tzinfo=timezone.utc)
    e = lambda d: SimpleNamespace(published_at=d)  # noqa: E731
    dated = now - timedelta(hours=3)
    first = publish_dates([e(None), e(dated), e(None)], True, now)
    # Primeira coleta: sem data vai para depois do mais antigo datado.
    assert first[1] == dated and first[0] < dated and first[2] < first[0]
    later = publish_dates([e(None)], False, now)
    assert later[0] == now
    # Mais velho que a retenção: não entra.
    assert publish_dates([e(now - timedelta(days=4000))], False, now) == [None]


def test_fix_future_timezone():
    from datetime import datetime, timedelta, timezone
    from app.feeds.store import fix_future
    now = datetime(2026, 11, 7, 13, 50, tzinfo=timezone.utc)  # 10:50 em Brasília
    # UOL: 13:35 "-0300" (= 16:35 UTC) para uma matéria das 10:35 de Brasília.
    wrong = datetime(2026, 11, 7, 16, 35, tzinfo=timezone.utc)
    assert fix_future(wrong, now) == datetime(2026, 11, 7, 13, 35, tzinfo=timezone.utc)
    assert fix_future(now + timedelta(minutes=2), now) == now + timedelta(minutes=2)
    assert fix_future(now + timedelta(days=3), now) == now


def test_drops_player_menus():
    html = ("<p>Texto.</p><ul><li>0.5×</li><li>1×</li><li>2×</li></ul>"
            "<ul><li>Ana</li><li>Bia</li></ul><ol><li>1</li><li>2</li></ol>")
    clean = h.sanitize(html)
    assert "0.5" not in clean and "<ol>" not in clean
    assert "<li>Ana</li>" in clean


def test_trafilatura_images_and_double_title():
    raw = ('<html><body><h1>O que está por trás</h1><p><strong>O que está por trás</strong></p>'
           '<graphic src="https://img.example.com/a.jpg" alt="Foto"/><p>Texto <b>forte</b>.</p></body></html>')
    clean = h.drop_leading_title(h.sanitize(h.trafilatura_images(raw), "https://x.example.com/"),
                                 "O que está por trás")
    assert clean.startswith('<img src="https://img.example.com/a.jpg"')
    assert "<b>forte</b>" in clean and "<h1>" not in clean and "<strong>O que" not in clean


def test_extract_keeps_images_and_paragraphs():
    from worker.fetcher import _extract
    para = ("O Congresso Nacional aprovou nesta quarta-feira a proposta que muda as regras do "
            "orçamento, depois de uma longa negociação entre governo e oposição. ")
    page = f"""<html><body><article><h1>Congresso aprova</h1><p>{para * 3}</p>
      <figure><img src="/fotos/plenario.jpg" alt="Plenário"><figcaption>Plenário</figcaption></figure>
      <p><strong>Destaque:</strong> {para * 2}</p><h2>Próximos passos</h2><p>{para * 2}</p>
      </article></body></html>""".encode()
    html, text = _extract(page, "https://jornal.example.com/politica/1")
    assert 'src="https://jornal.example.com/fotos/plenario.jpg"' in html
    assert html.count("<p>") >= 3 and "<h2>" in html


def test_extract_amp_images():
    from worker.fetcher import _extract
    para = ("Chuvas intensas voltaram a causar estragos no Oeste de Santa Catarina na manhã deste "
            "sábado, segundo a Defesa Civil, que confirmou tornados na região durante a semana. ")
    page = f"""<html><body><article><h1>Cidades alagadas</h1>
      <figure><amp-img src="https://img.example.com/foto.jpeg" alt="Temporais causam estragos"
        width="1600" height="900" layout="responsive"></amp-img>
        <figcaption>Temporais causam estragos</figcaption></figure>
      <p>{para * 3}</p><p>{para * 3}</p></article></body></html>""".encode()
    html, _ = _extract(page, "https://g1.example.com/sc/noticia.ghtml")
    assert 'src="https://img.example.com/foto.jpeg"' in html


# ── Vídeos, reextração, retenção ────────────────────────────────────

def test_globo_video_thumb_becomes_card():
    from app.core import videos
    html = '<p><img src="https://s03.video.glbimg.com/x240/15141862.jpg" alt="Conheça o navio"></p>'
    out = videos.globo_thumbs_to_cards(html)
    assert 'href="https://globoplay.globo.com/v/15141862/"' in out and 'title="berganews:video"' in out
    # O cartão sobrevive à limpeza do HTML.
    assert 'title="berganews:video"' in h.sanitize(out)


def test_video_embeds_and_page_video():
    from app.core import videos
    page = (b'<html><head><meta property="og:type" content="video.other">'
            b'<meta property="og:image" content="/thumb.jpg"><meta property="og:title" content="Boletim">'
            b'</head><body><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0"></iframe>'
            b'<a href="https://youtube.com/embed/AAAAAAAAAAA">rodape</a></body></html>')
    assert videos.embeds(page) == [("https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                                    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")]
    url, thumb, title = videos.page_video(page, "https://g1.example.com/videos/x.ghtml")
    assert thumb == "https://g1.example.com/thumb.jpg" and title == "Boletim"
    assert videos.page_video(b"<html></html>", "https://g1.example.com/noticia/x.ghtml") is None
    out = videos.add_embeds("<p>texto</p>", page)
    assert out.count("berganews:video") == 1 and "Vídeos da matéria" in out


def test_choose_keeps_partial_and_video():
    from worker.fetcher import _choose
    row = {"summary": "Trecho curto do RSS.", "title": "Manchete"}
    long_text = "x" * 500
    assert _choose(row, "<p>" + long_text + "</p>", long_text, None, None)[0] == "ok"
    # Começo da matéria (paywall): fica guardado como 'short'.
    partial = "Começo da matéria com mais texto que o trecho do RSS, por causa do paywall do site."
    st, html = _choose(row, f"<p>{partial}</p>", partial, None, None)
    assert st == "short" and partial in html
    # Página de vídeo sem texto: cartão + trecho.
    st, html = _choose(row, "", "", ("https://v.example.com/1", None, "Boletim"), None)
    assert st == "ok" and "berganews:video" in html and "Trecho curto" in html
    # Sem nada da página: o texto do feed.
    st, html = _choose(row, "", "", None, "<p>" + "y" * 500 + "</p>")
    assert st == "ok"


def test_stale_feed():
    from datetime import datetime, timezone
    from types import SimpleNamespace
    from app.feeds.routes import stale_since
    old = SimpleNamespace(entries=[SimpleNamespace(published_at=datetime(2023, 5, 5, tzinfo=timezone.utc))] * 3)
    assert stale_since(old).year == 2023
    alive = SimpleNamespace(entries=[SimpleNamespace(published_at=datetime.now(timezone.utc))])
    assert stale_since(alive) is None


def test_image_cache_prune(tmp_path, monkeypatch):
    from app.config import settings
    from app.images import cache
    monkeypatch.setattr(settings, "image_cache_dir", str(tmp_path))
    keep, drop = "https://img.example.com/salva.jpg", "https://img.example.com/velha.jpg"
    cache.store(keep, "image/jpeg", b"a")
    cache.store(drop, "image/jpeg", b"b")
    html = f'<p><img src="{keep}"></p>'
    in_use = {cache.digest(u) for u in cache.urls_in(html)}
    assert cache.prune(in_use) == 1
    assert cache.cached(keep) and not cache.cached(drop)


def test_globo_generic_video_removed():
    from app.core import videos
    html = ('<p><img src="https://s01.video.glbimg.com/x240/1.jpg" alt="Agora no g1"></p>'
            '<p>Agora no g1</p><p>Texto</p>')
    out = videos.globo_thumbs_to_cards(html)
    assert "glbimg" not in out and "Agora no g1" not in out and "<p>Texto</p>" in out
