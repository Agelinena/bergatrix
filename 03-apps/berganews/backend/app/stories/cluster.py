"""Agrupamento incremental em histórias (só SQL e pgvector, sem LLM).

Para cada artigo novo, em ordem de publicação:
1. Vizinhos pelo embedding (HNSW) entre os artigos-base das histórias que
   tiveram artigo a até STORY_WINDOW_HOURS.
2. Entra na história do vizinho mais parecido se a similaridade passar de
   STORY_THRESHOLD e, quando os dois estão no mesmo idioma, se tiverem um
   nome próprio ou sigla em comum. Acima de STORY_STRONG entra sem a
   checagem de entidade e vira artigo-base (até STORY_MAX_SEEDS).
3. Senão, abre uma história nova, com ele de base.

A comparação é com os artigos-base, e não com o último que entrou: um
artigo que se parece com o último, mas não com o começo da história, não
entra. É o que segura o "efeito corrente".

Juntar, separar e o agrupamento disputam as mesmas linhas: todos pegam o
mesmo advisory lock.
"""
from __future__ import annotations

from dataclasses import dataclass

from app.config import settings
from app.stories import entities as ent

LOCK_ID = 7_310_001  # pg_advisory_xact_lock das histórias
# A API pede, o worker de IA refaz (um só escritor das histórias automáticas).
RECLUSTER_KEY = "berganews:stories:recluster"


@dataclass
class Decision:
    story_id: int | None      # None = história nova
    similarity: float | None
    seed: bool


def decide(candidates, article_lang: str | None, article_entities: list[str]) -> Decision:
    """candidates: linhas com story_id, similarity, language, entities (dos
    artigos-base), da mais parecida para a menos."""
    for c in candidates:
        sim = float(c["similarity"])
        if sim < settings.story_threshold:
            break
        strong = sim >= settings.story_strong
        same_lang = bool(article_lang) and article_lang == c["language"]
        if strong or not same_lang or ent.overlap(article_entities, c["entities"] or []):
            return Decision(c["story_id"], sim, strong)
    return Decision(None, None, True)


async def refresh_story(conn, story_id: int) -> None:
    """Contagens, datas e a manchete (a do primeiro artigo-base). Sem artigo,
    a história some."""
    row = await conn.fetchrow(
        # Republicação (o mesmo endereço em outro feed, ex.: a Folha no UOL)
        # não conta como mais um veículo: vale o veículo da primeira vez.
        """WITH arts AS (
             SELECT a.feed_id, a.published_at,
                    row_number() OVER (PARTITION BY a.url ORDER BY a.published_at, a.id) AS nth
             FROM story_articles sa JOIN articles a ON a.id = sa.article_id
             WHERE sa.story_id = $1)
           SELECT count(*) AS n, count(DISTINCT feed_id) FILTER (WHERE nth = 1) AS sources,
                  min(published_at) AS first, max(published_at) AS last
           FROM arts""", story_id)
    if not row["n"]:
        await conn.execute("DELETE FROM stories WHERE id = $1", story_id)
        return
    if not await conn.fetchval("SELECT 1 FROM story_articles WHERE story_id = $1 AND is_seed",
                               story_id):
        await conn.execute(
            """UPDATE story_articles SET is_seed = true WHERE article_id = (
                 SELECT sa.article_id FROM story_articles sa JOIN articles a ON a.id = sa.article_id
                 WHERE sa.story_id = $1 ORDER BY a.published_at LIMIT 1)""", story_id)
    title = await conn.fetchval(
        """SELECT a.title FROM story_articles sa JOIN articles a ON a.id = sa.article_id
           WHERE sa.story_id = $1 ORDER BY sa.is_seed DESC, a.published_at LIMIT 1""", story_id)
    await conn.execute(
        """UPDATE stories SET title = $2, first_published_at = $3, last_published_at = $4,
                  article_count = $5, source_count = $6, updated_at = now() WHERE id = $1""",
        story_id, title, row["first"], row["last"], row["n"], row["sources"])


async def new_story(conn, article_id: int) -> int:
    row = await conn.fetchrow("SELECT title, published_at FROM articles WHERE id = $1", article_id)
    return await conn.fetchval(
        """INSERT INTO stories (title, first_published_at, last_published_at, article_count,
                                source_count)
           VALUES ($1, $2, $2, 0, 0) RETURNING id""", row["title"], row["published_at"])


async def assign(conn, article_id: int) -> Decision:
    """Põe o artigo (já com embedding) numa história. Chame numa transação."""
    await conn.execute("SELECT pg_advisory_xact_lock($1)", LOCK_ID)
    if await conn.fetchval("SELECT 1 FROM story_articles WHERE article_id = $1", article_id):
        return Decision(None, None, False)
    me = await conn.fetchrow(
        """SELECT a.published_at, a.language, e.entities
           FROM articles a JOIN article_embeddings e ON e.article_id = a.id WHERE a.id = $1""",
        article_id)
    if me is None:
        return Decision(None, None, False)
    # Busca exata entre os artigos-base da janela (poucos milhares, rápido).
    # O índice HNSW filtraria depois de buscar e poderia perder as histórias
    # recentes quando o banco crescer.
    candidates = await conn.fetch(
        """WITH me AS (SELECT embedding FROM article_embeddings WHERE article_id = $1),
           seeds AS MATERIALIZED (
             SELECT sa.story_id, a.language, e.entities, e.embedding
             FROM story_articles sa
             JOIN stories s ON s.id = sa.story_id
             JOIN article_embeddings e ON e.article_id = sa.article_id
             JOIN articles a ON a.id = sa.article_id
             WHERE sa.is_seed AND sa.article_id <> $1
               AND s.last_published_at >= $2::timestamptz - make_interval(hours => $3)
               AND s.first_published_at <= $2::timestamptz + make_interval(hours => $3))
           SELECT seeds.story_id, seeds.language, seeds.entities,
                  1 - (seeds.embedding <=> me.embedding) AS similarity
           FROM seeds, me
           ORDER BY seeds.embedding <=> me.embedding
           LIMIT 20""",
        article_id, me["published_at"], settings.story_window_hours)
    decision = decide(candidates, me["language"], list(me["entities"] or []))
    story_id = decision.story_id
    seed = decision.seed
    if story_id is None:
        story_id = await new_story(conn, article_id)
    elif seed:
        seeds = await conn.fetchval(
            "SELECT count(*) FROM story_articles WHERE story_id = $1 AND is_seed", story_id)
        seed = seeds < settings.story_max_seeds
    await conn.execute(
        """INSERT INTO story_articles (article_id, story_id, similarity, is_seed)
           VALUES ($1, $2, $3, $4)""", article_id, story_id, decision.similarity, seed)
    await refresh_story(conn, story_id)
    return Decision(story_id, decision.similarity, seed)


# ── Curadoria manual ────────────────────────────────────────────────

async def _seed_of(conn, story_id: int) -> int | None:
    return await conn.fetchval(
        """SELECT sa.article_id FROM story_articles sa JOIN articles a ON a.id = sa.article_id
           WHERE sa.story_id = $1 ORDER BY sa.is_seed DESC, a.published_at LIMIT 1""", story_id)


async def label_pair(conn, a: int, b: int, same: bool, source: str, user_id: str | None) -> None:
    if a == b:
        return
    a, b = min(a, b), max(a, b)
    await conn.execute(
        """INSERT INTO story_pairs (article_a, article_b, same, source, user_id)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (article_a, article_b) DO UPDATE SET same = EXCLUDED.same,
               source = EXCLUDED.source, user_id = EXCLUDED.user_id, created_at = now()""",
        a, b, same, source, user_id)


async def merge(conn, target: int, other: int, user_id: str | None) -> None:
    """Junta `other` em `target`. Vira exemplo de "mesma notícia"."""
    await conn.execute("SELECT pg_advisory_xact_lock($1)", LOCK_ID)
    seed_a, seed_b = await _seed_of(conn, target), await _seed_of(conn, other)
    await conn.execute(
        """UPDATE story_articles SET story_id = $1, added_by = 'manual', is_seed = false
           WHERE story_id = $2""", target, other)
    if seed_a and seed_b:
        await label_pair(conn, seed_a, seed_b, True, "merge", user_id)
    await refresh_story(conn, other)
    await refresh_story(conn, target)


async def split(conn, story_id: int, article_ids: list[int], user_id: str | None) -> int:
    """Tira artigos de uma história para uma nova. Vira exemplo de "notícias
    diferentes" (cada artigo tirado × a base da original)."""
    await conn.execute("SELECT pg_advisory_xact_lock($1)", LOCK_ID)
    first = await conn.fetchval(
        """SELECT sa.article_id FROM story_articles sa JOIN articles a ON a.id = sa.article_id
           WHERE sa.story_id = $1 AND sa.article_id = ANY($2::bigint[])
           ORDER BY a.published_at LIMIT 1""", story_id, article_ids)
    if first is None:
        raise ValueError("Nenhum desses artigos está na história")
    new_id = await new_story(conn, first)
    moved = await conn.fetch(
        """UPDATE story_articles SET story_id = $1, added_by = 'manual', is_seed = false,
                  similarity = NULL
           WHERE story_id = $2 AND article_id = ANY($3::bigint[]) RETURNING article_id""",
        new_id, story_id, article_ids)
    await conn.execute("UPDATE story_articles SET is_seed = true WHERE article_id = $1", first)
    await refresh_story(conn, story_id)
    seed = await _seed_of(conn, story_id)
    if seed:
        for row in moved:
            await label_pair(conn, seed, row["article_id"], False, "split", user_id)
    await refresh_story(conn, new_id)
    return new_id


async def recluster(conn, days: int) -> int:
    """Refaz o agrupamento automático dos artigos dos últimos N dias, na ordem
    de publicação. O que foi posto à mão fica. Chame numa transação."""
    await conn.execute("SELECT pg_advisory_xact_lock($1)", LOCK_ID)
    removed = await conn.fetch(
        """DELETE FROM story_articles sa USING articles a
           WHERE a.id = sa.article_id AND sa.added_by = 'auto'
             AND a.published_at > now() - make_interval(days => $1)
           RETURNING sa.article_id, sa.story_id, a.published_at""", days)
    for story_id in {r["story_id"] for r in removed}:
        await refresh_story(conn, story_id)
    for row in sorted(removed, key=lambda r: (r["published_at"], r["article_id"])):
        await assign(conn, row["article_id"])
    return len(removed)
