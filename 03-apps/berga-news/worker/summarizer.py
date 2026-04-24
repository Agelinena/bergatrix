"""
Generates AI summaries for article clusters.
"""
import logging
from typing import Any

import llm

log = logging.getLogger("summarizer")


def summarize_cluster(label: str, articles: list[Any]) -> str:
    """
    articles: list of Article ORM objects with .title, .description, .feed.title
    Returns a 2-3 sentence summary in Brazilian Portuguese.
    """
    if not articles:
        return ""

    article_lines = []
    for a in articles:
        source = (a.feed.title if a.feed else "") or "?"
        title = a.title.strip()
        desc = (a.description or "").strip()[:200]
        article_lines.append(f"- [{source}] {title}" + (f" — {desc}" if desc else ""))

    article_text = "\n".join(article_lines)
    prompt = (
        f'Resuma em 2-3 frases em português brasileiro os artigos abaixo sobre "{label}".\n'
        "Preserve a atribuição de fonte entre parênteses onde relevante.\n"
        "Seja factual, neutro e conciso. Não use markdown.\n\n"
        f"Artigos:\n{article_text}"
    )

    try:
        summary = llm.chat([{"role": "user", "content": prompt}])
        return summary.strip()
    except Exception as exc:
        log.error("Summarization failed for cluster '%s': %s", label, exc)
        return ""
