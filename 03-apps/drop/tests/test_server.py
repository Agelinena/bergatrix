import asyncio
import base64
import time
import unittest
from unittest.mock import patch

from fastapi import HTTPException, WebSocketDisconnect

import server


class FakeWebSocket:
    def __init__(self, incoming=None):
        self.accepted = False
        self.closed = None
        self.messages = []
        self.incoming = iter(incoming or [])

    async def accept(self):
        self.accepted = True

    async def close(self, code=None, reason=None):
        self.closed = (code, reason)

    async def send_text(self, message):
        self.messages.append(message)

    async def receive_text(self):
        try:
            return next(self.incoming)
        except StopIteration:
            raise WebSocketDisconnect(code=1000)


class ConnectionManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_session_expires_after_absolute_ttl(self):
        manager = server.ConnectionManager()
        websocket = FakeWebSocket()
        session_id = "a" * 64
        self.assertTrue(await manager.connect(session_id, websocket))
        manager.sessions[session_id].created_at = time.monotonic() - server.SESSION_TTL_SECONDS - 1

        self.assertFalse(await manager.send_to_session(session_id, "payload"))
        await asyncio.sleep(0)

        self.assertNotIn(session_id, manager.sessions)
        self.assertEqual(websocket.closed[0], 1001)

    async def test_session_capacity_rejects_new_connections(self):
        manager = server.ConnectionManager()
        websocket = FakeWebSocket()
        with patch.object(server, "MAX_ACTIVE_SESSIONS", 0):
            self.assertFalse(await manager.connect("b" * 64, websocket))

        self.assertEqual(websocket.closed[0], 1013)
        self.assertEqual(manager.sessions, {})

    async def test_send_rate_limit_is_per_session(self):
        manager = server.ConnectionManager()
        websocket = FakeWebSocket()
        session_id = "c" * 64
        await manager.connect(session_id, websocket)

        for _ in range(server.MAX_MESSAGES_PER_MINUTE):
            self.assertTrue(await manager.send_to_session(session_id, "payload"))
        with self.assertRaises(HTTPException) as error:
            await manager.send_to_session(session_id, "payload")

        self.assertEqual(error.exception.status_code, 429)
        self.assertEqual(len(websocket.messages), server.MAX_MESSAGES_PER_MINUTE)


class SendEndpointTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        server.manager.sessions.clear()

    async def test_invalid_base64_is_rejected(self):
        payload = server.SendPayload(encrypted_payload="!" * 40)
        with self.assertRaises(HTTPException) as error:
            await server.send_message("d" * 64, payload)

        self.assertEqual(error.exception.status_code, 422)

    async def test_oversized_payload_is_rejected(self):
        encrypted = b"x" * (server.MAX_MESSAGE_BYTES + 29)
        payload = server.SendPayload(
            encrypted_payload=base64.b64encode(encrypted).decode("ascii")
        )
        with self.assertRaises(HTTPException) as error:
            await server.send_message("e" * 64, payload)

        self.assertEqual(error.exception.status_code, 413)

    async def test_missing_receiver_returns_conflict(self):
        encrypted = base64.b64encode(b"x" * 28).decode("ascii")
        payload = server.SendPayload(encrypted_payload=encrypted)
        with self.assertRaises(HTTPException) as error:
            await server.send_message("f" * 64, payload)

        self.assertEqual(error.exception.status_code, 409)


class WebSocketEndpointTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        server.manager.sessions.clear()

    async def test_keepalive_ping_is_accepted(self):
        websocket = FakeWebSocket(["ping"])

        await server.websocket_endpoint(websocket, "1" * 64)

        self.assertTrue(websocket.accepted)
        self.assertIsNone(websocket.closed)
        self.assertIsNone(server.manager.sessions["1" * 64].websocket)

    async def test_non_ping_frame_is_closed(self):
        websocket = FakeWebSocket(["unexpected"])

        await server.websocket_endpoint(websocket, "2" * 64)

        self.assertEqual(websocket.closed[0], 1008)
        self.assertIsNone(server.manager.sessions["2" * 64].websocket)


if __name__ == "__main__":
    unittest.main()