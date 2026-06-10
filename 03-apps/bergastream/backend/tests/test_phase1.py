"""
Unit tests for Phase 1 (queue/download speed) pure logic.

These cover only dependency-light, pure functions so they run without
Postgres/Redis/yt-dlp/deemix.  Full integration is exercised by the Docker
stack; here we lock down the behaviour we changed:

  * queue_service._retry_backoff      — short, capped, monotonic backoff
  * downloader_service._duration_ok   — duration tolerance window
  * downloader_service semaphores     — stream pool is separate from bg pool
  * downloader_service._CANDIDATE_TTL — 7-day cache
  * config.Settings                   — new concurrency knobs exist
  * metadata_service.find_deezer_track_id — title+duration scoring (regression
    test for the "wrong track downloaded" bug: duration-only matching is gone)
"""
import asyncio
import pytest

from app.services import queue_service as qs
from app.services import downloader_service as ds
from app.services import metadata_service as ms
from app.config import get_settings


# ── _retry_backoff ───────────────────────────────────────────────────────────

def test_retry_backoff_values():
    assert qs._retry_backoff(0) == 3
    assert qs._retry_backoff(1) == 6
    assert qs._retry_backoff(2) == 8   # 3*2**2=12 capped to 8


def test_retry_backoff_capped_and_nonnegative():
    for n in range(0, 20):
        w = qs._retry_backoff(n)
        assert 0 < w <= qs._RETRY_BACKOFF_CAP
    # negative retries must not blow up or go negative
    assert qs._retry_backoff(-5) == 3


def test_retry_backoff_monotonic_until_cap():
    seq = [qs._retry_backoff(n) for n in range(0, 6)]
    assert seq == sorted(seq)              # non-decreasing
    assert max(seq) <= qs._RETRY_BACKOFF_CAP


def test_retry_backoff_much_shorter_than_old():
    # Old behaviour was 30*(n+1) = 30, 60.  New must be a small fraction.
    assert qs._retry_backoff(0) < 30
    assert qs._retry_backoff(1) < 60


# ── _duration_ok ─────────────────────────────────────────────────────────────

def test_duration_ok_within_tolerance():
    # 200 s expected, 5 s off → within max(10s, 5%) = 10s window
    assert ds._duration_ok(205_000, 200_000) is True


def test_duration_ok_outside_tolerance():
    assert ds._duration_ok(230_000, 200_000) is False


def test_duration_ok_unknown_is_permissive():
    assert ds._duration_ok(0, 200_000) is True
    assert ds._duration_ok(200_000, None) is True
    assert ds._duration_ok(200_000, 0) is True


# ── Separate yt-dlp semaphores (Phase 1.4) ───────────────────────────────────

def test_stream_and_bg_semaphores_are_distinct():
    bg = ds._get_yt_semaphore()
    stream = ds._get_yt_stream_semaphore()
    assert bg is not stream
    assert isinstance(bg, asyncio.Semaphore)
    assert isinstance(stream, asyncio.Semaphore)


def test_semaphore_initial_slots_match_settings():
    s = get_settings()
    assert ds._get_yt_semaphore()._value == s.max_yt_concurrent
    assert ds._get_yt_stream_semaphore()._value == s.max_yt_stream_concurrent


# ── Cache TTL (Phase 1.6) ────────────────────────────────────────────────────

def test_candidate_ttl_is_seven_days():
    assert ds._CANDIDATE_TTL == 7 * 24 * 3600


# ── New config knobs (Phase 1.3 / 1.4) ───────────────────────────────────────

def test_config_has_new_concurrency_knobs():
    s = get_settings()
    assert isinstance(s.max_yt_stream_concurrent, int) and s.max_yt_stream_concurrent >= 1
    assert isinstance(s.deemix_bg_workers, int) and s.deemix_bg_workers >= 1
    assert isinstance(s.max_yt_concurrent, int) and s.max_yt_concurrent >= 1


# ── find_deezer_track_id title+duration scoring (regression) ─────────────────

class _FakeResponse:
    def __init__(self, payload):
        self.status_code = 200
        self._payload = payload

    def json(self):
        return self._payload


class _FakeClient:
    def __init__(self, payload):
        self._payload = payload
        self.calls = 0

    async def get(self, url, params=None):
        self.calls += 1
        return _FakeResponse(self._payload)


async def test_find_deezer_prefers_title_match_over_duration(monkeypatch):
    # Candidate 0: exact duration match but UNRELATED title (the old bug would
    # have picked this).  Candidate 1: correct title+artist, duration close.
    payload = {"data": [
        {"id": 111, "title": "Completely Unrelated Tune",
         "artist": {"name": "Some Other Band"}, "duration": 200},
        {"id": 222, "title": "My Song",
         "artist": {"name": "My Artist"}, "duration": 195},
    ]}
    fake = _FakeClient(payload)
    monkeypatch.setattr(ms, "get_shared_client", lambda: fake)

    chosen = await ms.find_deezer_track_id("My Song", "My Artist", 200_000)
    assert chosen == "222"


async def test_find_deezer_returns_none_when_no_title_match(monkeypatch):
    payload = {"data": [
        {"id": 1, "title": "Nothing Alike", "artist": {"name": "Nobody"}, "duration": 200},
        {"id": 2, "title": "Also Different", "artist": {"name": "Someone"}, "duration": 201},
    ]}
    fake = _FakeClient(payload)
    monkeypatch.setattr(ms, "get_shared_client", lambda: fake)

    chosen = await ms.find_deezer_track_id("Bohemian Rhapsody", "Queen", 355_000)
    assert chosen is None
