"""
Auto-updater for the volatile Python deps that the download pipeline
depends on.

Why this exists
---------------
yt-dlp ships frequent (often weekly) releases because YouTube keeps
changing its extractor logic; an out-of-date yt-dlp returns 403/
"Sign in to confirm you're not a bot" / "Failed to extract any
player response" errors.  ytmusicapi/spotipy/mutagen rotate less
often but still benefit from refresh.

Approach
--------
A background task in the API container runs every UPDATE_INTERVAL_HOURS
(24 h default).  It pip-installs the latest of each package into the
running interpreter.  Subsequent yt-dlp invocations (via
asyncio.create_subprocess_exec) pick up the new binary on next call —
no service restart required, because the entry-point script in
site-packages/bin/yt-dlp is replaced in-place by pip.

Failures
--------
- Network down / pip rate-limited: log a warning and try again next
  cycle.  Old version keeps working.
- Sidecar containers (deemix) live outside this process and are not
  touched here; they update by `docker pull` + `docker compose up`.
"""
from __future__ import annotations

import asyncio
import logging
import sys
from datetime import datetime, timezone
from typing import Iterable

logger = logging.getLogger(__name__)

# Packages we keep current.  yt-dlp first so its update runs even if a
# later package fails.
_PACKAGES_TO_UPDATE: tuple[str, ...] = (
    "yt-dlp",
    "ytmusicapi",
    "spotipy",
    "mutagen",
)

UPDATE_INTERVAL_HOURS = 24
INITIAL_DELAY_SECONDS = 60  # don't hammer pip at boot
PIP_TIMEOUT_SECONDS = 300   # per-package upgrade


class UpdaterService:
    """Periodic pip-upgrade loop for runtime dependencies."""

    _last_run: datetime | None = None
    _last_results: dict[str, str] = {}

    @classmethod
    async def run_periodic(cls) -> None:
        """Long-running task launched from app.main lifespan."""
        await asyncio.sleep(INITIAL_DELAY_SECONDS)
        while True:
            try:
                await cls.run_once()
            except asyncio.CancelledError:
                return
            except Exception as exc:  # never let this loop die
                logger.exception(f"[updater] unexpected error in periodic loop: {exc}")
            await asyncio.sleep(UPDATE_INTERVAL_HOURS * 3600)

    @classmethod
    async def run_once(cls, *, packages: Iterable[str] | None = None) -> dict[str, str]:
        """Upgrade every package in sequence.  Returns {pkg: result_label}.

        Result labels:
          "updated:<old>->" + "<new>"   newest installed
          "already-latest:<ver>"        no-op
          "error:<message>"             pip failed
        """
        targets = list(packages or _PACKAGES_TO_UPDATE)
        logger.info(f"[updater] starting upgrade pass for {targets}")
        results: dict[str, str] = {}
        for pkg in targets:
            results[pkg] = await cls._upgrade_one(pkg)
        cls._last_run = datetime.now(timezone.utc)
        cls._last_results = results
        logger.info(f"[updater] pass finished: {results}")
        return results

    @classmethod
    async def _upgrade_one(cls, pkg: str) -> str:
        before = await cls._version(pkg)
        try:
            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m", "pip", "install", "--upgrade", "--no-cache-dir", "--quiet", pkg,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                _, stderr = await asyncio.wait_for(
                    proc.communicate(), timeout=PIP_TIMEOUT_SECONDS
                )
            except asyncio.TimeoutError:
                try:
                    proc.kill()
                except Exception:
                    pass
                return f"error:timeout after {PIP_TIMEOUT_SECONDS}s"
            if proc.returncode != 0:
                err = stderr.decode("utf-8", errors="replace").strip()[-300:]
                return f"error:rc={proc.returncode} {err}"
        except Exception as exc:
            return f"error:{type(exc).__name__}: {exc}"

        after = await cls._version(pkg)
        if before == after:
            return f"already-latest:{after or '?'}"
        return f"updated:{before or '?'}->{after or '?'}"

    @classmethod
    async def _version(cls, pkg: str) -> str | None:
        try:
            proc = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "pip", "show", pkg,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
            for line in stdout.decode("utf-8", errors="replace").splitlines():
                if line.lower().startswith("version:"):
                    return line.split(":", 1)[1].strip()
        except Exception:
            pass
        return None

    @classmethod
    def status(cls) -> dict[str, object]:
        return {
            "last_run": cls._last_run.isoformat() if cls._last_run else None,
            "interval_hours": UPDATE_INTERVAL_HOURS,
            "packages": list(_PACKAGES_TO_UPDATE),
            "last_results": dict(cls._last_results),
        }
