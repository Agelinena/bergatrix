from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import (
    create_session, delete_session, get_user, hash_password,
    verify_password,
)
from db import User, get_db

router = APIRouter()
templates = Jinja2Templates(directory="templates")


@router.get("/login", response_class=HTMLResponse)
def login_page(request: Request, user=Depends(get_user), error: str = ""):
    if user:
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse("login.html", {"request": request, "error": error})


@router.post("/login")
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_password(password, user.password_hash):
        return templates.TemplateResponse(
            "login.html",
            {"request": request, "error": "Usuário ou senha incorretos."},
            status_code=401,
        )
    token = create_session(db, user)
    response = RedirectResponse("/", status_code=303)
    response.set_cookie(
        "session_id", token,
        httponly=True, samesite="lax", secure=True,
        max_age=60 * 60 * 24 * 30,
    )
    return response


@router.post("/logout")
def logout(request: Request, db: Session = Depends(get_db)):
    token = request.cookies.get("session_id")
    if token:
        delete_session(db, token)
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie("session_id")
    return response
