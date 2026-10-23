import json
import time
import unittest
from unittest.mock import patch

from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import server

ORIGIN = {"origin": "http://testserver"}
ROOM = "a" * 64


def join(ws, role, room=ROOM, version=server.PROTOCOL_VERSION):
    ws.send_text(json.dumps({"type": "join", "v": version, "room": room, "role": role}))


def close_code(ws):
    """Código com que o servidor fechou a conexão (pula o que veio antes)."""
    while True:
        message = ws.receive()
        if message["type"] == "websocket.close":
            return message["code"]


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(server.app)

    def test_index_has_strict_headers(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        csp = response.headers["content-security-policy"]
        self.assertIn("default-src 'none'", csp)
        self.assertIn("script-src 'self'", csp)
        self.assertIn("require-trusted-types-for 'script'", csp)
        self.assertNotIn("http", csp)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.headers["cross-origin-opener-policy"], "same-origin")
        self.assertEqual(response.headers["x-frame-options"], "DENY")

    def test_assets_have_types_nosniff_accepts(self):
        for path, kind in (("/assets/js/app.js", "text/javascript"),
                           ("/assets/vendor/qrcode.mjs", "text/javascript"),
                           ("/assets/fonts/manrope-latin-wght-normal.woff2", "font/woff2"),
                           ("/assets/css/app.css", "text/css")):
            response = self.client.get(path)
            self.assertEqual(response.status_code, 200, path)
            self.assertTrue(response.headers["content-type"].startswith(kind), path)
            self.assertEqual(response.headers["cache-control"], "no-cache")

    def test_common_paths_do_not_404(self):
        for path in ("/favicon.ico", "/robots.txt", "/healthz"):
            self.assertEqual(self.client.get(path).status_code, 200, path)

    def test_page_loads_nothing_from_other_origins(self):
        html = self.client.get("/").text
        self.assertNotIn("https://", html)
        self.assertNotIn("http://", html.replace("http://www.w3.org", ""))


class RelayTests(unittest.TestCase):
    def setUp(self):
        server.rooms.rooms.clear()
        self.client = TestClient(server.app)

    def connect(self, role, room=ROOM, headers=ORIGIN):
        ws = self.client.websocket_connect("/ws", headers=headers)
        session = ws.__enter__()
        self.addCleanup(ws.__exit__, None, None, None)
        join(session, role, room)
        return session

    def test_rejects_other_origin(self):
        with self.assertRaises(WebSocketDisconnect) as closed:
            with self.client.websocket_connect("/ws", headers={"origin": "https://evil.example"}):
                pass
        self.assertEqual(closed.exception.code, server.CLOSE_FORBIDDEN)

    def test_relays_bytes_both_ways(self):
        receiver = self.connect("receiver")
        ready = receiver.receive_json()
        self.assertEqual((ready["type"], ready["role"], ready["peer"]), ("ready", "receiver", False))
        self.assertGreater(ready["expiresIn"], server.ROOM_TTL_SECONDS - 5)
        sender = self.connect("sender")
        ready = sender.receive_json()
        self.assertEqual((ready["type"], ready["peer"]), ("ready", True))
        self.assertEqual(receiver.receive_json(), {"type": "peer", "present": True})

        payload = bytes(range(256)) * 4
        sender.send_bytes(payload)
        self.assertEqual(receiver.receive_bytes(), payload)
        receiver.send_bytes(b"ack")
        self.assertEqual(sender.receive_bytes(), b"ack")

    def test_sender_needs_existing_room(self):
        sender = self.connect("sender")
        self.assertEqual(close_code(sender), server.CLOSE_NOT_FOUND)
        self.assertEqual(server.rooms.rooms, {})

    def test_second_receiver_is_busy(self):
        self.connect("receiver").receive_json()
        other = self.connect("receiver")
        self.assertEqual(close_code(other), server.CLOSE_BUSY)

    def test_receiver_can_come_back(self):
        with self.client.websocket_connect("/ws", headers=ORIGIN) as first:
            join(first, "receiver")
            first.receive_json()
        again = self.connect("receiver")
        self.assertEqual(again.receive_json()["type"], "ready")

    def test_invalid_join_is_closed(self):
        for message in ("{}", "ping", json.dumps({"type": "join", "v": 1, "room": ROOM, "role": "receiver"}),
                        json.dumps({"type": "join", "v": 2, "room": "A" * 64, "role": "receiver"}),
                        json.dumps({"type": "join", "v": 2, "room": ROOM, "role": "admin"})):
            with self.client.websocket_connect("/ws", headers=ORIGIN) as ws:
                ws.send_text(message)
                self.assertEqual(close_code(ws), server.CLOSE_BAD_REQUEST, message)
        self.assertEqual(server.rooms.rooms, {})

    def test_only_ping_text_after_join(self):
        receiver = self.connect("receiver")
        receiver.receive_json()
        receiver.send_text("ping")
        receiver.send_text("hello")
        self.assertEqual(close_code(receiver), server.CLOSE_BAD_REQUEST)

    def test_frame_without_peer_reports_error(self):
        receiver = self.connect("receiver")
        receiver.receive_json()
        receiver.send_bytes(b"x")
        self.assertEqual(receiver.receive_json(), {"type": "error", "code": "peer-missing"})

    def test_oversized_frame_closes(self):
        receiver = self.connect("receiver")
        receiver.receive_json()
        receiver.send_bytes(b"x" * (server.MAX_FRAME_BYTES + 1))
        self.assertEqual(close_code(receiver), server.CLOSE_LIMIT)

    def test_room_byte_budget(self):
        receiver = self.connect("receiver")
        receiver.receive_json()
        with patch.object(server, "MAX_ROOM_BYTES", 10):
            receiver.send_bytes(b"x" * 8)
            receiver.receive_json()
            receiver.send_bytes(b"x" * 8)
            self.assertEqual(close_code(receiver), server.CLOSE_LIMIT)

    def test_limits_rooms_per_client(self):
        with patch.object(server, "MAX_ROOMS_PER_CLIENT", 1):
            self.connect("receiver", "b" * 64).receive_json()
            other = self.connect("receiver", "c" * 64)
            self.assertEqual(close_code(other), server.CLOSE_LIMIT)

    def test_server_full(self):
        with patch.object(server, "MAX_ROOMS", 0):
            other = self.connect("receiver")
            self.assertEqual(close_code(other), server.CLOSE_FULL)

    def test_expired_room_is_closed(self):
        receiver = self.connect("receiver")
        receiver.receive_json()
        server.rooms.rooms[ROOM].created_at = time.monotonic() - server.ROOM_TTL_SECONDS - 1
        receiver.send_text("ping")
        self.assertEqual(close_code(receiver), server.CLOSE_EXPIRED)


if __name__ == "__main__":
    unittest.main()
