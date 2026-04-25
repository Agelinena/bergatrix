"""
Unified LLM client (worker copy — sync).
Handles rate-limit (429) with the retry delay suggested by the API.
"""
import logging
import os
import re
import time

from openai import OpenAI, RateLimitError

log = logging.getLogger("llm")

LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "gemini")
LLM_MODEL    = os.environ.get("LLM_MODEL", "gemini-2.0-flash")

_BASE_URLS = {
    "gemini":     "https://generativelanguage.googleapis.com/v1beta/openai/",
    "openai":     "https://api.openai.com/v1",
    "openrouter": "https://openrouter.ai/api/v1",
}
_API_KEYS = {
    "gemini":     os.environ.get("GEMINI_API_KEY", ""),
    "openai":     os.environ.get("OPENAI_API_KEY", ""),
    "openrouter": os.environ.get("OPENROUTER_API_KEY", ""),
}

_client: OpenAI | None = None


def get_client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI(
            api_key=_API_KEYS[LLM_PROVIDER],
            base_url=_BASE_URLS[LLM_PROVIDER],
            max_retries=0,   # we handle retries ourselves
        )
    return _client


def _parse_retry_delay(exc: RateLimitError) -> float:
    """Extract suggested retry delay (seconds) from Gemini/OpenAI 429 error."""
    msg = str(exc)
    # Gemini: "Please retry in 45.3s"  or  'retryDelay': '45s'
    for pattern in (
        r"retry in\s+(\d+(?:\.\d+)?)\s*s",
        r"retryDelay['\"]?\s*:\s*['\"]?(\d+(?:\.\d+)?)",
    ):
        m = re.search(pattern, msg, re.IGNORECASE)
        if m:
            return float(m.group(1)) + 3   # +3s safety buffer
    return 60.0   # conservative default


def chat(messages: list[dict], temperature: float = 0.2, **kwargs) -> str:
    max_attempts = 5
    for attempt in range(max_attempts):
        try:
            response = get_client().chat.completions.create(
                model=LLM_MODEL,
                messages=messages,
                temperature=temperature,
                **kwargs,
            )
            return response.choices[0].message.content or ""

        except RateLimitError as exc:
            if attempt == max_attempts - 1:
                raise

            # Check for exhausted daily quota — no point retrying today
            if "GenerateRequestsPerDayPerProjectPerModel" in str(exc):
                log.error(
                    "Quota diária do Gemini esgotada. "
                    "Aguarde até amanhã ou mude para outro modelo/provider."
                )
                raise

            delay = _parse_retry_delay(exc)
            log.warning(
                "Rate limit 429 — aguardando %.0fs antes de tentar novamente "
                "(tentativa %d/%d)…",
                delay, attempt + 1, max_attempts,
            )
            time.sleep(delay)
