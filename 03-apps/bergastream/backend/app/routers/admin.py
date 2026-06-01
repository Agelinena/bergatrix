"""Admin-only endpoints for user management and queue diagnostics."""
import uuid
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.database import get_db
from app.dependencies import require_admin
from app.models.user import User
from app.schemas.auth import UserResponse, AdminCreateUserRequest, AdminUpdateUserRequest
from app.services import auth_service
from app.services.queue_service import DownloadQueueService

router = APIRouter(prefix="/admin", tags=["admin"])


def _user_response(user: User) -> UserResponse:
    return UserResponse(
        id=str(user.id),
        username=user.username,
        email=user.email,
        avatar_url=user.avatar_url,
        is_admin=user.is_admin,
        is_active=user.is_active,
    )


@router.get("/users", response_model=list[UserResponse])
async def list_users(
    db: AsyncSession = Depends(get_db),
    _admin: User = Depends(require_admin),
):
    result = await db.execute(select(User).order_by(User.created_at.asc()))
    return [_user_response(u) for u in result.scalars().all()]


@router.post("/users", response_model=UserResponse, status_code=201)
async def create_user(
    body: AdminCreateUserRequest,
    db: AsyncSession = Depends(get_db),
    _admin: User = Depends(require_admin),
):
    if await auth_service.get_user_by_email(db, body.email):
        raise HTTPException(status_code=400, detail="Este e-mail já está cadastrado")
    if await auth_service.get_user_by_username(db, body.username):
        raise HTTPException(status_code=400, detail="Este nome de usuário já está em uso")

    user = await auth_service.create_user(db, body.username, body.email, body.password)
    if body.is_admin:
        user.is_admin = True
        await db.flush()
    return _user_response(user)


@router.patch("/users/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: uuid.UUID,
    body: AdminUpdateUserRequest,
    db: AsyncSession = Depends(get_db),
    admin: User = Depends(require_admin),
):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="Usuário não encontrado")

    # Prevent admin from removing their own admin role
    if str(user.id) == str(admin.id) and body.is_admin is False:
        raise HTTPException(status_code=400, detail="Você não pode remover sua própria permissão de admin")

    if body.is_admin is not None:
        user.is_admin = body.is_admin
    if body.is_active is not None:
        user.is_active = body.is_active

    await db.flush()
    return _user_response(user)


@router.delete("/users/{user_id}", status_code=204)
async def delete_user(
    user_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    admin: User = Depends(require_admin),
):
    if str(user_id) == str(admin.id):
        raise HTTPException(status_code=400, detail="Você não pode excluir sua própria conta pelo painel admin")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="Usuário não encontrado")

    await db.delete(user)
    await db.flush()


@router.get("/queue-stats")
async def queue_stats(_admin: User = Depends(require_admin)):
    """
    Snapshot of the download queue system: queue depths, in-flight downloads,
    queued tracks, and promotion markers.  Useful for diagnosing stuck tracks.
    """
    return await DownloadQueueService.queue_stats()


@router.get("/updater/status")
async def updater_status(_admin: User = Depends(require_admin)):
    """Last upgrade pass results from the background UpdaterService."""
    from app.services.updater_service import UpdaterService
    return UpdaterService.status()


@router.post("/updater/run")
async def updater_run(_admin: User = Depends(require_admin)):
    """Force-run an upgrade pass for yt-dlp / ytmusicapi / spotipy / mutagen.

    May take a few minutes if pip needs to download everything.
    """
    from app.services.updater_service import UpdaterService
    return await UpdaterService.run_once()
