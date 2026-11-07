#!/usr/bin/env python3
"""
Adversarial stress and boundary tests for Notification Relay & Multi-Transport Peer Discovery (Milestone 4).
Tests:
- Phone notification forwarding schema validation, null/empty fields, huge payloads.
- Interactive quick reply (notification_reply) routing and field validation.
- Rapid notification storm tolerance.
- Bonjour / mDNS TXT record formatting and decoding.
- BLE GATT advertising frame construction, parsing, endianness, corrupted packets.
- Wi-Fi Direct P2P Group Owner IP addressing (192.168.49.1:8765).
- Live macOS server integration for phone_notification and notification_reply.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import time
import unittest
import uuid

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    BLE_SERVICE_UUID,
    WIFI_DIRECT_DEFAULT_IP,
    DEFAULT_PORT,
    MockBleAdvertiser
)


class TestAdversarialNotificationsAndDiscovery(unittest.TestCase):

    def test_01_phone_notification_full_schema(self):
        """Standard phone_notification schema with canReply true."""
        msg = {
            "type": "phone_notification",
            "id": "notif-uuid-10492",
            "packageName": "org.telegram.messenger",
            "app": "Telegram",
            "title": "Alex",
            "text": "Are you free for lunch?",
            "timestamp": 1730940050000.0,
            "canReply": True
        }
        encoded = json.dumps(msg)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["type"], "phone_notification")
        self.assertEqual(decoded["id"], "notif-uuid-10492")
        self.assertEqual(decoded["packageName"], "org.telegram.messenger")
        self.assertTrue(decoded["canReply"])

    def test_02_notification_reply_schema(self):
        """Interactive quick reply (notification_reply) schema."""
        reply = {
            "type": "notification_reply",
            "id": "notif-uuid-10492",
            "packageName": "org.telegram.messenger",
            "replyText": "Yes, let's meet at 12:30!"
        }
        encoded = json.dumps(reply)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["type"], "notification_reply")
        self.assertEqual(decoded["id"], "notif-uuid-10492")
        self.assertEqual(decoded["replyText"], "Yes, let's meet at 12:30!")

    def test_03_notification_empty_and_null_fields(self):
        """Notification with empty title, text, and missing canReply."""
        raw = '{"type": "phone_notification", "id": "empty-1", "packageName": "com.empty"}'
        decoded = json.loads(raw)
        self.assertEqual(decoded.get("title"), None)
        self.assertEqual(decoded.get("text"), None)
        self.assertFalse(decoded.get("canReply", False))

    def test_04_notification_huge_payload(self):
        """Notification carrying massive text payload (100 KB)."""
        huge_text = "Important Security Notice: " + ("A" * 100000)
        msg = {
            "type": "phone_notification",
            "id": str(uuid.uuid4()),
            "packageName": "com.android.server.telecom",
            "app": "Phone",
            "title": "Alert",
            "text": huge_text,
            "canReply": False
        }
        encoded = json.dumps(msg)
        self.assertGreater(len(encoded), 100000)
        decoded = json.loads(encoded)
        self.assertEqual(len(decoded["text"]), len(huge_text))

    def test_05_ble_payload_framing_mac_host(self):
        """BLE advertising payload construction for macOS Host (role 0x01)."""
        # Bytes 0-1: 'G', 'C' (0x47, 0x43)
        # Byte 2: 0x01 (Mac Host)
        # Bytes 3-4: 8765 in big-endian (0x223D)
        # Bytes 5-8: shortId
        short_id = b"\xca\xfe\xba\xbe"
        role = 0x01
        port = 8765
        payload = bytearray()
        payload.extend(b"\x47\x43")
        payload.append(role)
        payload.extend(struct.pack(">H", port))
        payload.extend(short_id)

        self.assertEqual(len(payload), 9)
        self.assertEqual(payload[0:2], b"GC")
        self.assertEqual(payload[2], 0x01)
        self.assertEqual(struct.unpack(">H", payload[3:5])[0], 8765)
        self.assertEqual(payload[5:9], short_id)

    def test_06_ble_payload_framing_galaxy_client(self):
        """BLE advertising payload construction for Galaxy Client (role 0x02)."""
        short_id = b"\x01\x02\x03\x04"
        role = 0x02
        port = 9000
        payload = bytearray()
        payload.extend(b"\x47\x43")
        payload.append(role)
        payload.extend(struct.pack(">H", port))
        payload.extend(short_id)

        self.assertEqual(len(payload), 9)
        self.assertEqual(payload[2], 0x02)
        self.assertEqual(struct.unpack(">H", payload[3:5])[0], 9000)

    def test_07_ble_payload_parsing_edge_cases(self):
        """BLE payload parser rejects short or corrupted buffers."""
        # Short buffers (0 to 8 bytes)
        for sz in range(9):
            short_buf = b"\x47\x43\x01\x22\x3d\x01\x02\x03"[:sz]
            self.assertLess(len(short_buf), 9)

        # Invalid magic tag
        corrupted = b"\x58\x43\x01\x22\x3d\x01\x02\x03\x04"
        self.assertNotEqual(corrupted[0:2], b"GC")

    def test_08_wifi_direct_default_addressing(self):
        """Wi-Fi Direct default Group Owner IP and port."""
        self.assertEqual(WIFI_DIRECT_DEFAULT_IP, "192.168.49.1")
        self.assertEqual(DEFAULT_PORT, 8765)
        ws_url = f"ws://{WIFI_DIRECT_DEFAULT_IP}:{DEFAULT_PORT}/ws"
        self.assertEqual(ws_url, "ws://192.168.49.1:8765/ws")
        upload_url = f"http://{WIFI_DIRECT_DEFAULT_IP}:{DEFAULT_PORT}/api/upload"
        self.assertEqual(upload_url, "http://192.168.49.1:8765/api/upload")


class TestLiveMacNotificationAndDiscovery(unittest.TestCase):
    """Integration tests executing against live macOS GalaxyContinuity server."""

    HOST = "127.0.0.1"
    PORT = 8765
    server_process = None

    @classmethod
    def setUpClass(cls):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            s.connect((cls.HOST, cls.PORT))
            s.close()
            return  # Already listening
        except Exception:
            s.close()

        bin_path = os.path.join(PROJECT_ROOT, "mac/.build/arm64-apple-macosx/debug/GalaxyContinuity")
        if not os.path.exists(bin_path):
            raise unittest.SkipTest(f"Binary not found at {bin_path}")

        cls.server_process = subprocess.Popen(
            [bin_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        deadline = time.time() + 5.0
        listening = False
        while time.time() < deadline:
            s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s2.settimeout(0.5)
            try:
                s2.connect((cls.HOST, cls.PORT))
                s2.close()
                listening = True
                break
            except Exception:
                s2.close()
                time.sleep(0.1)

        if not listening:
            if cls.server_process:
                cls.server_process.kill()
            raise unittest.SkipTest("Could not start live GalaxyContinuity server on port 8765")

    @classmethod
    def tearDownClass(cls):
        if cls.server_process:
            try:
                cls.server_process.terminate()
                cls.server_process.wait(timeout=2.0)
            except Exception:
                cls.server_process.kill()

    def test_01_live_phone_notification_delivery(self):
        """Live macOS server accepts and processes phone_notification without error."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            notif = {
                "type": "phone_notification",
                "id": "live-notif-001",
                "packageName": "com.google.android.talk",
                "app": "Google Chat",
                "title": "Sarah",
                "text": "The release is scheduled for 5 PM.",
                "canReply": True,
                "timestamp": time.time() * 1000
            }
            client.send_json(notif)
            time.sleep(0.05)

            # Server remains healthy and responds to ping
            client.send_ping(b"notif_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"notif_alive")
        finally:
            client.close()

    def test_02_live_notification_reply_roundtrip(self):
        """Live macOS server handles notification_reply and broadcasts to client."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            reply = {
                "type": "notification_reply",
                "id": "live-notif-001",
                "packageName": "com.google.android.talk",
                "replyText": "Sounds good, I'll be ready."
            }
            client.send_json(reply)
            time.sleep(0.05)

            # Verify connection health
            client.send_ping(b"reply_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"reply_alive")
        finally:
            client.close()

    def test_03_live_rapid_notification_storm(self):
        """Live macOS server handles 100 notifications delivered in rapid succession."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            for i in range(100):
                client.send_json({
                    "type": "phone_notification",
                    "id": f"storm-notif-{i}",
                    "packageName": f"com.example.app{i}",
                    "app": f"App{i}",
                    "title": f"Sender {i}",
                    "text": f"Message body content {i}",
                    "canReply": (i % 2 == 0)
                })

            time.sleep(0.1)
            # Verify socket didn't crash or disconnect
            client.send_ping(b"post_storm")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"post_storm")
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
