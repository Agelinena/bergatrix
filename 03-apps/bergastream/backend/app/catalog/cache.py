"""Cache simples em memória com validade, para não repetir chamadas caras
ao Spotify/YT Music enquanto o usuário rola a página de um artista."""
from __future__ import annotations

import threading
import time
from typing import Any, Callable

_lock = threading.Lock()
_store: dict[str, tuple[float, Any]] = {}
_MAX_ITEMS = 500


def cached(key: str, ttl_seconds: float, load: Callable[[], Any]) -> Any:
    now = time.monotonic()
    with _lock:
        hit = _store.get(key)
        if hit and hit[0] > now:
            return hit[1]
    value = load()
    with _lock:
        if len(_store) >= _MAX_ITEMS:
            # Remove os que venceram; se ainda cheio, o mais antigo.
            for k in [k for k, (exp, _) in _store.items() if exp <= now]:
                del _store[k]
            if len(_store) >= _MAX_ITEMS:
                del _store[min(_store, key=lambda k: _store[k][0])]
        _store[key] = (now + ttl_seconds, value)
    return value
