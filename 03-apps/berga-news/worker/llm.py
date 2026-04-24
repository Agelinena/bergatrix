"""
Unified LLM client (worker copy — sync, same logic as api/llm.py).
"""
import os

from openai import OpenAI

LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "gemini")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemini-2.0-flash")

_BASE_URLS = {
    "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/",
    "openai": "https://api.openai.com/v1",
    "openrouter": "https://openrouter.ai/api/v1",
}
_API_KEYS = {
    "gemini": os.environ.get("GEMINI_API_KEY", ""),
    "openai": os.environ.get("OPENAI_API_KEY", ""),
    "openrouter": os.environ.get("OPENROUTER_API_KEY", ""),
}

_client: OpenAI | None = None


def get_client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI(
            api_key=_API_KEYS[LLM_PROVIDER],
            base_url=_BASE_URLS[LLM_PROVIDER],
        )
    return _client


def chat(messages: list[dict], temperature: float = 0.2, **kwargs) -> str:
    response = get_client().chat.completions.create(
        model=LLM_MODEL,
        messages=messages,
        temperature=temperature,
        **kwargs,
    )
    return response.choices[0].message.content or ""
