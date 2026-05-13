from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.track import TrackSchema
from app.services.radio_service import RadioService

router = APIRouter(prefix="/radio", tags=["radio"])


@router.post("/seed")
async def radio_seed(
    body: dict,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    track_id: str = body.get("track_id", "")
    source: str = body.get("source", "deezer")
    limit: int = body.get("limit", 10)

    tracks = await RadioService.get_seeds(track_id, source, limit, db)
    return {"tracks": tracks}


@router.get("/next")
async def radio_next(
    track_id: str = Query(...),
    source: str = Query("lastfm", pattern="^(lastfm|ai)$"),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    tracks = await RadioService.get_seeds(track_id, source, 1, db)
    return {"track": tracks[0] if tracks else None}
