"""Modelos do módulo tracks (catálogo interno de faixas)."""

from __future__ import annotations
from datetime import datetime

from pydantic import BaseModel, field_validator


class Track(BaseModel):
    """Faixa interna — retornada pelo banco."""
    id: str
    title: str
    artist: str
    album: str | None = None
    duration_seconds: int
    isrc: str | None = None
    cover_url: str | None = None
    created_at: datetime | None = None

    @field_validator("id", mode="before")
    @classmethod
    def coerce_id(cls, v):
        return str(v)


class PlayRequest(BaseModel):
    """Corpo do POST /api/play — mesmos campos de um SearchResult."""
    provider: str        # 'spotify' | 'youtube'
    external_id: str
    title: str
    artist: str
    album: str = ""
    duration_seconds: int = 0
    isrc: str | None = None
    cover_url: str | None = None


class PlayResponse(BaseModel):
    """Resposta do POST /api/play."""
    track_id: str
    status: str  # 'ready' | 'registered'