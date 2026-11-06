"""Embeddings dos artigos (worker de IA) e o agrupamento logo em seguida."""
from __future__ import annotations

import logging
from datetime import timedelta

from app.config import settings
from app.stories import cluster, entities as ent

logger = logging.getLogger("berganews.embed")

DIMENSIONS = 1024


def text_for(row) -> str:
    """Manchete + começo do texto: é o que diz qual é a notícia (o resto do
    texto só dilui o vetor com contexto e opinião)."""
    body = (row["content_text"] or row["summary"] or "").strip()
    return f"{row['title']}\n{body[:900]}".strip()


def vector_literal(values: list[float]) -> str:
    return "[" + ",".join(f"{v:.6f}" for v in values) + "]"


async def pending(pool, limit: int):
    """Artigos recentes sem embedding, em ordem de publicação (a história
    cresce na ordem em que a notícia saiu). Espera a extração do texto, ou
    10 minutos, o que vier primeiro."""
    return await pool.fetch(
        """SELECT a.id, a.title, a.summary, a.content_text
           FROM articles a
           WHERE NOT EXISTS (SELECT 1 FROM article_embeddings e WHERE e.article_id = a.id)
             AND a.published_at > now() - $1::interval
             AND (a.content_status IS NOT NULL OR a.fetched_at < now() - interval '10 minutes')
           ORDER BY a.published_at
           LIMIT $2""",
        timedelta(days=settings.embed_max_age_days), limit)


async def embed_batch(pool, ollama, rows) -> int:
    texts = [text_for(r) for r in rows]
    vectors = await ollama.embed(texts)
    if len(vectors) != len(rows):
        raise RuntimeError("O Ollama devolveu um número diferente de embeddings")
    if vectors and len(vectors[0]) != DIMENSIONS:
        raise RuntimeError(f"O modelo {settings.embed_model} gera {len(vectors[0])} dimensões; "
                           f"o banco espera {DIMENSIONS} (use bge-m3)")
    names = [ent.extract(f"{r['title']}. {(r['content_text'] or r['summary'] or '')[:900]}")
             for r in rows]
    async with pool.acquire() as conn:
        async with conn.transaction():
            await conn.executemany(
                """INSERT INTO article_embeddings (article_id, embedding, entities, model)
                   VALUES ($1, $2::text::vector, $3::text[], $4) ON CONFLICT DO NOTHING""",
                [(r["id"], vector_literal(v), n, settings.embed_model)
                 for r, v, n in zip(rows, vectors, names)])
        joined = 0
        for r in rows:
            async with conn.transaction():
                decision = await cluster.assign(conn, r["id"])
            joined += decision.similarity is not None
    logger.info("[embeddings] %d artigos (%d entraram numa história existente)", len(rows), joined)
    return len(rows)
