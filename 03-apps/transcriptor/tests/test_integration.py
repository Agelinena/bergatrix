"""Testes com Postgres: login, CSRF, jobs, upload em pedaços, tokens, fila e worker."""

import asyncio
import json
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import asyncpg
import pytest
from fastapi.testclient import TestClient

from conftest import TEST_DATABASE_URL
from test_units import FakeOIDC, id_token

pytestmark = pytest.mark.skipif(not TEST_DATABASE_URL, reason="sem TRANSCRIPTOR_TEST_DATABASE_URL")

from app import db  # noqa: E402
from app import jobs as repo  # noqa: E402
from app.api import auth  # noqa: E402
from app.api.main import app  # noqa: E402
from app.formats import Segment  # noqa: E402

BASE = "https://transcriptor.example.com"
HEADERS = {"X-Transcriptor": "1", "Origin": BASE}


class LoginOIDC(FakeOIDC):
    groups = ["transcriptor_users"]
    subject = "ana"

    async def authorize_url(self, state, nonce, challenge):
        self.nonce = nonce
        return f"https://authentik.example.com/authorize?state={state}"

    async def exchange(self, code, verifier):
        assert code == "codigo"
        return {"id_token": id_token(nonce=self.nonce, sub=self.subject, preferred_username=self.subject,
                                     groups=self.groups)}


def run(coroutine):
    return asyncio.run(coroutine)


async def sql(query, *args):
    connection = await asyncpg.connect(TEST_DATABASE_URL)
    try:
        return await connection.fetch(query, *args)
    finally:
        await connection.close()


@pytest.fixture()
def oidc():
    fake = LoginOIDC()
    auth.set_client(fake)
    yield fake
    auth.set_client(None)


@pytest.fixture()
def client(oidc):
    run(sql("TRUNCATE users, login_states, workers CASCADE"))
    with TestClient(app, base_url=BASE) as test_client:
        yield test_client


def login(client, oidc, subject="ana", groups=("transcriptor_users",)):
    client.cookies.clear()
    oidc.subject, oidc.groups = subject, list(groups)
    response = client.get("/auth/login?next=/%23/t/1", follow_redirects=False)
    assert response.status_code == 303
    state = parse_qs(urlsplit(response.headers["location"]).query)["state"][0]
    return client.get(f"/auth/callback?code=codigo&state={state}", follow_redirects=False)


def test_login_and_session(client, oidc):
    assert client.get("/api/me").status_code == 401
    response = login(client, oidc)
    assert response.status_code == 303 and response.headers["location"] == "/#/t/1"
    assert "__Host-transcriptor=" in response.headers["set-cookie"]
    assert "HttpOnly" in response.headers["set-cookie"] and "Secure" in response.headers["set-cookie"]
    assert client.get("/api/me").json()["username"] == "ana"
    # O state é de uso único.
    assert run(sql("SELECT count(*) AS n FROM login_states"))[0]["n"] == 0
    client.post("/auth/logout", headers=HEADERS)
    assert client.get("/api/me").status_code == 401


def test_login_requires_group(client, oidc):
    response = login(client, oidc, groups=["outra_coisa"])
    assert "erro=" in response.headers["location"]
    assert client.get("/api/me").status_code == 401


def test_admin_group(client, oidc):
    login(client, oidc, subject="root", groups=["transcriptor_admins"])
    assert client.get("/api/me").json()["is_admin"] is True
    assert client.get("/api/admin/status").status_code == 200
    login(client, oidc, subject="ana")
    assert client.get("/api/admin/status").status_code == 403


def test_csrf_guard(client, oidc):
    login(client, oidc)
    body = {"url": "https://example.com/a.mp3"}
    assert client.post("/api/jobs", json=body).status_code == 403
    assert client.post("/api/jobs", json=body, headers={"X-Transcriptor": "1", "Origin": "https://evil.com"}).status_code == 403
    assert client.post("/api/jobs", json=body, headers=HEADERS).status_code == 201


def test_url_job_validation(client, oidc):
    login(client, oidc)
    for url in ("http://192.168.0.1/admin", "http://authentik-server:9000/", "file:///etc/passwd"):
        assert client.post("/api/jobs", json={"url": url}, headers=HEADERS).status_code == 422
    assert client.post("/api/jobs", json={"url": "https://e.com/a", "model": "xx"}, headers=HEADERS).status_code == 422
    job = client.post("/api/jobs", json={"url": "https://e.com/a", "language": None}, headers=HEADERS).json()
    assert (job["status"], job["model"], job["language"]) == ("queued", "turbo", None)


def test_chunked_upload_and_isolation(client, oidc):
    login(client, oidc)
    start = client.post("/api/uploads", json={"name": "reunião.mp3", "size": 20, "model": "small"}, headers=HEADERS)
    assert start.status_code == 201
    job_id = start.json()["id"]
    assert client.get("/api/jobs").json()["jobs"] == []  # ainda subindo: fora da lista
    put = lambda offset, data: client.put(f"/api/uploads/{job_id}?offset={offset}", content=data, headers=HEADERS)
    assert put(0, b"a" * 10).json() == {"received": 10}
    wrong = put(0, b"b" * 10)
    assert wrong.status_code == 409 and wrong.json()["received"] == 10
    assert put(10, b"c" * 11).status_code == 413
    assert client.post(f"/api/uploads/{job_id}/complete", headers=HEADERS).status_code == 409
    assert put(10, b"c" * 10).json() == {"received": 20}
    done = client.post(f"/api/uploads/{job_id}/complete", headers=HEADERS).json()
    assert done["status"] == "queued"
    assert repo.upload_path(job_id).read_bytes() == b"a" * 10 + b"c" * 10
    assert [j["id"] for j in client.get("/api/jobs").json()["jobs"]] == [job_id]

    login(client, oidc, subject="bia")
    assert client.get(f"/api/jobs/{job_id}").status_code == 404
    assert client.delete(f"/api/jobs/{job_id}", headers=HEADERS).status_code == 404
    assert client.get(f"/api/jobs/{job_id}/export/txt").status_code == 404
    assert client.get("/api/jobs").json()["jobs"] == []


def test_upload_limits(client, oidc):
    login(client, oidc)
    too_big = client.post("/api/uploads", json={"name": "a.mp4", "size": 10 * 1024 ** 4}, headers=HEADERS)
    assert too_big.status_code == 413


def test_tokens(client, oidc):
    login(client, oidc)
    created = client.post("/api/tokens", json={"name": "n8n"}, headers=HEADERS).json()
    secret = created["token"]
    assert secret.startswith("trs_") and "token" not in client.get("/api/tokens").json()["tokens"][0]
    bearer = {"Authorization": f"Bearer {secret}"}
    session = dict(client.cookies)
    client.cookies.clear()
    # Token não precisa de cabeçalho CSRF nem de cookie.
    assert client.post("/api/jobs", json={"url": "https://e.com/v"}, headers=bearer).status_code == 201
    assert client.get("/api/jobs", headers=bearer).json()["jobs"][0]["source_url"] == "https://e.com/v"
    assert client.get("/api/tokens", headers=bearer).status_code == 403
    assert client.get("/api/jobs", headers={"Authorization": "Bearer trs_falso"}).status_code == 401
    client.cookies.update(session)
    client.delete(f"/api/tokens/{created['id']}", headers=HEADERS)
    client.cookies.clear()
    assert client.get("/api/jobs", headers=bearer).status_code == 401


def test_search_export_edit(client, oidc):
    login(client, oidc)
    job_id = client.post("/api/jobs", json={"url": "https://e.com/v"}, headers=HEADERS).json()["id"]

    async def finish():
        pool = await asyncpg.create_pool(TEST_DATABASE_URL)
        await repo.add_segments(pool, job_id, [Segment(0, 0, 1500, "Reunião sobre orçamento."),
                                               Segment(1, 1600, 3000, "Próximos passos.")])
        await pool.execute("UPDATE jobs SET title = 'Planejamento' WHERE id = $1", job_id)
        await repo.finish(pool, job_id, "done")
        await pool.close()

    run(finish())
    assert [j["id"] for j in client.get("/api/jobs?q=orçamentos").json()["jobs"]] == [job_id]  # radical em português
    assert client.get("/api/jobs?q=planej").json()["jobs"][0]["id"] == job_id  # título por trecho
    assert client.get("/api/jobs?q=inexistente").json()["jobs"] == []
    txt = client.get(f"/api/jobs/{job_id}/export/txt")
    assert txt.text == "Reunião sobre orçamento. Próximos passos.\n"
    assert "Planejamento.txt" in txt.headers["content-disposition"]
    assert "00:00:01,600 --> 00:00:03,000" in client.get(f"/api/jobs/{job_id}/export/srt").text
    assert client.put(f"/api/jobs/{job_id}/segments/1", json={"text": "Próximas etapas."}, headers=HEADERS).status_code == 200
    assert client.get(f"/api/jobs?q=etapas").json()["jobs"][0]["id"] == job_id
    assert json.loads(client.get(f"/api/jobs/{job_id}/export/json").text)["segments"][1]["text"] == "Próximas etapas."


def test_cancel_retry_delete(client, oidc):
    login(client, oidc)
    job_id = client.post("/api/jobs", json={"url": "https://e.com/v"}, headers=HEADERS).json()["id"]
    assert client.post(f"/api/jobs/{job_id}/cancel", headers=HEADERS).json()["status"] == "canceled"
    assert client.post(f"/api/jobs/{job_id}/cancel", headers=HEADERS).status_code == 409
    assert client.post(f"/api/jobs/{job_id}/retry", headers=HEADERS).json()["status"] == "queued"
    assert client.delete(f"/api/jobs/{job_id}", headers=HEADERS).status_code == 204
    assert client.get(f"/api/jobs/{job_id}").status_code == 404


def test_queue_claim_heartbeat_and_stale(client, oidc):
    login(client, oidc)
    first = client.post("/api/jobs", json={"url": "https://e.com/1"}, headers=HEADERS).json()["id"]
    second = client.post("/api/jobs", json={"url": "https://e.com/2"}, headers=HEADERS).json()["id"]

    async def scenario():
        pool = await asyncpg.create_pool(TEST_DATABASE_URL)
        claimed = await repo.claim(pool, "gpu")
        assert str(claimed["id"]) == first and claimed["status"] == "downloading"
        assert await repo.update(pool, claimed["id"], progress=0.5) is True
        await repo.cancel(pool, claimed["id"])
        assert await repo.update(pool, claimed["id"]) is False  # o worker vê o pedido de cancelar
        other = await repo.claim(pool, "gpu")
        assert str(other["id"]) == second
        # Worker morreu: sem sinal de vida há 10 minutos.
        await pool.execute("UPDATE jobs SET heartbeat_at = now() - interval '10 minutes'")
        assert await repo.requeue_stale(pool) == 2
        rows = {str(r["id"]): r["status"] for r in await pool.fetch("SELECT id, status FROM jobs")}
        await pool.close()
        return rows

    # O que tinha pedido de cancelar fica cancelado; o outro volta para a fila.
    assert run(scenario()) == {first: "canceled", second: "queued"}


def test_trigger_notifies(client, oidc):
    login(client, oidc)

    async def listen():
        connection = await asyncpg.connect(TEST_DATABASE_URL)
        received = asyncio.Queue()
        await connection.add_listener("transcriptor_jobs", lambda *a: received.put_nowait(json.loads(a[3])))
        await connection.add_listener("transcriptor_queue", lambda *a: received.put_nowait({"queue": a[3]}))
        await asyncio.to_thread(client.post, "/api/jobs", json={"url": "https://e.com/x"}, headers=HEADERS)
        events = [await asyncio.wait_for(received.get(), 5) for _ in range(2)]
        await connection.close()
        return events

    events = run(listen())
    assert any(e.get("status") == "queued" for e in events)
    assert any("queue" in e for e in events)


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="sem ffmpeg")
def test_worker_pipeline(client, oidc, tmp_path):
    """Upload → probe → ffmpeg → transcrição (motor falso, sem GPU) → pronto."""
    from app.worker.engine import Result
    from app.worker.main import Worker

    login(client, oidc)
    audio = tmp_path / "fala.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=duration=3", str(audio)], check=True)
    data = audio.read_bytes()
    job_id = client.post("/api/uploads", json={"name": "fala.m4a", "size": len(data)}, headers=HEADERS).json()["id"]
    client.put(f"/api/uploads/{job_id}?offset=0", content=data, headers=HEADERS)
    client.post(f"/api/uploads/{job_id}/complete", headers=HEADERS)

    class FakeEngine:
        spec = None

        def transcribe(self, wav, spec, path, *, language, prompt, batch_size, emit):
            assert Path(wav).exists() and language == "pt"
            assert emit([Segment(0, 0, 1000, "Primeiro trecho.")], 0.4)
            assert emit([Segment(1, 1000, 2900, "Segundo trecho.")], 0.99)
            return Result(3.0, "pt")

        def unload_if_idle(self, seconds):
            pass

    async def scenario():
        worker = Worker()
        worker.engine = FakeEngine()
        worker.pool = await asyncpg.create_pool(TEST_DATABASE_URL, init=db._init)  # noqa: SLF001
        worker.model_paths = {"turbo": tmp_path}
        job = await repo.claim(worker.pool, "gpu")
        await worker.process(job)
        row = await worker.pool.fetchrow("SELECT * FROM jobs WHERE id = $1", job["id"])
        await worker.pool.close()
        return row

    row = run(scenario())
    assert row["status"] == "done", row["error"]
    assert row["transcript"] == "Primeiro trecho. Segundo trecho."
    assert row["has_audio"] and 2.9 < row["duration_seconds"] < 3.2
    assert repo.playback_path(job_id).exists()
    assert not repo.upload_path(job_id).exists()
    assert not (repo.work_dir(job_id) / "audio.wav").exists()
    audio_response = client.get(f"/api/jobs/{job_id}/audio", headers={"Range": "bytes=0-99"})
    assert audio_response.status_code == 206 and len(audio_response.content) == 100


def test_worker_rejects_bad_media(client, oidc):
    from app.worker.main import Worker

    login(client, oidc)
    playlist = b"#EXTM3U\n#EXTINF:10,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n"
    job_id = client.post("/api/uploads", json={"name": "x.mp3", "size": len(playlist)}, headers=HEADERS).json()["id"]
    client.put(f"/api/uploads/{job_id}?offset=0", content=playlist, headers=HEADERS)
    client.post(f"/api/uploads/{job_id}/complete", headers=HEADERS)

    async def scenario():
        worker = Worker()
        worker.pool = await asyncpg.create_pool(TEST_DATABASE_URL, init=db._init)  # noqa: SLF001
        job = await repo.claim(worker.pool, "gpu")
        await worker.process(job)
        row = await worker.pool.fetchrow("SELECT status, error FROM jobs WHERE id = $1", job["id"])
        await worker.pool.close()
        return row

    row = run(scenario())
    assert row["status"] == "failed" and "Formato não reconhecido" in row["error"]


def test_worker_survives_unwritable_work_dir(client, oidc, tmp_path, monkeypatch):
    """Sem permissão na pasta de trabalho: o job falha com aviso e o worker segue de pé."""
    from app.worker import main as worker_main
    from app.worker.main import Worker

    login(client, oidc)
    job_id = client.post("/api/jobs", json={"url": "https://e.com/v"}, headers=HEADERS).json()["id"]
    locked = tmp_path / "travada"
    locked.mkdir()
    locked.chmod(0o500)
    monkeypatch.setattr(worker_main.repo, "work_dir", lambda jid: locked / str(jid))
    monkeypatch.setattr(worker_main.settings, "work_dir", str(locked))

    async def scenario():
        worker = Worker()
        worker.pool = await asyncpg.create_pool(TEST_DATABASE_URL, init=db._init)  # noqa: SLF001
        job = await repo.claim(worker.pool, "gpu")
        await worker.process(job)
        row = await worker.pool.fetchrow("SELECT status, error FROM jobs WHERE id = $1", job["id"])
        await worker.pool.close()
        return row

    try:
        assert "sem permissão de escrita" in worker_main.storage_problem()
        row = run(scenario())
    finally:
        locked.chmod(0o700)
    assert row["status"] == "failed" and "arquivos temporários" in row["error"]
    assert worker_main.storage_problem() is None
