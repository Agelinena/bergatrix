"""
Session-based authentication helpers.
"""
import os
import uuid
from datetime import datetime, timedelta
from typing import Optional

import bcrypt
from fastapi import Depends, Request
from sqlalchemy.orm import Session

from db import UserSession, User, get_db

SESSION_DAYS = 30


class LoginRequired(Exception):
    pass


class AdminRequired(Exception):
    pass


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain.encode(), hashed.encode())


def create_session(db: Session, user: User) -> str:
    token = str(uuid.uuid4())
    session = UserSession(
        id=token,
        user_id=user.id,
        expires_at=datetime.utcnow() + timedelta(days=SESSION_DAYS),
    )
    db.add(session)
    db.commit()
    return token


def delete_session(db: Session, token: str):
    s = db.get(UserSession, token)
    if s:
        db.delete(s)
        db.commit()


def get_user(request: Request, db: Session = Depends(get_db)) -> Optional[User]:
    token = request.cookies.get("session_id")
    if not token:
        return None
    session = (
        db.query(UserSession)
        .filter(UserSession.id == token, UserSession.expires_at > datetime.utcnow())
        .first()
    )
    if not session:
        return None
    return db.get(User, session.user_id)


def require_login(user: Optional[User] = Depends(get_user)) -> User:
    if user is None:
        raise LoginRequired()
    return user


def require_admin(user: User = Depends(require_login)) -> User:
    if user.role != "admin":
        raise AdminRequired()
    return user


def seed_admin(db: Session):
    """Create admin user from env if no users exist."""
    if db.query(User).count() > 0:
        return
    username = os.environ.get("ADMIN_USERNAME", "admin")
    password = os.environ.get("ADMIN_PASSWORD", "changeme")
    admin = User(
        username=username,
        password_hash=hash_password(password),
        role="admin",
    )
    db.add(admin)
    db.commit()
