import uuid
from datetime import datetime
from pydantic import BaseModel
from app.schemas.track import TrackSchema


class RecordPlayRequest(BaseModel):
    track_id: str
    duration_played_ms: int
    completed: bool = False
    source_context: str | None = None
    context_id: str | None = None


class PlayHistorySchema(BaseModel):
    id: uuid.UUID
    track: TrackSchema
    played_at: datetime
    duration_played_ms: int | None
    completed: bool
    source_context: str | None

    model_config = {"from_attributes": True}


class HistoryStatsSchema(BaseModel):
    total_plays: int
    total_ms_played: int
    unique_tracks: int
    unique_artists: int
    top_artists: list[dict]
    top_tracks: list[dict]
    hours_per_day: list[dict]
