from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.dependencies import get_current_user, bearer_scheme
from app.models.user import User
from app.schemas.auth import (
    RegisterRequest, LoginRequest, TokenResponse, UserResponse,
    UpdateProfileRequest, ChangePasswordRequest,
)
from app.services import auth_service
from app.config import get_settings

settings = get_settings()
router = APIRouter(prefix="/auth", tags=["auth"])


def _user_response(user: User) -> UserResponse:
    return UserResponse(
        id=str(user.id),
        username=user.username,
        email=user.email,
        avatar_url=user.avatar_url,
        is_admin=user.is_admin,
        is_active=user.is_active,
    )


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterRequest, request: Request, db: AsyncSession = Depends(get_db)):
    if await auth_service.get_user_by_email(db, body.email):
        raise HTTPException(status_code=400, detail="Este e-mail já está cadastrado")
    if await auth_service.get_user_by_username(db, body.username):
        raise HTTPException(status_code=400, detail="Este nome de usuário já está em uso")

    user = await auth_service.create_user(db, body.username, body.email, body.password)
    token, _ = await auth_service.create_session(db, user.id, request.headers.get("user-agent"))
    return TokenResponse(access_token=token, expires_in=settings.jwt_expire_minutes * 60)


@router.post("/login", response_model=TokenResponse)
async def login(body: LoginRequest, request: Request, db: AsyncSession = Depends(get_db)):
    user = await auth_service.authenticate_user(db, body.email, body.password)
    if user is None:
        raise HTTPException(status_code=401, detail="E-mail ou senha inválidos")

    token, _ = await auth_service.create_session(db, user.id, request.headers.get("user-agent"))
    return TokenResponse(access_token=token, expires_in=settings.jwt_expire_minutes * 60)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    credentials=Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
):
    await auth_service.invalidate_session(db, credentials.credentials)


@router.get("/me", response_model=UserResponse)
async def me(current_user: User = Depends(get_current_user)):
    return _user_response(current_user)


@router.post("/change-password", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    body: ChangePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not auth_service.verify_password(body.current_password, current_user.password_hash):
        raise HTTPException(status_code=400, detail="Senha atual incorreta")
    current_user.password_hash = auth_service.hash_password(body.new_password)
    await db.flush()


@router.put("/me", response_model=UserResponse)
async def update_me(
    body: UpdateProfileRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if body.username and body.username != current_user.username:
        if await auth_service.get_user_by_username(db, body.username):
            raise HTTPException(status_code=400, detail="Este nome de usuário já está em uso")
        current_user.username = body.username

    if body.avatar_url is not None:
        current_user.avatar_url = body.avatar_url

    await db.flush()
    return _user_response(current_user)
