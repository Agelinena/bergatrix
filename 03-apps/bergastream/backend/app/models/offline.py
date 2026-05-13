import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, ForeignKey, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class OfflineTrack(Base):
    __tablename__ = "offline_tracks"
    __table_args__ = (UniqueConstraint("user_id", "track_id", name="uq_offline_track"),)

    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    track_id: Mapped[str] = mapped_column(String(100), ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True)
    downloaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    device_path: Mapped[str | None] = mapped_column(String, nullable=True)

    user: Mapped["User"] = relationship("User", back_populates="offline_tracks")
    track: Mapped["Track"] = relationship("Track", back_populates="offline_tracks")
