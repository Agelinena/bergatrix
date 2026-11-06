"""Teste de integração com Postgres de verdade (pgserver, com pgvector), sem Docker.

    pip install -r requirements.txt pgserver
    python tests/integration_pgserver.py . /tmp/berganews-pg
"""
import asyncio
import os
import pathlib
import random
import shutil
import sys

BACKEND = pathlib.Path(sys.argv[1])
DATA = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(BACKEND))
os.environ["JWT_SECRET"] = "teste"

import pgserver  # noqa: E402

shutil.rmtree(DATA, ignore_errors=True)
srv = pgserver.get_server(str(DATA), cleanup_mode="stop")
os.environ["DATABASE_URL"] = srv.get_uri()

import asyncpg  # noqa: E402

from app.auth.dependencies import CurrentUser  # noqa: E402
from app.core import db  # noqa: E402
from app.feeds import parse, store  # noqa: E402


class FakeRedis:
    def __init__(self):
        self.kv, self.lists = {}, {}

    async def set(self, k, v, ex=None, nx=False):
        if nx and k in self.kv:
            return None
        self.kv[k] = str(v)
        return True

    async def get(self, k):
        return self.kv.get(k)

    async def getdel(self, k):
        return self.kv.pop(k, None)

    async def delete(self, k):
        self.kv.pop(k, None)

    async def rpush(self, k, v):
        self.lists.setdefault(k, []).append(str(v))


def rss(name, items):
    body = "".join(
        f"<item><title>{t}</title><link>https://{name}.example.com/{i}</link><guid>{name}-{i}</guid>"
        f"<pubDate>Fri, 06 Nov 2026 1{i}:00:00 -0300</pubDate><description>{d}</description></item>"
        for i, (t, d) in enumerate(items))
    return (f'<?xml version="1.0"?><rss version="2.0"><channel><title>{name.title()}</title>'
            f"<link>https://{name}.example.com/</link><language>pt-br</language>{body}</channel></rss>").encode()


def vec(base, noise):
    v = [b + random.gauss(0, noise) for b in base]
    n = sum(x * x for x in v) ** 0.5
    return v


async def main():
    for mig in sorted((BACKEND / "db/migrations").glob("*.sql")):
        up = mig.read_text(encoding="utf-8").split("-- migrate:down")[0].replace("-- migrate:up", "")
        # pgserver não tem o contrib unaccent (a imagem oficial tem): troca só no teste.
        up = up.replace("CREATE EXTENSION IF NOT EXISTS unaccent;", "").replace(
            "$$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $$",
            "$$ SELECT translate($1, 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouucAAAAEEIOOOUC') $$")
        conn = await asyncpg.connect(os.environ["DATABASE_URL"])
        await conn.execute(up)
        await conn.close()
        print("migração ok:", mig.name)

    import app.core.redis as rmod
    fake = FakeRedis()
    rmod._pool = fake
    pool = await db.create_pool()

    from app.auth import oidc
    ident = oidc.Identity(subject="sub-1", username="lucas", email="l@example.com",
                          name="Lucas", groups=("berganews_users", "berganews_admins"))
    user = await oidc.link_user(pool, ident)
    again = await oidc.link_user(pool, ident)
    assert user["id"] == again["id"] and user["is_admin"]
    other = await oidc.link_user(pool, oidc.Identity("sub-2", "lucas", "x@example.com", "Lucas", ("berganews_users",)))
    assert other["username"] == "lucas2" and other["name"] == "Lucas (2)", (other["username"], other["name"])
    me = CurrentUser(id=str(user["id"]), is_admin=True)
    print("contas ok")

    feeds = {
        "folha": [("Senado aprova reforma tributária", "O Senado aprovou a reforma tributária de Haddad."),
                  ("Chuva forte em São Paulo", "Alagamentos na capital paulista.")],
        "globo": [("Reforma tributária passa no Senado", "Haddad comemora aprovação da reforma no Senado."),
                  ("Flamengo vence o clássico", "Gol nos acréscimos no Maracanã.")],
        "bbc": [("Brazil Senate passes tax reform", "Brazil's Senate approved the tax reform pushed by Haddad.")],
    }
    ids = {}
    async with pool.acquire() as conn:
        for name, items in feeds.items():
            parsed = parse.parse(rss(name, items), f"https://{name}.example.com/rss")
            fid = await store.upsert_feed(conn, f"https://{name}.example.com/rss", parsed)
            n = await store.save_entries(conn, fid, parsed)
            assert n == len(items)
            assert await store.save_entries(conn, fid, parsed) == 0
            ids[name] = fid
        # Lucas assina folha e globo; não assina bbc.
        for name in ("folha", "globo"):
            await conn.execute("INSERT INTO subscriptions (user_id, feed_id) VALUES ($1, $2)",
                               user["id"], ids[name])
    print("feeds ok")

    from app.feeds import routes as fr
    subs = await fr.list_subscriptions(me)
    assert {s.title for s in subs} == {"Folha", "Globo"} and all(s.unread == 2 for s in subs), subs
    folder = await fr.create_folder(fr.FolderIn(name="Brasil"), me)
    await fr.patch_subscription(ids["folha"], fr.SubscriptionPatch(folder_id=folder.id), me)
    folders = await fr.list_folders(me)
    assert folders[0].unread == 2
    opml_resp = await fr.export_opml(me)
    assert b"Brasil" in opml_resp.body and b"folha.example.com" in opml_resp.body
    print("assinaturas, pastas, OPML ok")

    from app.articles import routes as ar
    page = await ar.list_articles("all", None, None, None, None, 40, me)
    assert len(page.items) == 4
    page2 = await ar.list_articles("all", None, None, None, None, 3, me)
    assert len(page2.items) == 3 and page2.next_cursor
    rest = await ar.list_articles("all", None, None, None, page2.next_cursor, 3, me)
    assert len(rest.items) == 1
    found = await ar.list_articles("all", None, None, "reforma tributaria", None, 40, me)
    assert len(found.items) == 2, [i.title for i in found.items]
    by_folder = await ar.list_articles("all", None, folder.id, None, None, 40, me)
    assert len(by_folder.items) == 2
    art = await ar.get_article(page.items[0].id, me)
    assert art.read and art.translate_to == "en"
    unread = await ar.list_articles("unread", None, None, None, None, 40, me)
    assert len(unread.items) == 3
    await ar.set_state(page.items[1].id, ar.StateIn(saved=True), me)
    saved = await ar.list_articles("saved", None, None, None, None, 40, me)
    assert [i.id for i in saved.items] == [page.items[1].id]
    marked = await ar.mark_read(ar.MarkReadIn(feed_id=ids["globo"]), me)
    assert marked["marked"] >= 1
    tr = await ar.request_translation(page.items[0].id, "en", me)
    assert tr.state == "queued"
    print("artigos, busca, lido/salvo, tradução (fila) ok")

    from app.prefs import routes as pr
    prefs = await pr.put_prefs(pr.PrefsIn(theme="dark", tabs=[pr.Tab(id="stories", enabled=True)]), me)
    assert prefs.tabs[0].id == "stories" and (await pr.get_prefs(me)).theme == "dark"
    print("preferências ok")

    # ── Histórias ──
    from app.stories import cluster, embed
    from app.stories import routes as sr
    random.seed(1)
    reform = [random.gauss(0, 1) for _ in range(1024)]
    rain = [random.gauss(0, 1) for _ in range(1024)]
    football = [random.gauss(0, 1) for _ in range(1024)]
    base_for = {"Senado aprova reforma tributária": reform, "Reforma tributária passa no Senado": reform,
                "Brazil Senate passes tax reform": reform, "Chuva forte em São Paulo": rain,
                "Flamengo vence o clássico": football}
    rows = await embed.pending(pool, 50)
    assert len(rows) == 0  # esperam extração (content_status NULL e recém-coletados)
    await pool.execute("UPDATE articles SET content_status = 'short'")
    rows = await embed.pending(pool, 50)
    assert len(rows) == 5

    class FakeOllama:
        async def embed(self, texts):
            return [vec(base_for[t.split("\n")[0]], 0.25) for t in texts]

    await embed.embed_batch(pool, FakeOllama(), rows)
    stories = await sr.list_stories(3, 2, None, 30, me)
    assert len(stories.items) == 1, [(s.title, s.source_count) for s in stories.items]
    story = stories.items[0]
    assert story.source_count == 3 and {s.title for s in story.sources} == {"Folha", "Globo", "Bbc"}
    assert [s.followed for s in story.sources][:2] == [True, True] and not story.sources[2].followed
    full = await sr.get_story(story.id, me)
    assert [a.feed_title for a in full.articles][0] == "Folha" and len(full.articles) == 3
    # Artigo da BBC (não assinada) abre porque está na história.
    bbc = next(a for a in full.articles if a.feed_title == "Bbc")
    assert (await ar.get_article(bbc.id, me)).story_sources == 3
    print("histórias ok:", story.title, [round(a.similarity or 1, 3) for a in full.articles])

    # Separar a da BBC, depois juntar de volta.
    res = await sr.split_story(story.id, sr.SplitIn(article_ids=[bbc.id]), me)
    assert (await sr.get_story(story.id, me)).source_count == 2
    # A história nova só tem a BBC (não assinada): Lucas não a vê; o merge parte da original.
    async with pool.acquire() as conn, conn.transaction():
        await cluster.merge(conn, story.id, res["story_id"], me.id)
    assert (await sr.get_story(story.id, me)).source_count == 3
    pairs = await pool.fetch("SELECT same, source FROM story_pairs ORDER BY created_at")
    assert [(p["same"], p["source"]) for p in pairs] == [(True, "merge")], pairs  # o merge sobrescreve o par
    cal = await sr.calibration(me)
    assert cal.pairs == 1 and len(cal.table) == 36
    sug = await sr.suggest_pairs(20, me)
    print("curadoria ok; sugestões:", len(sug))

    async with pool.acquire() as conn, conn.transaction():
        moved = await cluster.recluster(conn, 3)
    after = await sr.list_stories(3, 2, None, 30, me)
    print("recluster ok:", moved, "artigos;", [(s.title, s.source_count) for s in after.items])

    from worker.fetcher import cleanup
    await cleanup(pool)
    from app.users import routes as ur
    users = await ur.list_users(me)
    assert len(users) == 2
    print("limpeza e admin ok")
    await db.close_pool()


try:
    asyncio.run(main())
finally:
    srv.cleanup()
print("TUDO OK")
