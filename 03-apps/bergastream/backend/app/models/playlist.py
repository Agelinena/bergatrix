import uuid
import secrets
from datetime import datetime
from sqlalchemy import String, Boolean, Integer, DateTime, ForeignKey, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class Playlist(Base):
    __tablename__ = "playlists"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    description: Mapped[str | None] = mapped_column(String, nullable=True)
    cover_url: Mapped[str | None] = mapped_column(String, nullable=True)
    is_public: Mapped[bool] = mapped_column(Boolean, default=False)
    is_shared: Mapped[bool] = mapped_column(Boolean, default=False)
    share_token: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    owner: Mapped["User"] = relationship("User", back_populates="playlists")
    tracks: Mapped[list["PlaylistTrack"]] = relationship(
        "PlaylistTrack", back_populates="playlist",
        cascade="all, delete-orphan",
        order_by="PlaylistTrack.position",
    )
    collaborators: Mapped[list["PlaylistCollaborator"]] = relationship(
        "PlaylistCollaborator", back_populates="playlist", cascade="all, delete-orphan",
    )

    def generate_share_token(self) -> str:
        self.share_token = secrets.token_urlsafe(48)
        self.is_shared = True
        return self.share_token


class PlaylistTrack(Base):
    __tablename__ = "playlist_tracks"
    __table_args__ = (UniqueConstraint("playlist_id", "position", name="uq_playlist_track_position"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    playlist_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("playlists.id", ondelete="CASCADE"), nullable=False)
    track_id: Mapped[str] = mapped_column(String(100), ForeignKey("tracks.id", ondelete="CASCADE"), nullable=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    added_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)

    playlist: Mapped[Playlist] = relationship("Playlist", back_populates="tracks")
    track: Mapped["Track"] = relationship("Track", back_populates="playlist_tracks")


class PlaylistCollaborator(Base):
    """Users who can add/remove tracks from a playlist (but are not the owner)."""
    __tablename__ = "playlist_collaborators"
    __table_args__ = (UniqueConstraint("playlist_id", "user_id", name="uq_playlist_collaborator"),)

    playlist_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("playlists.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    playlist: Mapped[Playlist] = relationship("Playlist", back_populates="collaborators")
    user: Mapped["User"] = relationship("User", back_populates="collaborating_playlists")


class LikedSong(Base):
    __tablename__ = "liked_songs"
    __table_args__ = (UniqueConstraint("user_id", "track_id", name="uq_liked_song"),)

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    track_id: Mapped[str] = mapped_column(String(100), ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True)
    liked_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    user: Mapped["User"] = relationship("User", back_populates="liked_songs")
    track: Mapped["Track"] = relationship("Track", back_populates="liked_by")
