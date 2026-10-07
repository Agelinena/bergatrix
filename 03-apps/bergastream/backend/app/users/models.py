"""Modelos do módulo users (fantasmas)."""
from __future__ import annotations
from pydantic import BaseModel, field_validator


class User(BaseModel):
    id: str
    name: str

    @field_validator("id", mode="before")
    @classmethod
    def coerce_id(cls, v):
        return str(v)


class Playlist(BaseModel):
    id: str
    user_id: str
    name: str

    @field_validator("id", "user_id", mode="before")
    @classmethod
    def coerce_id(cls, v):
        return str(v)