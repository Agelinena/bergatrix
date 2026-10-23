"""Testes do Transcriptor.

Os de integração usam um Postgres de verdade, já migrado pelo dbmate:

    docker run -d --name transcriptor-test-db -e POSTGRES_PASSWORD=test -p 55432:5432 postgres:16-alpine
    docker run --rm --network host -v "$PWD/db:/db" ghcr.io/amacneil/dbmate:2 \
        --url "postgres://postgres:test@127.0.0.1:55432/postgres?sslmode=disable" --no-dump-schema up
    TRANSCRIPTOR_TEST_DATABASE_URL=postgresql://postgres:test@127.0.0.1:55432/postgres pytest tests

Sem a variável, só os testes que não precisam de banco rodam.
"""

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

TEST_DATABASE_URL = os.environ.get("TRANSCRIPTOR_TEST_DATABASE_URL", "")
WORK = tempfile.mkdtemp(prefix="transcriptor-work-")

os.environ.update({
    "TRANSCRIPTOR_DATABASE_URL": TEST_DATABASE_URL or "postgresql://invalid/invalid",
    "TRANSCRIPTOR_PUBLIC_URL": "https://transcriptor.example.com",
    "TRANSCRIPTOR_WORK_DIR": WORK,
    "TRANSCRIPTOR_MODELS_DIR": tempfile.mkdtemp(prefix="transcriptor-models-"),
    "TRANSCRIPTOR_OIDC_ISSUER": "https://authentik.example.com/application/o/transcriptor/",
    "TRANSCRIPTOR_SSO_CLIENT_ID": "transcriptor-client",
    "TRANSCRIPTOR_SSO_CLIENT_SECRET": "segredo-de-teste",
})
