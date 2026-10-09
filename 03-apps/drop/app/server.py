import asyncio
import base64
import binascii
import re
import time
from collections import deque
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Deque, Dict, Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

SESSION_TTL_SECONDS = 600
MAX_ACTIVE_SESSIONS = 2048
MAX_MESSAGES_PER_MINUTE = 20
MAX_MESSAGE_BYTES = 16 * 1024
SESSION_ID_PATTERN = re.compile(r"^[a-f0-9]{64}$")


class SendPayload(BaseModel):
    encrypted_payload: str = Field(min_length=40, max_length=22000)

@dataclass
class Session:
    created_at: float
    websocket: Optional[WebSocket] = None
    sent_at: Deque[float] = field(default_factory=deque)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class ConnectionManager:
    def __init__(self):
        self.sessions: Dict[str, Session] = {}

    def cleanup(self):
        now = time.monotonic()
        expired = [
            session_id for session_id, session in self.sessions.items()
            if now - session.created_at >= SESSION_TTL_SECONDS
        ]
        for session_id in expired:
            session = self.sessions.pop(session_id)
            if session.websocket is not None:
                asyncio.create_task(
                    session.websocket.close(code=1001, reason="Session expired")
                )

    async def connect(self, session_id: str, websocket: WebSocket) -> bool:
        if not SESSION_ID_PATTERN.fullmatch(session_id):
            await websocket.close(code=1008, reason="Invalid session")
            return False

        await websocket.accept()
        self.cleanup()
        session = self.sessions.get(session_id)
        if session is None:
            if len(self.sessions) >= MAX_ACTIVE_SESSIONS:
                await websocket.close(code=1013, reason="Server busy")
                return False
            session = Session(created_at=time.monotonic())
            self.sessions[session_id] = session
        elif session.websocket is not None:
            await websocket.close(code=1008, reason="Session busy")
            return False

        session.websocket = websocket
        return True

    def disconnect(self, session_id: str, websocket: WebSocket):
        session = self.sessions.get(session_id)
        if session is not None and session.websocket is websocket:
            session.websocket = None

    async def send_to_session(self, session_id: str, message: str) -> bool:
        self.cleanup()
        session = self.sessions.get(session_id)
        if session is None or session.websocket is None:
            return False

        now = time.monotonic()
        while session.sent_at and now - session.sent_at[0] >= 60:
            session.sent_at.popleft()
        if len(session.sent_at) >= MAX_MESSAGES_PER_MINUTE:
            raise HTTPException(status_code=429, detail="Too many messages")
        session.sent_at.append(now)

        try:
            async with session.send_lock:
                if session.websocket is None:
                    return False
                await session.websocket.send_text(message)
            return True
        except Exception:
            session.websocket = None
            return False

manager = ConnectionManager()


async def expire_sessions():
    while True:
        await asyncio.sleep(15)
        manager.cleanup()


@asynccontextmanager
async def lifespan(app: FastAPI):
    cleanup_task = asyncio.create_task(expire_sessions())
    try:
        yield
    finally:
        cleanup_task.cancel()
        try:
            await cleanup_task
        except asyncio.CancelledError:
            pass


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
APP_DIRECTORY = Path(__file__).resolve().parent
html_content = (APP_DIRECTORY / "index.html").read_text(encoding="utf-8")


@app.middleware("http")
async def add_security_headers(request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Strict-Transport-Security"] = "max-age=31536000"
    response.headers["Permissions-Policy"] = "camera=(self), clipboard-write=(self)"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; "
        "script-src 'self' https://cdnjs.cloudflare.com "
        "https://unpkg.com; "
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; "
        "img-src 'self' data: blob:; connect-src 'self' wss:; "
        "media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; "
        "form-action 'self'; object-src 'none'"
    )
    return response

@app.get("/")
async def get():
    return HTMLResponse(html_content)


@app.get("/app.js")
async def get_app_script():
    return FileResponse(APP_DIRECTORY / "app.js", media_type="application/javascript")


@app.get("/app.css")
async def get_app_styles():
    return FileResponse(APP_DIRECTORY / "app.css", media_type="text/css")


@app.get("/healthz")
async def healthcheck():
    return {"status": "ok"}


@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    success = await manager.connect(session_id, websocket)
    if not success:
        return

    try:
        while True:
            if await websocket.receive_text() != "ping":
                await websocket.close(code=1008, reason="Invalid message")
                break
    except WebSocketDisconnect:
        pass
    finally:
        manager.disconnect(session_id, websocket)

@app.post("/api/send/{session_id}")
async def send_message(session_id: str, data: SendPayload):
    if not SESSION_ID_PATTERN.fullmatch(session_id):
        raise HTTPException(status_code=404, detail="Receiver not connected")
    try:
        encrypted = base64.b64decode(data.encrypted_payload, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=422, detail="Invalid encrypted payload")
    if not 28 <= len(encrypted) <= MAX_MESSAGE_BYTES + 28:
        raise HTTPException(status_code=413, detail="Message size is not allowed")

    success = await manager.send_to_session(session_id, data.encrypted_payload)
    if success:
        return {"status": "sent"}
    raise HTTPException(status_code=409, detail="Receiver not connected")
