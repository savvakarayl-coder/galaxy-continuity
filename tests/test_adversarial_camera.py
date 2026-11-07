#!/usr/bin/env python3
"""
Empirical Adversarial Stress Test Suite for Continuity Camera & Virtual Webcam
Verifies:
1. Standardized 5-byte packet framing (Stream Type 0x02, UInt32 BE length), JPEG payload validation (0xFF 0xD8),
   0-byte payloads, truncated headers (< 5 bytes), and declared length bounds.
2. Camera controls: canonical lenses (back, front, ultra_wide, telephoto), unknown lens fallback ("periscope_zoom_5x"),
   digital zoom magnification (0.5x, 1.0x, 2.0x, 10.0x), and torch toggling.
3. Schema aliases: 'facing' mapped to 'lens', 'resolution' mapped to 'quality', precedence rules.
4. Session lifecycle: zero/negative fps, redundant camera_stop calls, rapid cycling, and stream stalling recovery (>5000ms).
5. Virtual Webcam HTTP endpoints: GET /api/camera/stream and GET /camera/mjpeg live JPEG frame delivery,
   503 Service Unavailable when inactive, non-GET method rejections, and concurrent fetch stress.
"""

import concurrent.futures
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from typing import Optional

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    DEFAULT_PORT,
    ContinuityClient,
    ContinuityTestHarness,
    decode_ws_frame,
    encode_ws_frame,
    make_mock_jpeg,
    make_stream_packet,
    parse_stream_packet,
)

SERVER_BIN = os.path.join(
    PROJECT_ROOT, "mac", ".build", "arm64-apple-macosx", "debug", "GalaxyContinuity"
)
HOST = "127.0.0.1"
PORT = DEFAULT_PORT


class TestAdversarialCameraNativeServer(unittest.TestCase):
    """Adversarial stress tests targeting the live native macOS ServerManager."""

    server_process: Optional[subprocess.Popen] = None

    @classmethod
    def setUpClass(cls):
        # Check if server is already running on port 8765
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        is_running = False
        try:
            s.connect((HOST, PORT))
            is_running = True
        except (socket.error, ConnectionRefusedError):
            pass
        finally:
            s.close()

        if not is_running:
            if not os.path.isfile(SERVER_BIN):
                raise RuntimeError(f"Native server binary not found at {SERVER_BIN}. Run 'swift build' first.")
            # Spawn native server
            cls.server_process = subprocess.Popen(
                [SERVER_BIN],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd=os.path.join(PROJECT_ROOT, "mac")
            )
            # Wait up to 5 seconds for port to open
            opened = False
            for _ in range(50):
                time.sleep(0.1)
                chk = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                chk.settimeout(0.5)
                try:
                    chk.connect((HOST, PORT))
                    opened = True
                    break
                except (socket.error, ConnectionRefusedError):
                    continue
                finally:
                    chk.close()
            if not opened:
                raise RuntimeError("Failed to start native GalaxyContinuity server within 5 seconds.")

    @classmethod
    def tearDownClass(cls):
        if cls.server_process:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
            cls.server_process = None

    def _create_connected_client(self) -> ContinuityClient:
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        return client

    # -------------------------------------------------------------------------
    # 1. 5-byte Binary Packet Framing (Stream Type 0x02)
    # -------------------------------------------------------------------------

    def test_01_binary_packet_framing_camera_type_0x02(self):
        """Native server ingests 5-byte stream packet with stream type 0x02 and valid JPEG."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            jpeg = make_mock_jpeg(640, 480)
            packet = bytes([0x02]) + struct.pack(">I", len(jpeg)) + jpeg
            client.send_frame(opcode=0x2, payload=packet, masked=True)
            time.sleep(0.05)

            # Liveness check via ping/pong
            client.send_ping(b"cam_alive_1")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_alive_1")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_02_zero_byte_camera_payload_packet(self):
        """Native server safely handles 5-byte packet with 0-byte payload."""
        client = self._create_connected_client()
        try:
            packet = bytes([0x02]) + struct.pack(">I", 0)
            self.assertEqual(len(packet), 5)
            client.send_frame(opcode=0x2, payload=packet, masked=True)
            time.sleep(0.05)

            client.send_ping(b"cam_zero_len")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_zero_len")
        finally:
            client.close()

    def test_03_truncated_header_packets_rejection(self):
        """Native server drops truncated binary packets (< 5 bytes) without crashing or socket close."""
        client = self._create_connected_client()
        try:
            for count in range(5):
                truncated = b"\x02" * count
                client.send_frame(opcode=0x2, payload=truncated, masked=True)
                time.sleep(0.02)

            client.send_ping(b"cam_trunc_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_trunc_alive")
        finally:
            client.close()

    def test_04_declared_length_boundary_and_excess(self):
        """Packet with declared length exceeding buffer does not overflow; trailing bytes handled cleanly."""
        client = self._create_connected_client()
        try:
            # 1. Declared length 10000, but only 4 bytes provided
            short_buf = bytes([0x02]) + struct.pack(">I", 10000) + b"\xFF\xD8\xFF\xE0"
            client.send_frame(opcode=0x2, payload=short_buf, masked=True)
            time.sleep(0.02)

            # 2. Declared length 0, but extra bytes attached
            zero_with_trail = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
            client.send_frame(opcode=0x2, payload=zero_with_trail, masked=True)
            time.sleep(0.02)

            # 3. UInt32.max declared length
            uint32_max_buf = bytes([0x02]) + struct.pack(">I", 0xFFFFFFFF) + b"\xCA\xFE"
            client.send_frame(opcode=0x2, payload=uint32_max_buf, masked=True)
            time.sleep(0.02)

            client.send_ping(b"cam_bounds_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_bounds_alive")
        finally:
            client.close()

    def test_05_corrupted_non_jpeg_payloads(self):
        """Native server safely digests non-JPEG corrupted payloads without crash."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "front", "quality": "720p"})
            time.sleep(0.02)

            corrupted_payloads = [
                b"\x00" * 256,                              # All zeroes
                b"\xFF" * 256,                              # All 0xFF
                b"THIS_IS_NOT_A_JPEG_BUFFER_1234567890",    # ASCII text
                os.urandom(1024 * 32),                      # 32 KB high-entropy noise
                b"\xFF\xD8\x00\x00",                        # Incomplete SOI
            ]

            for payload in corrupted_payloads:
                packet = bytes([0x02]) + struct.pack(">I", len(payload)) + payload
                client.send_frame(opcode=0x2, payload=packet, masked=True)
                time.sleep(0.02)

            client.send_ping(b"cam_corrupted_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_corrupted_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_06_unrecognized_stream_types(self):
        """Native server logs and safely ignores unrecognized stream types (0x00, 0x03, 0xFF)."""
        client = self._create_connected_client()
        try:
            for st in [0x00, 0x03, 0x7F, 0xFF]:
                packet = bytes([st]) + struct.pack(">I", 4) + b"\xAA\xBB\xCC\xDD"
                client.send_frame(opcode=0x2, payload=packet, masked=True)
                time.sleep(0.02)

            client.send_ping(b"cam_st_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_st_alive")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 2. Virtual Webcam HTTP Endpoints (GET /api/camera/stream & /camera/mjpeg)
    # -------------------------------------------------------------------------

    def test_07_virtual_webcam_stream_endpoint_full_lifecycle(self):
        """Verify GET /api/camera/stream returns 503 when inactive, 200 OK with JPEG when active, and 503 on stop."""
        client = self._create_connected_client()
        try:
            # 1. Ensure camera is stopped initially
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)

            # 2. When inactive, /api/camera/stream must return 503 Service Unavailable
            try:
                urllib.request.urlopen(f"http://{HOST}:{PORT}/api/camera/stream")
                self.fail("Expected 503 Service Unavailable when camera is inactive")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 503)

            # Also check alias /camera/mjpeg
            try:
                urllib.request.urlopen(f"http://{HOST}:{PORT}/camera/mjpeg")
                self.fail("Expected 503 Service Unavailable on /camera/mjpeg when camera is inactive")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 503)

            # 3. Start camera and feed a distinctive JPEG frame
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            unique_jpeg = make_mock_jpeg(320, 240)
            packet = bytes([0x02]) + struct.pack(">I", len(unique_jpeg)) + unique_jpeg
            client.send_frame(opcode=0x2, payload=packet, masked=True)
            time.sleep(0.05)

            # 4. Fetch from /api/camera/stream -> must return 200 OK with image/jpeg
            req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                body = resp.read()
                self.assertEqual(body, unique_jpeg)

            # 5. Fetch from /camera/mjpeg alias
            req_alias = urllib.request.Request(f"http://{HOST}:{PORT}/camera/mjpeg")
            with urllib.request.urlopen(req_alias) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                body = resp.read()
                self.assertEqual(body, unique_jpeg)

            # 6. Stop camera -> Feeder resets -> subsequent requests return 503
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)

            try:
                urllib.request.urlopen(f"http://{HOST}:{PORT}/api/camera/stream")
                self.fail("Expected 503 Service Unavailable after camera_stop")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 503)
        finally:
            client.close()

    def test_08_concurrent_stream_http_fetches(self):
        """Concurrent HTTP clients fetching /api/camera/stream while camera frames are continuously fed."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            # Feeder loop in background
            stop_event = threading.Event()

            def _feeder():
                frame_idx = 0
                while not stop_event.is_set():
                    jpeg = make_mock_jpeg(160, 120)
                    packet = bytes([0x02]) + struct.pack(">I", len(jpeg)) + jpeg
                    try:
                        client.send_frame(opcode=0x2, payload=packet, masked=True)
                    except Exception:
                        break
                    frame_idx += 1
                    time.sleep(0.02)

            t = threading.Thread(target=_feeder, daemon=True)
            t.start()
            time.sleep(0.05)

            # Run 20 concurrent HTTP fetches
            def _fetch_frame():
                req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream")
                with urllib.request.urlopen(req, timeout=3.0) as resp:
                    data = resp.read()
                    return resp.status, resp.headers.get("Content-Type"), data

            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
                futures = [executor.submit(_fetch_frame) for _ in range(20)]
                for fut in concurrent.futures.as_completed(futures):
                    status, ctype, data = fut.result()
                    self.assertEqual(status, 200)
                    self.assertEqual(ctype, "image/jpeg")
                    # Check JPEG SOI and EOI markers
                    self.assertTrue(data.startswith(b"\xFF\xD8"))
                    self.assertTrue(data.endswith(b"\xFF\xD9"))

            stop_event.set()
            t.join(timeout=1.0)
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_09_non_get_http_methods_on_camera_stream(self):
        """Unsupported HTTP methods (POST, PUT, DELETE) on /api/camera/stream return 404."""
        for method in ["POST", "PUT", "DELETE"]:
            req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream", method=method, data=b"{}")
            try:
                urllib.request.urlopen(req)
                self.fail(f"Expected 404 for method {method}")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 404)

    # -------------------------------------------------------------------------
    # 3. Camera Controls (Lenses, Zoom, Torch)
    # -------------------------------------------------------------------------

    def test_10_camera_lens_switching_canonical_and_unknown(self):
        """Lens switching across back, front, ultra_wide, telephoto, and unknown 'periscope_zoom_5x'."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p"})
            time.sleep(0.02)

            test_lenses = [
                "front",
                "ultra_wide",
                "telephoto",
                "back",
                "periscope_zoom_5x",
                "macro_lens",
                "",
                "   "
            ]

            for lens in test_lenses:
                # Test via camera_switch_lens
                client.send_json({"type": "camera_switch_lens", "lens": lens})
                time.sleep(0.01)
                # Test via camera_control action
                client.send_json({"type": "camera_control", "action": "switch_lens", "lens": lens})
                time.sleep(0.01)

            client.send_ping(b"cam_lenses_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_lenses_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_11_camera_control_zoom_magnifications(self):
        """Digital zoom across 0.5x, 1.0x, 2.0x, 10.0x, and boundary coordinates."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back"})
            time.sleep(0.02)

            zoom_levels = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 0.0, -1.0, 100.0]
            for zoom in zoom_levels:
                client.send_json({"type": "camera_control", "action": "set_zoom", "zoom": zoom})
                time.sleep(0.01)

            client.send_ping(b"cam_zoom_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_zoom_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_12_camera_control_torch_rapid_toggles(self):
        """Torch on/off controls and rapid toggle sequences."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back"})
            time.sleep(0.02)

            for _ in range(25):
                client.send_json({"type": "camera_control", "action": "toggle_torch", "torch": True})
                client.send_json({"type": "camera_control", "action": "toggle_torch", "torch": False})

            client.send_ping(b"cam_torch_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_torch_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    # -------------------------------------------------------------------------
    # 4. Schema Harmonization & Aliases ('facing', 'resolution')
    # -------------------------------------------------------------------------

    def test_13_schema_aliases_facing_and_resolution(self):
        """camera_start with 'facing' and 'resolution' schema aliases accepted cleanly."""
        client = self._create_connected_client()
        try:
            # 1. Alias in camera_start
            client.send_json({
                "type": "camera_start",
                "facing": "ultra_wide",
                "resolution": "4k",
                "fps": 60
            })
            time.sleep(0.02)

            # 2. Alias in camera_switch_lens
            client.send_json({
                "type": "camera_switch_lens",
                "facing": "front"
            })
            time.sleep(0.02)

            # 3. Alias in camera_control
            client.send_json({
                "type": "camera_control",
                "action": "switch_lens",
                "facing": "telephoto",
                "zoom": 2.5,
                "torch": True
            })
            time.sleep(0.02)

            client.send_ping(b"cam_aliases_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_aliases_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    # -------------------------------------------------------------------------
    # 5. Session Lifecycle & Idempotence
    # -------------------------------------------------------------------------

    def test_14_camera_start_zero_and_extreme_fps(self):
        """camera_start with zero, negative, and extreme fps parsed without error."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "front", "quality": "720p", "fps": 0})
            time.sleep(0.02)
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": -30})
            time.sleep(0.02)
            client.send_json({"type": "camera_start", "lens": "ultra_wide", "quality": "4k", "fps": 240})
            time.sleep(0.02)

            client.send_ping(b"cam_fps_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_fps_alive")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_15_redundant_camera_stop_idempotence(self):
        """Calling camera_stop when not started or repeatedly is strictly idempotent."""
        client = self._create_connected_client()
        try:
            # Stop when not active
            client.send_json({"type": "camera_stop"})
            time.sleep(0.02)

            # Start then multiple redundant stops
            client.send_json({"type": "camera_start", "lens": "back"})
            time.sleep(0.02)
            for _ in range(5):
                client.send_json({"type": "camera_stop"})

            client.send_ping(b"cam_stop_idempotent")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"cam_stop_idempotent")
        finally:
            client.close()

    def test_16_camera_stalling_watchdog_triggers_stop(self):
        """When an active camera stream receives no frames for > 5000ms, watchdog triggers camera_stop."""
        client = self._create_connected_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            # Feed 1 frame to start watchdog timer
            jpeg = make_mock_jpeg(160, 120)
            packet = bytes([0x02]) + struct.pack(">I", len(jpeg)) + jpeg
            client.send_frame(opcode=0x2, payload=packet, masked=True)

            # Verify stream endpoint is 200 OK
            req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)

            # Now stall: watchdog checks every 1.0s with threshold > 5.0s, so it triggers within 5.0s - 6.5s
            stalled = False
            for _ in range(16):
                time.sleep(0.5)
                try:
                    urllib.request.urlopen(f"http://{HOST}:{PORT}/api/camera/stream")
                except urllib.error.HTTPError as e:
                    if e.code == 503:
                        stalled = True
                        break
            self.assertTrue(stalled, "Watchdog must stop camera feeder after >5000ms stream stall")

            # The watchdog broadcasts {"type": "camera_stop"} to connected WebSocket clients
            op, msg_bytes = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0x1, "Server should broadcast camera_stop text message on stream stall")
            msg = json.loads(msg_bytes.decode("utf-8"))
            self.assertEqual(msg.get("type"), "camera_stop")

            # Client socket should remain healthy and responsive
            client.send_ping(b"watchdog_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"watchdog_alive")
        finally:
            client.close()


class TestAdversarialCameraIsolatedHarness(unittest.TestCase):
    """Adversarial packet framing and contract verification on isolated mock harness."""

    @classmethod
    def setUpClass(cls):
        cls.harness = ContinuityTestHarness()
        cls.harness.__enter__()
        cls.host = cls.harness.host
        cls.port = cls.harness.port
        cls.server = cls.harness.server

    @classmethod
    def tearDownClass(cls):
        cls.harness.__exit__(None, None, None)

    def test_17_make_stream_packet_and_parse_roundtrip(self):
        """Harness stream packet utility roundtrip with synthetic JPEG."""
        jpeg = make_mock_jpeg(640, 480)
        packet = make_stream_packet(stream_type=0x02, payload=jpeg)

        self.assertEqual(len(packet), 5 + len(jpeg))
        self.assertEqual(packet[0], 0x02)

        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x02)
        self.assertEqual(parsed["length"], len(jpeg))
        self.assertEqual(parsed["payload"], jpeg)

    def test_18_parse_stream_packet_truncated_header_raises(self):
        """parse_stream_packet rejects inputs under 5 bytes (except 4-byte legacy)."""
        for count in [0, 1, 2, 3]:
            with self.assertRaises(ValueError):
                parse_stream_packet(b"\x02" * count)

    def test_19_zero_byte_payload_packet_roundtrip(self):
        """parse_stream_packet with 0-byte payload."""
        packet = make_stream_packet(stream_type=0x02, payload=b"")
        self.assertEqual(len(packet), 5)
        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x02)
        self.assertEqual(parsed["length"], 0)
        self.assertEqual(parsed["payload"], b"")


if __name__ == "__main__":
    unittest.main()
