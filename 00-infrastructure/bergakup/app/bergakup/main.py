"""Bergakup: interface e API de configuração do backup.

Este serviço só guarda e distribui a configuração. Quem faz backup e
restauração é o bergakup-agent, no host. Este container pode ficar desligado
que os backups continuam rodando com a última revisão aplicada."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from urllib.parse import quote

from fastapi import Depends, FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from bergakup import agent_api, auth, web_api
from bergakup.config import settings
from bergakup.db import create_pool

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("bergakup")

STATIC = Path(settings.static_dir)
WATCH_SECONDS = 300


async def watchdog(app: FastAPI) -> None:
    """Alertas que o agente não consegue dar: ele mesmo sumiu, ou uma tarefa
    está atrasada. Ficam na interface (o e-mail é do agente)."""
    while True:
        try:
            db = app.state.pool
            await db.execute(
                """INSERT INTO notifications (agent_id, level, title, body, dedupe_key)
                   SELECT id, 'error', 'Agente ' || name || ' sem sinal de vida',
                          'Último contato: ' || coalesce(to_char(last_seen_at AT TIME ZONE 'America/Sao_Paulo',
                          'DD/MM HH24:MI'), 'nunca') || '. Os backups agendados podem não estar rodando.',
                          'agent-offline:' || id
                   FROM agents WHERE last_seen_at < now() - make_interval(mins => $1)
                   ON CONFLICT DO NOTHING""", settings.agent_stale_minutes)
            await db.execute(
                """INSERT INTO notifications (agent_id, level, title, body, dedupe_key)
                   SELECT d.agent_id, 'warning', 'Tarefa atrasada: ' || j.name,
                          'Nenhum backup com sucesso nas últimas ' || j.stale_hours || ' horas.',
                          'job-late:' || j.id
                   FROM jobs j JOIN repositories r ON r.id = j.repository_id JOIN datasets d ON d.id = r.dataset_id
                   WHERE j.enabled AND j.created_at < now() - make_interval(hours => j.stale_hours)
                     AND NOT EXISTS (SELECT 1 FROM runs x WHERE x.job_id = j.id AND x.kind = 'backup'
                                     AND x.status IN ('success', 'warning')
                                     AND x.finished_at > now() - make_interval(hours => j.stale_hours))
                   ON CONFLICT DO NOTHING""")
            # Limpeza: logs de consultas rápidas (ls, snapshots) não precisam ficar.
            await db.execute(
                """DELETE FROM runs WHERE kind IN ('ls', 'snapshots', 'discover', 'test')
                   AND started_at < now() - interval '2 days'""")
            await db.execute("DELETE FROM sessions WHERE expires_at < now()")
        except Exception:
            logger.exception("[watchdog] falhou")
        await asyncio.sleep(WATCH_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await create_pool()
    app.state.settings = settings
    task = asyncio.create_task(watchdog(app))
    try:
        yield
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        await app.state.pool.close()


app = FastAPI(title="Bergakup", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

CONTENT_SECURITY_POLICY = "; ".join((
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self'",
    "img-src 'self' data:",
    "connect-src 'self'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
))


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
    response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    if settings.secure_cookies:
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
    path = request.url.path
    response.headers.setdefault("Cache-Control", "public, max-age=31536000, immutable"
                                if path.startswith("/assets/") else "no-store")
    return response


app.include_router(agent_api.router)
app.include_router(web_api.router)


@app.get("/health", include_in_schema=False)
async def health(request: Request):
    await request.app.state.pool.fetchval("SELECT 1")
    return {"status": "ok"}


@app.get("/auth/login", include_in_schema=False)
async def login(request: Request, next: str = "/"):
    if not settings.oidc_enabled:
        return RedirectResponse("/login?erro=" + quote("O login pelo Authentik não está configurado."), 303)
    try:
        url = await auth.begin_login(request.app.state.pool, next)
    except Exception as error:
        logger.warning("[oidc] Authentik indisponível: %s", error)
        return RedirectResponse("/login?erro=" + quote("O Authentik não respondeu. Tente de novo."), 303)
    return RedirectResponse(url, 303)


@app.get("/auth/callback", include_in_schema=False)
async def callback(request: Request, code: str = "", state: str = "", error: str = ""):
    if error or not code:
        return RedirectResponse("/login?erro=" + quote("O login foi cancelado no Authentik."), 303)
    try:
        token, next_path = await auth.finish_login(request.app.state.pool, code, state,
                                                   request.headers.get("user-agent", ""))
    except auth.LoginError as failure:
        return RedirectResponse("/login?erro=" + quote(str(failure)), 303)
    except Exception as failure:
        logger.exception("[oidc] falha no retorno do login: %s", failure)
        return RedirectResponse("/login?erro=" + quote("Não foi possível concluir o login."), 303)
    response = RedirectResponse(next_path, 303)
    response.set_cookie(auth.SESSION_COOKIE, token, max_age=settings.session_days * 86400, path="/",
                        secure=settings.secure_cookies, httponly=True, samesite="lax")
    return response


@app.post("/auth/logout", include_in_schema=False)
async def logout(request: Request, user: auth.User = Depends(auth.current_user)):
    await auth.end_session(request.app.state.pool, request.cookies.get(auth.SESSION_COOKIE))
    response = JSONResponse({"status": "ok"})
    response.delete_cookie(auth.SESSION_COOKIE, path="/", secure=settings.secure_cookies, httponly=True,
                           samesite="lax")
    return response


@app.get("/robots.txt", include_in_schema=False)
async def robots():
    return Response("User-agent: *\nDisallow: /\n", media_type="text/plain")


if (STATIC / "assets").is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC / "assets"), name="assets")


@app.get("/{path:path}", include_in_schema=False)
async def spa(path: str):
    """A interface React (rotas do lado do navegador)."""
    if path.startswith(("api/", "agent/", "auth/")):
        return JSONResponse({"detail": "Não encontrado."}, 404)
    candidate = (STATIC / path).resolve()
    if path and candidate.is_file() and STATIC.resolve() in candidate.parents:
        return FileResponse(candidate)
    return FileResponse(STATIC / "index.html", media_type="text/html; charset=utf-8")
