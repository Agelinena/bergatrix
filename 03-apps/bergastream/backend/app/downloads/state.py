"""Estado dos downloads em memória."""
from __future__ import annotations
from pydantic import BaseModel

class DownloadStatus:
    PENDING = "pending"
    DOWNLOADING = "downloading"
    READY = "ready"
    ERROR = "error"

class DownloadInfo(BaseModel):
    track_id: str
    status: str = DownloadStatus.PENDING
    provider_used: str | None = None
    error_message: str | None = None

_active: dict[str, DownloadInfo] = {}

def set_status(track_id, status, provider=None, error=None):
    _active[track_id] = DownloadInfo(track_id=track_id, status=status, provider_used=provider, error_message=error)

def get_info(track_id):
    return _active.get(track_id)

def is_active(track_id):
    info = _active.get(track_id)
    return info is not None and info.status in (DownloadStatus.PENDING, DownloadStatus.DOWNLOADING)

def remove(track_id):
    _active.pop(track_id, None)
