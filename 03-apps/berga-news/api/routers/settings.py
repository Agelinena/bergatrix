"""
Settings router — /settings
User profile: change username, change password, active sessions, logout all.
"""
import logging

import bcrypt
from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from auth import require_login, hash_password, verify_password
from db import User, UserSession, get_db

router = APIRouter(prefix="/settings")
templates = Jinja2Templates(directory="templates")
log = logging.getLogger("settings")


@router.get("")
def settings_page(
    request: Request,
    msg: str = "",
    error: str = "",
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    sessions = (
        db.query(UserSession)
        .filter(UserSession.user_id == user.id)
        .order_by(UserSession.created_at.desc())
        .all()
    )
    return templates.TemplateResponse(
        "settings.html",
        {
            "request": request,
            "user": user,
            "sessions": sessions,
            "msg": msg,
            "error": error,
        },
    )


@router.post("/username")
def change_username(
    request: Request,
    username: str = Form(...),
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    username = username.strip()
    if not username or len(username) < 3:
        return RedirectResponse("/settings?error=Nome+deve+ter+ao+menos+3+caracteres", status_code=303)

    existing = db.query(User).filter(User.username == username, User.id != user.id).first()
    if existing:
        return RedirectResponse("/settings?error=Nome+de+usu%C3%A1rio+j%C3%A1+em+uso", status_code=303)

    user.username = username
    db.commit()
    log.info("User %s renamed to %s", user.id, username)
    return RedirectResponse("/settings?msg=Nome+atualizado+com+sucesso", status_code=303)


@router.post("/password")
def change_password(
    request: Request,
    current_password: str = Form(...),
    new_password: str = Form(...),
    confirm_password: str = Form(...),
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    if not verify_password(current_password, user.password_hash):
        return RedirectResponse("/settings?error=Senha+atual+incorreta", status_code=303)

    if len(new_password) < 8:
        return RedirectResponse("/settings?error=Nova+senha+deve+ter+ao+menos+8+caracteres", status_code=303)

    if new_password != confirm_password:
        return RedirectResponse("/settings?error=As+senhas+n%C3%A3o+coincidem", status_code=303)

    user.password_hash = hash_password(new_password)
    db.commit()
    log.info("User %s changed password", user.id)
    return RedirectResponse("/settings?msg=Senha+alterada+com+sucesso", status_code=303)


@router.post("/logout-all")
def logout_all_sessions(
    request: Request,
    user: User = Depends(require_login),
    db: Session = Depends(get_db),
):
    """Revoke all sessions except the current one."""
    current_token = request.cookies.get("session_id")
    db.query(UserSession).filter(
        UserSession.user_id == user.id,
        UserSession.id != current_token,
    ).delete()
    db.commit()
    return RedirectResponse("/settings?msg=Todas+as+outras+sess%C3%B5es+encerradas", status_code=303)
