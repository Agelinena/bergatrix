"""
Berga News — API
"""
import logging
import sys

from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import AdminRequired, LoginRequired, seed_admin
from db import SessionLocal, init_db
from routers import admin, articles, auth_router, digests, feeds, reader, settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)

app = FastAPI(title="Berga News", docs_url=None, redoc_url=None)
templates = Jinja2Templates(directory="templates")


@app.exception_handler(LoginRequired)
async def login_required_handler(request: Request, exc: LoginRequired):
    return RedirectResponse(url="/login", status_code=303)


@app.exception_handler(AdminRequired)
async def admin_required_handler(request: Request, exc: AdminRequired):
    return templates.TemplateResponse(
        "login.html",
        {"request": request, "error": "Acesso restrito a administradores."},
        status_code=403,
    )


app.mount("/static", StaticFiles(directory="static"), name="static")

app.include_router(auth_router.router)
app.include_router(digests.router)
app.include_router(articles.router)
app.include_router(reader.router)
app.include_router(feeds.router)
app.include_router(settings.router)
app.include_router(admin.router)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.on_event("startup")
def startup():
    init_db()
    db: Session = SessionLocal()
    try:
        seed_admin(db)
    finally:
        db.close()
