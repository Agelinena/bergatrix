from datetime import datetime
from sqlalchemy import String, Boolean, Integer, BigInteger, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class Track(Base):
    __tablename__ = "tracks"

    # ID format: "deezer_123456789" | "youtube_abc123" | "spotify_abc123"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    title: Mapped[str] = mapped_column(String, nullable=False)
    artist: Mapped[str] = mapped_column(String, nullable=False)
    album: Mapped[str | None] = mapped_column(String, nullable=True)
    album_id: Mapped[str | None] = mapped_column(String, nullable=True)
    artist_id: Mapped[str | None] = mapped_column(String, nullable=True)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    year: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cover_url: Mapped[str | None] = mapped_column(String, nullable=True)
    source: Mapped[str] = mapped_column(String(20), nullable=False)  # 'deezer' | 'youtube' | 'spotify'
    source_id: Mapped[str | None] = mapped_column(String, nullable=True)
    file_path: Mapped[str | None] = mapped_column(String, nullable=True)   # /data/music/permanent/
    cache_path: Mapped[str | None] = mapped_column(String, nullable=True)  # /data/music/cache/
    is_permanent: Mapped[bool] = mapped_column(Boolean, default=False)
    cache_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    file_size_bytes: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    audio_quality: Mapped[str | None] = mapped_column(String(10), nullable=True)  # 'flac' | 'mp3_320' | 'mp3_128'
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_accessed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    playlist_tracks: Mapped[list["PlaylistTrack"]] = relationship("PlaylistTrack", back_populates="track")
    liked_by: Mapped[list["LikedSong"]] = relationship("LikedSong", back_populates="track")
    play_history: Mapped[list["PlayHistory"]] = relationship("PlayHistory", back_populates="track")
    offline_tracks: Mapped[list["OfflineTrack"]] = relationship("OfflineTrack", back_populates="track")

    @property
    def current_file_path(self) -> str | None:
        """Returns the available file path (permanent > cache)."""
        return self.file_path or self.cache_path
