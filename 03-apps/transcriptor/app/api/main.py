"""API e interface web do Transcriptor. A transcrição em si roda no worker
(app/worker), que pega os jobs da fila no Postgres."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import mimetypes
import shutil
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Literal
from urllib.parse import quote, urlsplit
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from starlette.requests import ClientDisconnect

from app import db, formats
from app import jobs as repo
from app.api import auth
from app.api.events import hub
from app.catalog import CATALOG, LANGUAGES, available
from app.config import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("transcriptor.api")

STATIC = Path(__file__).resolve().parent / "static"
UPLOAD_CHUNK_BYTES = 8 * 1024 * 1024
DISK_MARGIN_BYTES = 2 * 1024 * 1024 * 1024
SSE_KEEPALIVE_SECONDS = 20
WORKER_STALE_SECONDS = 90
# Um pedaço por vez por upload: dois PUTs no mesmo offset duplicariam dados.
upload_locks: defaultdict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("font/woff2", ".woff2")


@asynccontextmanager
async def lifespan(app: FastAPI):
    Path(settings.work_dir).mkdir(parents=True, exist_ok=True)
    app.state.pool = await db.create_pool()
    hub.start()
    try:
        yield
    finally:
        await hub.stop()
        await db.close_pool()


app = FastAPI(title="Transcriptor", lifespan=lifespan, docs_url=None, redoc_url=None,
              openapi_url="/api/openapi.json")

CONTENT_SECURITY_POLICY = "; ".join((
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "font-src 'self'",
    "img-src 'self' data:",
    "media-src 'self'",
    "connect-src 'self'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
))


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
    response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    if settings.secure_cookies:
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
    response.headers.setdefault("Cache-Control", "no-store" if request.url.path.startswith(("/api", "/auth")) or
                                request.url.path == "/" else "no-cache")
    return response


def pool(request: Request):
    return request.app.state.pool


# ── Páginas e login ──────────────────────────────────────────────────

@app.api_route("/", methods=["GET", "HEAD"], include_in_schema=False)
async def index():
    return FileResponse(STATIC / "index.html", media_type="text/html; charset=utf-8")


@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return FileResponse(STATIC / "assets" / "icon.svg", media_type="image/svg+xml")


@app.get("/robots.txt", include_in_schema=False)
async def robots():
    return Response("User-agent: *\nDisallow: /\n", media_type="text/plain")


@app.api_route("/health", methods=["GET", "HEAD"], include_in_schema=False)
async def health(request: Request):
    await pool(request).fetchval("SELECT 1")
    return {"status": "ok"}


@app.get("/auth/login", include_in_schema=False)
async def login(request: Request, next: str = "/"):
    if not settings.oidc_enabled:
        return RedirectResponse("/?erro=" + quote("O login pelo Authentik não está configurado."), 303)
    try:
        url = await auth.begin_login(pool(request), next)
    except Exception as error:
        logger.warning("[oidc] Authentik indisponível: %s", error)
        return RedirectResponse("/?erro=" + quote("O Authentik não respondeu. Tente de novo em instantes."), 303)
    return RedirectResponse(url, 303)


@app.get("/auth/callback", include_in_schema=False)
async def callback(request: Request, code: str = "", state: str = "", error: str = ""):
    if error or not code:
        return RedirectResponse("/?erro=" + quote("O login foi cancelado no Authentik."), 303)
    try:
        token, next_path = await auth.finish_login(pool(request), code, state,
                                                   request.headers.get("user-agent", ""))
    except auth.LoginError as failure:
        return RedirectResponse("/?erro=" + quote(str(failure)), 303)
    except Exception as failure:
        logger.exception("[oidc] falha no retorno do login: %s", failure)
        return RedirectResponse("/?erro=" + quote("Não foi possível concluir o login."), 303)
    response = RedirectResponse(next_path, 303)
    response.set_cookie(auth.SESSION_COOKIE, token, max_age=settings.session_days * 86400, path="/",
                        secure=settings.secure_cookies, httponly=True, samesite="lax")
    return response


@app.post("/auth/logout", include_in_schema=False)
async def logout(request: Request, user: auth.User = Depends(auth.web_user)):
    await auth.end_session(pool(request), request.cookies.get(auth.SESSION_COOKIE))
    response = JSONResponse({"status": "ok"})
    response.delete_cookie(auth.SESSION_COOKIE, path="/", secure=settings.secure_cookies, httponly=True,
                           samesite="lax")
    return response


# ── Conta e configuração ─────────────────────────────────────────────

@app.get("/api/me")
async def me(user: auth.User = Depends(auth.current_user)):
    return {"username": user.username, "name": user.name, "email": user.email, "is_admin": user.is_admin}


async def worker_rows(request: Request):
    return await pool(request).fetch(
        """SELECT name, state, detail, heartbeat_at,
                  heartbeat_at > now() - make_interval(secs => $1) AS alive
           FROM workers ORDER BY name""", WORKER_STALE_SECONDS)


@app.get("/api/config")
async def config(request: Request, user: auth.User = Depends(auth.current_user)):
    ready: set[str] = set()
    worker_alive = False
    for row in await worker_rows(request):
        if row["alive"]:
            worker_alive = True
            ready.update(name for name, ok in (row["detail"].get("models") or {}).items() if ok == "ok")
    return {
        "models": [{"id": m.id, "label": m.label, "description": m.description, "ready": m.id in ready}
                   for m in available(settings.enabled_models)],
        "default_model": settings.default_model,
        "languages": [{"id": code, "label": label} for code, label in LANGUAGES.items()],
        "max_upload_bytes": settings.max_upload_bytes,
        "max_duration_minutes": settings.max_duration_minutes,
        "upload_chunk_bytes": UPLOAD_CHUNK_BYTES,
        "retention_days": settings.retention_days,
        "audio_days": settings.audio_days,
        "worker_alive": worker_alive,
    }


@app.get("/api/admin/status")
async def admin_status(request: Request, user: auth.User = Depends(auth.admin_user)):
    counts = await pool(request).fetch("SELECT status, count(*) AS n FROM jobs GROUP BY status")
    return {
        "workers": [{"name": r["name"], "state": r["state"], "alive": r["alive"], "detail": r["detail"],
                     "heartbeat_at": r["heartbeat_at"].isoformat()} for r in await worker_rows(request)],
        "jobs": {r["status"]: r["n"] for r in counts},
        "disk_free_bytes": shutil.disk_usage(settings.work_dir).free,
    }


# ── Jobs ─────────────────────────────────────────────────────────────

class JobOptions(BaseModel):
    model: str | None = None
    language: str | None = Field(default="pt", max_length=8)
    prompt: str = Field(default="", max_length=600)


class UrlJob(JobOptions):
    url: str = Field(max_length=2048)


class UploadStart(JobOptions):
    name: str = Field(min_length=1, max_length=255)
    size: int = Field(gt=0)


class JobPatch(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class SegmentPatch(BaseModel):
    text: str = Field(max_length=5000)


def check_options(options: JobOptions) -> tuple[str, str | None, str]:
    model = options.model or settings.default_model
    if model not in settings.enabled_models or model not in CATALOG:
        raise HTTPException(422, "Modelo indisponível.")
    language = options.language or None
    if language is not None and language not in LANGUAGES:
        raise HTTPException(422, "Idioma não suportado.")
    return model, language, options.prompt.strip()


def check_url(url: str) -> str:
    """Primeira barreira contra SSRF. A barreira real é o proxy de saída do
    worker, que recusa qualquer destino em rede privada depois de resolver o DNS."""
    url = url.strip()
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        raise HTTPException(422, "Use um link http:// ou https://.")
    host = parts.hostname.rstrip(".").lower()
    if host == "localhost" or host.endswith((".localhost", ".local", ".internal", ".lan", ".home.arpa")) \
            or "." not in host and ":" not in host:
        raise HTTPException(422, "Esse endereço não é permitido.")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return url
    if not address.is_global:
        raise HTTPException(422, "Esse endereço não é permitido.")
    return url


async def owned_job(request: Request, job_id: UUID, user: auth.User):
    job = await repo.get(pool(request), user.id, job_id)
    if job is None:
        raise HTTPException(404, "Transcrição não encontrada.")
    return job


async def check_capacity(request: Request, user: auth.User, size: int = 0) -> None:
    if await repo.active_count(pool(request), user.id) >= settings.max_active_jobs:
        raise HTTPException(429, f"Você já tem {settings.max_active_jobs} transcrições na fila. Espere algumas terminarem.")
    if size and shutil.disk_usage(settings.work_dir).free < size + DISK_MARGIN_BYTES:
        raise HTTPException(507, "O servidor está sem espaço para esse arquivo agora.")


@app.get("/api/jobs")
async def list_jobs(request: Request, q: str = Query("", max_length=200), before: datetime | None = None,
                    limit: int = Query(50, ge=1, le=200), user: auth.User = Depends(auth.current_user)):
    rows = await repo.listing(pool(request), user.id, q.strip(), limit, before)
    return {"jobs": [repo.public(r) for r in rows]}


@app.post("/api/jobs", status_code=201)
async def create_url_job(request: Request, body: UrlJob, user: auth.User = Depends(auth.current_user)):
    model, language, prompt = check_options(body)
    url = check_url(body.url)
    await check_capacity(request, user)
    row = await repo.create(pool(request), user.id, title=url[:200], source_kind="url", source_url=url,
                            model=model, language=language, prompt=prompt, status="queued")
    return repo.public(row)


@app.get("/api/jobs/{job_id}")
async def get_job(request: Request, job_id: UUID, segments: bool = True,
                  user: auth.User = Depends(auth.current_user)):
    job = await owned_job(request, job_id, user)
    if not segments:
        return repo.public(job)
    segments = await repo.segments(pool(request), job_id)
    return {**repo.public(job), "segments": [s.__dict__ for s in segments]}


@app.get("/api/jobs/{job_id}/segments")
async def get_segments(request: Request, job_id: UUID, after: int = -1, user: auth.User = Depends(auth.current_user)):
    await owned_job(request, job_id, user)
    return {"segments": [s.__dict__ for s in await repo.segments(pool(request), job_id, after)]}


@app.patch("/api/jobs/{job_id}")
async def patch_job(request: Request, job_id: UUID, body: JobPatch, user: auth.User = Depends(auth.current_user)):
    await owned_job(request, job_id, user)
    await repo.rename(pool(request), job_id, body.title.strip())
    return repo.public(await owned_job(request, job_id, user))


@app.put("/api/jobs/{job_id}/segments/{idx}")
async def put_segment(request: Request, job_id: UUID, idx: int, body: SegmentPatch,
                      user: auth.User = Depends(auth.current_user)):
    job = await owned_job(request, job_id, user)
    if job["status"] != "done":
        raise HTTPException(409, "Espere a transcrição terminar para editar.")
    if not await repo.edit_segment(pool(request), job_id, idx, body.text.strip()):
        raise HTTPException(404, "Trecho não encontrado.")
    return {"status": "ok"}


@app.post("/api/jobs/{job_id}/cancel")
async def cancel_job(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    job = await owned_job(request, job_id, user)
    if job["status"] in repo.FINISHED:
        raise HTTPException(409, "Essa transcrição já terminou.")
    await repo.cancel(pool(request), job_id)
    return repo.public(await owned_job(request, job_id, user))


@app.post("/api/jobs/{job_id}/retry")
async def retry_job(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    job = await owned_job(request, job_id, user)
    if job["source_kind"] == "upload" and not repo.upload_path(job_id).exists():
        raise HTTPException(409, "O arquivo enviado já foi apagado. Envie de novo.")
    await check_capacity(request, user)
    if not await repo.retry(pool(request), job_id):
        raise HTTPException(409, "Só dá para tentar de novo uma transcrição que falhou ou foi cancelada.")
    return repo.public(await owned_job(request, job_id, user))


@app.delete("/api/jobs/{job_id}", status_code=204)
async def delete_job(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    await owned_job(request, job_id, user)
    await repo.delete(pool(request), job_id)
    return Response(status_code=204)


def download_name(title: str, extension: str) -> str:
    stem = "".join(c if c.isalnum() or c in " ._-" else "_" for c in title).strip(" ._")[:80] or "transcricao"
    return f"{stem}.{extension}"


@app.get("/api/jobs/{job_id}/export/{kind}")
async def export(request: Request, job_id: UUID, kind: Literal["txt", "srt", "vtt", "json"],
                 user: auth.User = Depends(auth.current_user)):
    job = await owned_job(request, job_id, user)
    segments = await repo.segments(pool(request), job_id)
    if kind == "json":
        media_type, body = "application/json; charset=utf-8", formats.to_json(dict(job), segments)
    else:
        media_type, render = formats.EXPORTS[kind]
        body = render(segments)
    name = download_name(job["title"], kind)
    return Response(body, media_type=media_type, headers={
        "Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"})


@app.get("/api/jobs/{job_id}/audio")
async def audio(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    await owned_job(request, job_id, user)
    path = repo.playback_path(job_id)
    if not path.exists():
        raise HTTPException(404, "O áudio desta transcrição já foi apagado.")
    return FileResponse(path, media_type="audio/mp4", headers={"Cache-Control": "private, max-age=3600"})


# ── Upload em pedaços (retomável; cada pedido cabe no tempo do Traefik) ──

@app.post("/api/uploads", status_code=201)
async def start_upload(request: Request, body: UploadStart, user: auth.User = Depends(auth.current_user)):
    model, language, prompt = check_options(body)
    if body.size > settings.max_upload_bytes:
        raise HTTPException(413, f"O limite é {settings.max_upload_mb} MB por arquivo.")
    await check_capacity(request, user, body.size)
    row = await repo.create(pool(request), user.id, title=body.name.strip()[:200], source_kind="upload",
                            source_bytes=body.size, model=model, language=language, prompt=prompt,
                            status="uploading")
    try:
        repo.work_dir(row["id"]).mkdir(parents=True, exist_ok=True)
        repo.upload_path(row["id"]).touch()
    except OSError as error:
        logger.error("[upload] sem permissão em %s: %s", settings.work_dir, error)
        await pool(request).execute("DELETE FROM jobs WHERE id = $1", row["id"])
        raise HTTPException(507, "O servidor não conseguiu gravar o arquivo. Avise o administrador.") from error
    return {**repo.public(row), "received": 0, "chunk_bytes": UPLOAD_CHUNK_BYTES}


async def uploading_job(request: Request, job_id: UUID, user: auth.User):
    job = await owned_job(request, job_id, user)
    if job["status"] != "uploading":
        raise HTTPException(409, "Esse envio já terminou.")
    return job


@app.get("/api/uploads/{job_id}")
async def upload_state(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    await uploading_job(request, job_id, user)
    path = repo.upload_path(job_id)
    return {"received": path.stat().st_size if path.exists() else 0}


@app.put("/api/uploads/{job_id}")
async def upload_chunk(request: Request, job_id: UUID, offset: int = Query(ge=0),
                       user: auth.User = Depends(auth.current_user)):
    async with upload_locks[str(job_id)]:
        return await write_chunk(request, job_id, offset, user)


async def write_chunk(request: Request, job_id: UUID, offset: int, user: auth.User):
    job = await uploading_job(request, job_id, user)
    path = repo.upload_path(job_id)
    received = path.stat().st_size if path.exists() else 0
    if offset != received:
        return JSONResponse({"detail": "Posição errada.", "received": received}, status_code=409)
    parts, size = [], 0
    try:
        async for piece in request.stream():
            size += len(piece)
            if size > UPLOAD_CHUNK_BYTES or received + size > job["source_bytes"]:
                raise HTTPException(413, "Pedaço maior que o combinado.")
            parts.append(piece)
    except ClientDisconnect:
        return Response(status_code=400)
    data = b"".join(parts)

    def append() -> None:
        with open(path, "ab") as handle:
            handle.write(data)

    await asyncio.to_thread(append)
    return {"received": received + len(data)}


@app.post("/api/uploads/{job_id}/complete")
async def complete_upload(request: Request, job_id: UUID, user: auth.User = Depends(auth.current_user)):
    job = await uploading_job(request, job_id, user)
    path = repo.upload_path(job_id)
    if not path.exists() or path.stat().st_size != job["source_bytes"]:
        raise HTTPException(409, "O arquivo ainda não chegou inteiro.")
    upload_locks.pop(str(job_id), None)
    await pool(request).execute("UPDATE jobs SET status = 'queued', created_at = now() WHERE id = $1", job_id)
    return repo.public(await owned_job(request, job_id, user))


# ── Eventos (SSE) ────────────────────────────────────────────────────

@app.get("/api/events")
async def events(request: Request, user: auth.User = Depends(auth.current_user)):
    user_id = str(user.id)
    queue = hub.subscribe(user_id)

    async def stream():
        try:
            yield "retry: 3000\n\n"
            while not await request.is_disconnected():
                try:
                    data = await asyncio.wait_for(queue.get(), SSE_KEEPALIVE_SECONDS)
                except asyncio.TimeoutError:
                    yield ": ping\n\n"
                    continue
                data.pop("user", None)
                yield f"data: {json.dumps(data)}\n\n"
        finally:
            hub.unsubscribe(user_id, queue)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


# ── Tokens pessoais ──────────────────────────────────────────────────

class TokenCreate(BaseModel):
    name: str = Field(min_length=1, max_length=60)


@app.get("/api/tokens")
async def list_tokens(request: Request, user: auth.User = Depends(auth.web_user)):
    rows = await pool(request).fetch(
        "SELECT id, name, prefix, created_at, last_used_at FROM api_tokens WHERE user_id = $1 ORDER BY created_at",
        user.id)
    return {"tokens": [auth.token_public(r) for r in rows]}


@app.post("/api/tokens", status_code=201)
async def create_token(request: Request, body: TokenCreate, user: auth.User = Depends(auth.web_user)):
    if await pool(request).fetchval("SELECT count(*) FROM api_tokens WHERE user_id = $1", user.id) >= 20:
        raise HTTPException(429, "No máximo 20 tokens por pessoa.")
    token, secret = await auth.create_token(pool(request), user.id, body.name.strip())
    return {**token, "token": secret}


@app.delete("/api/tokens/{token_id}", status_code=204)
async def delete_token(request: Request, token_id: UUID, user: auth.User = Depends(auth.web_user)):
    await pool(request).execute("DELETE FROM api_tokens WHERE id = $1 AND user_id = $2", token_id, user.id)
    return Response(status_code=204)


app.mount("/assets", StaticFiles(directory=STATIC / "assets"), name="assets")
