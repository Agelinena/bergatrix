"""
Groups articles by topic using an LLM call.
Returns list of dicts: {"label": str, "article_ids": [int, ...]}
"""
import json
import logging
from typing import Any

import llm

log = logging.getLogger("clusterer")

CHUNK_SIZE = 150


def _build_article_list(articles: list[dict]) -> str:
    lines = []
    for a in articles:
        source = a.get("source", "?")
        title = a.get("title", "").replace("\n", " ")
        desc = (a.get("description") or "")[:100].replace("\n", " ")
        lines.append(f'{a["seq"]}. [{source}] {title} — {desc}')
    return "\n".join(lines)


def _cluster_chunk(articles: list[dict]) -> list[dict]:
    """Send one chunk to the LLM and return cluster assignments."""
    article_list = _build_article_list(articles)
    prompt = (
        "Você é um editor de notícias. Agrupe os artigos abaixo pelo mesmo evento ou assunto real.\n"
        "Artigos sobre o mesmo fato (mesmo que de fontes diferentes) devem ficar no mesmo cluster.\n"
        'Retorne APENAS JSON válido: {"clusters": [{"label": "título curto do tópico", "article_ids": [1, 4, 7]}, ...]}\n'
        'Artigos sem tema claro ou muito isolados vão em um cluster chamado "Outros".\n'
        "Nenhum texto fora do JSON. Nenhum markdown.\n\n"
        f"Artigos:\n{article_list}"
    )
    for attempt in range(3):
        try:
            raw = llm.chat([{"role": "user", "content": prompt}])
            raw = raw.strip()
            if raw.startswith("```"):
                raw = raw.split("```")[1]
                if raw.startswith("json"):
                    raw = raw[4:]
            data = json.loads(raw)
            return data.get("clusters", [])
        except (json.JSONDecodeError, KeyError) as exc:
            log.warning("Cluster parse failed (attempt %d): %s", attempt + 1, exc)
    return []


def _merge_labels(chunk_results: list[list[dict]]) -> dict[str, str]:
    """
    When multiple chunks exist, use LLM to merge near-duplicate labels
    into canonical topics.
    """
    all_labels = list({c["label"] for chunk in chunk_results for c in chunk})
    if len(all_labels) <= 1:
        return {}

    label_list = "\n".join(f"- {l}" for l in all_labels)
    prompt = (
        "Abaixo há uma lista de tópicos de notícias. Mescle os que são essencialmente o mesmo assunto.\n"
        'Retorne APENAS JSON: {"merges": {"label_original": "label_canônico", ...}}\n'
        "Mantenha apenas os pares onde a label muda. Nenhum texto fora do JSON.\n\n"
        f"Tópicos:\n{label_list}"
    )
    try:
        raw = llm.chat([{"role": "user", "content": prompt}])
        raw = raw.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        data = json.loads(raw)
        return data.get("merges", {})
    except Exception as exc:
        log.warning("Label merge failed: %s", exc)
        return {}


def cluster_articles(articles: list[Any]) -> list[dict]:
    """
    Main entry point.
    articles: list of Article ORM objects (must have .id, .title, .description, .feed.title)
    Returns: [{"label": str, "article_ids": [int, ...]}, ...]
    """
    if not articles:
        return []

    # Build serializable dicts with sequential ids for the LLM
    seq_to_id = {}
    article_dicts = []
    for seq, a in enumerate(articles, start=1):
        seq_to_id[seq] = a.id
        article_dicts.append({
            "seq": seq,
            "id": a.id,
            "source": (a.feed.title if a.feed else "") or "?",
            "title": a.title,
            "description": a.description or "",
        })

    # Split into chunks
    chunks = [article_dicts[i:i + CHUNK_SIZE] for i in range(0, len(article_dicts), CHUNK_SIZE)]
    log.info("Clustering %d articles in %d chunk(s)", len(articles), len(chunks))

    chunk_results = []
    for idx, chunk in enumerate(chunks):
        log.info("Clustering chunk %d/%d (%d articles)…", idx + 1, len(chunks), len(chunk))
        result = _cluster_chunk(chunk)
        chunk_results.append(result)

    # Merge labels if multiple chunks
    merges: dict[str, str] = {}
    if len(chunks) > 1:
        merges = _merge_labels(chunk_results)

    # Consolidate: label → list of real article IDs
    label_to_ids: dict[str, list[int]] = {}
    for chunk, chunk_clusters in zip(chunks, chunk_results):
        seq_map = {a["seq"]: a["id"] for a in chunk}
        for cluster in chunk_clusters:
            label = merges.get(cluster["label"], cluster["label"])
            real_ids = [seq_map[s] for s in cluster["article_ids"] if s in seq_map]
            if real_ids:
                label_to_ids.setdefault(label, []).extend(real_ids)

    return [{"label": label, "article_ids": ids} for label, ids in label_to_ids.items()]
