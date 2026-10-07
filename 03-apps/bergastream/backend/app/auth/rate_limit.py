"""Limite de tentativas de login por usuário+IP (Redis)."""
from __future__ import annotations

from app.config import settings
from app.core.redis import get_redis

_PREFIX = "bergastream:login_fail:"


def _key(username: str, ip: str) -> str:
    return f"{_PREFIX}{username.strip().lower()}:{ip}"


async def seconds_blocked(username: str, ip: str) -> int:
    """Segundos até liberar, ou 0 se pode tentar."""
    r = await get_redis()
    key = _key(username, ip)
    failures = int(await r.get(key) or 0)
    if failures < settings.login_max_failures:
        return 0
    return max(int(await r.ttl(key)), 1)


async def register_failure(username: str, ip: str) -> None:
    r = await get_redis()
    key = _key(username, ip)
    failures = await r.incr(key)
    if failures == 1:
        await r.expire(key, settings.login_block_minutes * 60)


async def reset(username: str, ip: str) -> None:
    r = await get_redis()
    await r.delete(_key(username, ip))
