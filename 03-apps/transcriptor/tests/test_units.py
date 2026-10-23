"""Testes sem banco: formatos, validação de link, ffprobe e id_token."""

import asyncio
import shutil
import subprocess
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import HTTPException

from app import formats
from app.api import auth
from app.api.main import check_url
from app.catalog import CATALOG
from app.config import settings
from app.formats import Segment

SEGMENTS = [Segment(0, 0, 2500, " Olá, tudo bem? "), Segment(1, 2600, 5000, "Vamos começar."),
            Segment(2, 9000, 3_725_042, "Depois de --> uma pausa longa.")]


def test_timestamp():
    assert formats.timestamp(3_725_042) == "01:02:05.042"
    assert formats.timestamp(1500, ",") == "00:00:01,500"


def test_text_breaks_paragraph_on_pause():
    assert formats.to_text(SEGMENTS) == "Olá, tudo bem? Vamos começar.\n\nDepois de --> uma pausa longa.\n"


def test_srt_and_vtt():
    srt = formats.to_srt(SEGMENTS)
    assert srt.startswith("1\n00:00:00,000 --> 00:00:02,500\nOlá, tudo bem?\n")
    assert "3\n00:00:09,000 --> 01:02:05,042\n" in srt
    vtt = formats.to_vtt(SEGMENTS)
    assert vtt.startswith("WEBVTT\n")
    assert "Depois de -> uma pausa longa." in vtt


@pytest.mark.parametrize("url", [
    "https://www.youtube.com/watch?v=abc", "http://example.com/audio.mp3", "https://8.8.8.8/a.mp3"])
def test_check_url_accepts_public(url):
    assert check_url(url) == url


@pytest.mark.parametrize("url", [
    "ftp://example.com/a", "file:///etc/passwd", "http://localhost:8000", "http://127.0.0.1/",
    "http://192.168.0.1/", "http://10.0.0.5/", "http://[::1]/", "http://169.254.169.254/latest",
    "http://authentik-server:9000/", "http://transcriptor-db/", "http://nas.local/", "https://user:pw@example.com/",
    "http://0.0.0.0/", "http://100.64.0.1/"])
def test_check_url_rejects_internal(url):
    with pytest.raises(HTTPException):
        check_url(url)


def test_safe_next():
    assert auth.safe_next("/#/t/123") == "/#/t/123"
    for bad in ("//evil.com", "https://evil.com", "/\\evil.com", "", None, "/a b"):
        assert auth.safe_next(bad) == "/"


def test_catalog_is_pinned():
    for spec in CATALOG.values():
        assert len(spec.revision) == 40 and len(spec.model_sha256) == 64
        assert "model.bin" in spec.files


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="sem ffmpeg")
def test_probe_rejects_playlist_and_accepts_audio(tmp_path):
    from app.worker import media

    audio = tmp_path / "tom.mp3"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=2", str(audio)], check=True)
    assert 1.9 < media.probe(audio, 60).duration < 2.2
    with pytest.raises(media.MediaError):
        media.probe(audio, 1)
    playlist = tmp_path / "video.m3u8"
    playlist.write_text("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n")
    with pytest.raises(media.MediaError):
        media.probe(playlist, 60)
    text = tmp_path / "nota.txt"
    text.write_text("não sou áudio")
    with pytest.raises(media.MediaError):
        media.probe(text, 60)


# ── id_token ─────────────────────────────────────────────────────────

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class FakeOIDC(auth.OIDCClient):
    def __init__(self):
        super().__init__()
        self._discovery = {"issuer": settings.oidc_issuer, "authorization_endpoint": "https://a/authorize",
                           "token_endpoint": "https://a/token", "jwks_uri": "https://a/jwks"}
        self._keys = {"k1": KEY.public_key()}
        self._keys_at = time.monotonic()


def id_token(**claims):
    now = int(time.time())
    payload = {"iss": settings.oidc_issuer, "aud": settings.sso_client_id, "sub": "abc", "iat": now,
               "exp": now + 300, "nonce": "n1", "preferred_username": "ana", "name": "Ana", "email": "Ana@X.com",
               "groups": ["transcriptor_users"], **claims}
    return jwt.encode(payload, KEY, algorithm="RS256", headers={"kid": "k1"})


def test_identity_valid():
    identity = asyncio.run(FakeOIDC().identity(id_token(), "n1"))
    assert (identity.subject, identity.username, identity.email) == ("abc", "ana", "ana@x.com")
    assert identity.groups == ("transcriptor_users",)


@pytest.mark.parametrize("claims, nonce", [
    ({"aud": "outro-app"}, "n1"), ({"iss": "https://evil/"}, "n1"), ({"exp": 1}, "n1"), ({}, "outro-nonce")])
def test_identity_rejects(claims, nonce):
    with pytest.raises(auth.LoginError):
        asyncio.run(FakeOIDC().identity(id_token(**claims), nonce))


def test_identity_rejects_other_key():
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    forged = jwt.encode({"sub": "x"}, other, algorithm="RS256", headers={"kid": "k1"})
    with pytest.raises(auth.LoginError):
        asyncio.run(FakeOIDC().identity(forged, "n1"))


def test_identity_rejects_hmac():
    forged = jwt.encode({"sub": "x"}, "segredo", algorithm="HS256", headers={"kid": "k1"})
    with pytest.raises(auth.LoginError):
        asyncio.run(FakeOIDC().identity(forged, "n1"))
