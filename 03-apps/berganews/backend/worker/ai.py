"""Worker de IA: tudo no Ollama local (GPU), um trabalho por vez.

Prioridade: 1) tradução sob demanda (alguém está esperando na tela);
2) refazer o agrupamento, quando o admin pede; 3) embeddings e agrupamento em
histórias, em lotes pequenos, ao longo do dia (o bge-m3 é leve). Os resumos
e a newsletter (pesados, de madrugada) entram nas fases 3 e 4. Um trabalho
por vez, porque a GPU é dividida com o Jellyfin, o Transcriptor, o Immich e
o Legendarr.

Sem rota e sem internet: só a rede interna (banco, Redis) e a bergatrix-ai
(Ollama). Roda: python -m worker.ai
"""
from __future__ import annotations

import asyncio
import logging

import httpx
from lxml import etree

from app.articles import translation
from app.config import settings
from app.core import db, html as h
from app.core.redis import get_redis
from app.stories import cluster, embed

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO),
                    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("berganews.ai")

LANG_NAMES = {"pt": "Brazilian Portuguese", "en": "English", "es": "Spanish", "fr": "French",
              "de": "German", "it": "Italian"}


class OllamaError(Exception):
    pass


class Ollama:
    def __init__(self):
        # Sem proxy: o Ollama fica na rede bergatrix-ai, e este worker não tem internet.
        self._client = httpx.AsyncClient(base_url=settings.ollama_url, trust_env=False,
                                         timeout=httpx.Timeout(600.0, connect=10.0))

    async def chat(self, system: str, user: str, temperature: float = 0.2) -> str:
        try:
            r = await self._client.post("/api/chat", json={
                "model": settings.ai_model,
                "messages": [{"role": "system", "content": system},
                             {"role": "user", "content": user}],
                "stream": False,
                "keep_alive": settings.ai_keep_alive,
                "options": {"temperature": temperature, "num_ctx": settings.ai_num_ctx},
            })
        except httpx.HTTPError as exc:
            raise OllamaError(f"Ollama fora do ar ({exc.__class__.__name__})") from exc
        if r.status_code == 404:
            raise OllamaError(f"Modelo {settings.ai_model} não está no Ollama "
                              f"(docker exec ollama ollama pull {settings.ai_model})")
        if r.status_code >= 400:
            raise OllamaError(f"Ollama respondeu {r.status_code}: {r.text[:200]}")
        return (r.json().get("message") or {}).get("content", "").strip()

    async def embed(self, texts: list[str]) -> list[list[float]]:
        try:
            r = await self._client.post("/api/embed", json={
                "model": settings.embed_model, "input": texts,
                "keep_alive": settings.ai_keep_alive, "truncate": True,
            })
        except httpx.HTTPError as exc:
            raise OllamaError(f"Ollama fora do ar ({exc.__class__.__name__})") from exc
        if r.status_code == 404:
            raise OllamaError(f"Modelo {settings.embed_model} não está no Ollama "
                              f"(docker exec ollama ollama pull {settings.embed_model})")
        if r.status_code >= 400:
            raise OllamaError(f"Ollama respondeu {r.status_code}: {r.text[:200]}")
        return r.json().get("embeddings") or []


# ── Tradução ────────────────────────────────────────────────────────

def _system(src: str | None, dst: str) -> str:
    source = LANG_NAMES.get(src or "", "the original language")
    return (f"You are a professional news translator. Translate the text the user sends from "
            f"{source} to {LANG_NAMES.get(dst, dst)}. Keep names, numbers, dates and quotes "
            f"faithful to the original and keep the journalistic tone. Reply with the "
            f"translation only: no comments, notes, explanations or quotation marks around it.")


def leaf_blocks(root) -> list:
    """Blocos de texto sem outro bloco dentro (um <li> com <p> traduz só o <p>)."""
    blocks = []
    for el in root.iter(*h.BLOCKS):
        if any(True for _ in el.iterdescendants(*h.BLOCKS)):
            continue
        if any(ch.isalpha() for ch in el.text_content()):
            blocks.append(el)
    return blocks


def replace_text(el, text: str) -> None:
    """Troca o texto do bloco e mantém as imagens dele. Links e negrito dentro
    do parágrafo se perdem na tradução (o original continua a um toque)."""
    images = [img for img in el.iter("img")]
    for child in list(el):
        el.remove(child)
    el.text = text
    for img in images:
        img.tail = None
        el.append(img)


async def translate_article(pool, redis, ollama: Ollama, article_id: int, lang: str) -> None:
    row = await pool.fetchrow(
        "SELECT title, summary, content_html, language FROM articles WHERE id = $1", article_id)
    if row is None:
        await translation.clear_status(redis, article_id, lang)
        return
    if await pool.fetchval("SELECT 1 FROM article_translations WHERE article_id = $1 AND lang = $2",
                           article_id, lang):
        await translation.clear_status(redis, article_id, lang)
        return
    if row["content_html"]:
        root = h.fragment(row["content_html"])
    else:  # sem texto completo: traduz o trecho do RSS
        root = etree.Element("div")
        etree.SubElement(root, "p").text = row["summary"] or ""
    blocks = leaf_blocks(root)
    total = len(blocks) + 1
    system = _system(row["language"], lang)
    await translation.set_status(redis, article_id, lang, "running", 0, total)
    title = await ollama.chat(system, row["title"])
    for i, block in enumerate(blocks, start=1):
        text = " ".join(block.text_content().split())
        replace_text(block, await ollama.chat(system, text))
        await translation.set_status(redis, article_id, lang, "running", i + 1, total)
    out = h.serialize_children(root)
    await pool.execute(
        """INSERT INTO article_translations (article_id, lang, title, html, model)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (article_id, lang) DO UPDATE SET title = EXCLUDED.title,
               html = EXCLUDED.html, model = EXCLUDED.model, created_at = now()""",
        article_id, lang, title or row["title"], h.sanitize(out), settings.ai_model)
    await translation.clear_status(redis, article_id, lang)
    logger.info("[tradução] artigo %d → %s (%d blocos)", article_id, lang, len(blocks))


async def embeddings_step(pool, ollama: Ollama) -> bool:
    """Um lote de embeddings + agrupamento. True se ainda há trabalho."""
    rows = await embed.pending(pool, settings.embed_batch)
    if not rows:
        return False
    await embed.embed_batch(pool, ollama, rows)
    return len(rows) == settings.embed_batch


async def main() -> None:
    pool = await db.create_pool(min_size=1, max_size=3)
    redis = await get_redis()
    ollama = Ollama()
    logger.info("IA pronta: tradução com %s, embeddings com %s, em %s",
                settings.ai_model, settings.embed_model, settings.ollama_url)
    busy = True          # há embeddings na fila: volta logo
    pause_until = 0.0    # Ollama sem o modelo: não insiste a cada segundo
    while True:
        # A tradução tem prioridade (alguém está esperando na tela); os
        # embeddings andam nos intervalos, em lotes pequenos.
        popped = await redis.blpop(translation.QUEUE_KEY, timeout=2 if busy else 60)
        if not popped:
            days = await redis.getdel(cluster.RECLUSTER_KEY)
            if days:
                try:
                    async with pool.acquire() as conn, conn.transaction():
                        moved = await cluster.recluster(conn, int(days))
                    logger.info("[histórias] agrupamento refeito: %d artigos dos últimos %s dias",
                                moved, days)
                except Exception:
                    logger.exception("[histórias] refazer o agrupamento falhou")
                continue
            if asyncio.get_running_loop().time() < pause_until:
                busy = False
                continue
            try:
                busy = await embeddings_step(pool, ollama)
            except (OllamaError, RuntimeError) as exc:
                logger.warning("[embeddings] %s (tento de novo em 10 min)", exc)
                pause_until = asyncio.get_running_loop().time() + 600
                busy = False
            except Exception:
                logger.exception("[embeddings] falhou")
                pause_until = asyncio.get_running_loop().time() + 600
                busy = False
            continue
        article_id, lang = popped[1].split(":", 1)
        try:
            await translate_article(pool, redis, ollama, int(article_id), lang)
        except OllamaError as exc:
            logger.warning("[tradução] artigo %s: %s", article_id, exc)
            await translation.set_status(redis, int(article_id), lang, "error", error=str(exc))
        except Exception:
            logger.exception("[tradução] artigo %s falhou", article_id)
            await translation.set_status(redis, int(article_id), lang, "error",
                                         error="Erro inesperado na tradução")


if __name__ == "__main__":
    asyncio.run(main())
