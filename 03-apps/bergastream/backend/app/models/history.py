import uuid
from datetime import datetime
from sqlalchemy import String, Boolean, Integer, DateTime, ForeignKey, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class PlayHistory(Base):
    __tablename__ = "play_history"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    track_id: Mapped[str] = mapped_column(String(100), ForeignKey("tracks.id", ondelete="CASCADE"), nullable=False)
    played_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    duration_played_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    source_context: Mapped[str | None] = mapped_column(String, nullable=True)  # 'search' | 'radio' | 'playlist' | 'album'
    context_id: Mapped[str | None] = mapped_column(String, nullable=True)      # playlist/album ID

    user: Mapped["User"] = relationship("User", back_populates="play_history")
    track: Mapped["Track"] = relationship("Track", back_populates="play_history")
