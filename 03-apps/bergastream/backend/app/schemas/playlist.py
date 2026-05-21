import uuid
from datetime import datetime
from pydantic import BaseModel
from app.schemas.track import TrackSchema


class PlaylistCreateRequest(BaseModel):
    name: str
    description: str | None = None
    is_public: bool = False


class PlaylistUpdateRequest(BaseModel):
    name: str | None = None
    description: str | None = None
    cover_url: str | None = None
    is_public: bool | None = None


class PlaylistTrackSchema(BaseModel):
    id: str
    track: TrackSchema
    position: int
    added_at: datetime
    added_by_username: str | None = None  # populated server-side via join

    model_config = {"from_attributes": True}


class CollaboratorSchema(BaseModel):
    user_id: str
    username: str
    email: str
    added_at: datetime

    model_config = {"from_attributes": True}


class PlaylistSchema(BaseModel):
    id: uuid.UUID
    name: str
    description: str | None
    cover_url: str | None
    is_public: bool
    is_shared: bool
    share_token: str | None
    owner_id: uuid.UUID
    created_at: datetime
    updated_at: datetime
    track_count: int = 0
    is_collaborative: bool = False  # True se o usuário atual é colaborador (não dono)

    model_config = {"from_attributes": True}


class PlaylistDetailSchema(PlaylistSchema):
    tracks: list[PlaylistTrackSchema] = []
    collaborators: list[CollaboratorSchema] = []


class AddTrackRequest(BaseModel):
    track_id: str
    position: int | None = None


class ReorderRequest(BaseModel):
    track_ids: list[str]


class ShareResponse(BaseModel):
    share_token: str
    share_url: str
