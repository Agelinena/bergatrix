from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse
import asyncio
from typing import Dict, Optional
import time

app = FastAPI()

# Configurações
SESSION_TIMEOUT = 600  # 10 minutos em segundos

class ConnectionManager:
    def __init__(self):
        # {session_id: {"websocket": WebSocket | None, "created_at": float, "last_activity": float}}
        self.sessions: Dict[str, dict] = {}

    def _cleanup(self):
        """Remove sessões expiradas"""
        now = time.time()
        expired = [
            sid for sid, data in self.sessions.items() 
            if now - data["last_activity"] > SESSION_TIMEOUT
        ]
        for sid in expired:
            del self.sessions[sid]

    async def connect(self, session_id: str, websocket: WebSocket):
        self._cleanup()
        
        # Se a sessão não existe, cria
        if session_id not in self.sessions:
            self.sessions[session_id] = {
                "websocket": None,
                "created_at": time.time(),
                "last_activity": time.time()
            }
        
        # Verifica se já tem alguém conectado (Single Listener)
        # Permite reconexão se for o mesmo socket (improvável) ou se o anterior caiu
        current_ws = self.sessions[session_id]["websocket"]
        if current_ws is not None:
            # Tenta verificar se a conexão antiga ainda está viva? 
            # Por simplificação, se já tem um WS atrelado, rejeita o novo.
            # O cliente antigo deve desconectar explicitamente ou cair por timeout/erro.
            # Mas se o usuário der F5, o WS antigo morre. O `disconnect` deve lidar com isso.
            # Se chegamos aqui e current_ws não é None, é porque o disconnect não foi chamado ainda ou é um intruso.
            # Vamos assumir que se o WS está lá, está ocupado.
            # Mas para suportar F5 rápido, o disconnect do anterior deve rodar antes do connect do novo.
            await websocket.close(code=1008, reason="Session busy")
            return False

        await websocket.accept()
        self.sessions[session_id]["websocket"] = websocket
        self.sessions[session_id]["last_activity"] = time.time()
        return True

    def disconnect(self, session_id: str, websocket: WebSocket):
        if session_id in self.sessions:
            if self.sessions[session_id]["websocket"] == websocket:
                self.sessions[session_id]["websocket"] = None
                # Não deleta a sessão, permite reconexão dentro do timeout
                self.sessions[session_id]["last_activity"] = time.time()

    async def send_to_session(self, session_id: str, message: str):
        self._cleanup()
        if session_id in self.sessions:
            ws = self.sessions[session_id]["websocket"]
            if ws:
                try:
                    await ws.send_text(message)
                    self.sessions[session_id]["last_activity"] = time.time()
                    return True
                except:
                    # Se falhar ao enviar, considera desconectado
                    self.sessions[session_id]["websocket"] = None
        return False

manager = ConnectionManager()

with open("index.html", "r", encoding="utf-8") as f:
    html_content = f.read()

@app.get("/")
async def get():
    return HTMLResponse(html_content)

@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    success = await manager.connect(session_id, websocket)
    if not success:
        return # Já fechou no connect

    try:
        while True:
            # Mantém vivo e atualiza last_activity
            await websocket.receive_text()
            if session_id in manager.sessions:
                manager.sessions[session_id]["last_activity"] = time.time()
    except WebSocketDisconnect:
        manager.disconnect(session_id, websocket)

@app.post("/api/send/{session_id}")
async def send_message(session_id: str, data: dict):
    success = await manager.send_to_session(session_id, data["encrypted_payload"])
    if success:
        return {"status": "sent"}
    # Se a sessão existe mas não tem WS conectado, retorna erro específico ou genérico?
    # O usuário pediu persistência de 10 min. Se o receptor desconectou (fechou aba), a sessão existe mas WS é None.
    # Nesse caso, não dá pra entregar.
    return {"status": "error", "detail": "Receiver not connected"}
