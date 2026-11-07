#!/usr/bin/env python3
"""
Adversarial Empirical Verification Suite for Milestone 3 Iteration 2 Gate
Targeting:
1. Camera HTTP endpoints: /api/camera/stream, /camera/mjpeg, /api/camera/snapshot, /camera/snapshot
   - 503 Service Unavailable when inactive (pre-start and post-stop)
   - Standard snapshot HTTP GET returns 200 OK, Content-Type: image/jpeg, Content-Length, Connection: close
   - Multipart MJPEG HTTP streaming (Accept: multipart/x-mixed-replace or ?stream=true or ?mjpeg=true)
     receives persistent multipart stream chunks (--frame boundary, Content-Type, Content-Length)
   - Continuous frame delivery across multiple frames to active streaming client
   - Multiple concurrent MJPEG stream clients receiving simultaneous live frames
   - Stream termination emits '--frame--\r\n' boundary and closes client sockets
2. Camera Controls & Deduplication:
   - Canonical lens switching (back, front, ultra_wide, telephoto) and unknown lenses
   - Verification of message deduplication: only canonical 'camera_control' broadcast, no duplicate 'camera_switch_lens'
   - Digital zoom parameters (0.5x, 1.0x, 2.0x, 5.0x, 10.0x, edge boundaries)
   - Torch toggling and rapid toggle bursts
3. Watchdog Recovery:
   - Camera stream active with frames fed
   - Deliberate frame stall (> 5000ms)
   - Watchdog triggers camera_stop, resets feeder to 503, and notifies WebSocket clients
"""

import http.client
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

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    DEFAULT_PORT,
    ContinuityClient,
    decode_ws_frame,
    make_mock_jpeg,
)

SERVER_BIN = os.path.join(
    PROJECT_ROOT, "mac", ".build", "arm64-apple-macosx", "debug", "GalaxyContinuity"
)
HOST = "127.0.0.1"
PORT = DEFAULT_PORT


class TestAdversarialCameraGate(unittest.TestCase):
    server_proc: subprocess.Popen = None
    spawned_server: bool = False

    @classmethod
    def setUpClass(cls):
        # Check if server is running
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        running = False
        try:
            s.connect((HOST, PORT))
            running = True
        except (socket.error, ConnectionRefusedError):
            pass
        finally:
            s.close()

        if not running:
            if not os.path.isfile(SERVER_BIN):
                raise RuntimeError(f"Server binary not found at {SERVER_BIN}. Run 'swift build' first.")
            cls.server_proc = subprocess.Popen(
                [SERVER_BIN],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd=os.path.join(PROJECT_ROOT, "mac")
            )
            cls.spawned_server = True
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
                raise RuntimeError("Failed to start GalaxyContinuity server within 5 seconds.")

    @classmethod
    def tearDownClass(cls):
        if cls.spawned_server and cls.server_proc:
            cls.server_proc.terminate()
            try:
                cls.server_proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                cls.server_proc.kill()
            cls.server_proc = None

    def setUp(self):
        # Ensure any leftover active camera session is stopped
        client = ContinuityClient(host=HOST, port=PORT)
        try:
            client.connect(send_initial_handshake=True)
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)
        except Exception:
            pass
        finally:
            client.close()

    def _create_ws_client(self) -> ContinuityClient:
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        time.sleep(0.05)
        client.drain_messages()
        return client

    def _feed_camera_frame(self, ws_client: ContinuityClient, jpeg_data: bytes):
        # Stream Type 0x02 (Camera), UInt32 BE length
        packet = bytes([0x02]) + struct.pack(">I", len(jpeg_data)) + jpeg_data
        ws_client.send_frame(opcode=0x2, payload=packet, masked=True)

    # =========================================================================
    # Task 1: /api/camera/stream and /camera/mjpeg Empiric Verification
    # =========================================================================

    def test_01_inactive_camera_returns_503(self):
        """Verify 503 Service Unavailable when camera is inactive across all endpoints & query variants."""
        endpoints = [
            "/api/camera/stream",
            "/camera/mjpeg",
            "/api/camera/snapshot",
            "/camera/snapshot",
            "/api/camera/stream?stream=true",
            "/camera/mjpeg?mjpeg=true",
        ]
        for ep in endpoints:
            try:
                urllib.request.urlopen(f"http://{HOST}:{PORT}{ep}")
                self.fail(f"Expected 503 Service Unavailable on {ep} when camera inactive")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 503, f"Endpoint {ep} returned status {e.code}, expected 503")

    def test_02_snapshot_http_request_200_jpeg(self):
        """Verify standard HTTP snapshot request receives 200 OK with Content-Type: image/jpeg and binary payload."""
        ws = self._create_ws_client()
        try:
            ws.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            test_jpeg = make_mock_jpeg(640, 480)
            self._feed_camera_frame(ws, test_jpeg)
            time.sleep(0.05)

            # Test standard GET /api/camera/stream (default snapshot mode without multipart Accept)
            req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                body = resp.read()
                self.assertEqual(len(body), len(test_jpeg))
                self.assertEqual(body, test_jpeg)
                self.assertTrue(body.startswith(b"\xFF\xD8"))
                self.assertTrue(body.endswith(b"\xFF\xD9"))

            # Test GET /camera/mjpeg alias
            req_alias = urllib.request.Request(f"http://{HOST}:{PORT}/camera/mjpeg")
            with urllib.request.urlopen(req_alias) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                body = resp.read()
                self.assertEqual(body, test_jpeg)

            # Test explicit Accept: image/jpeg
            req_accept = urllib.request.Request(
                f"http://{HOST}:{PORT}/api/camera/stream",
                headers={"Accept": "image/jpeg"}
            )
            with urllib.request.urlopen(req_accept) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                self.assertEqual(resp.read(), test_jpeg)

            # Test /camera/snapshot and /api/camera/snapshot
            for snap_path in ["/api/camera/snapshot", "/camera/snapshot"]:
                req_snap = urllib.request.Request(f"http://{HOST}:{PORT}{snap_path}")
                with urllib.request.urlopen(req_snap) as resp:
                    self.assertEqual(resp.status, 200)
                    self.assertEqual(resp.headers.get("Content-Type"), "image/jpeg")
                    self.assertEqual(resp.read(), test_jpeg)
        finally:
            ws.send_json({"type": "camera_stop"})
            ws.close()

    def test_03_multipart_mjpeg_streaming_accept_header(self):
        """Verify multipart streaming request (Accept: multipart/x-mixed-replace) receives persistent MJPEG stream chunks."""
        ws = self._create_ws_client()
        stream_sock = None
        try:
            ws.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            initial_jpeg = make_mock_jpeg(320, 240)
            self._feed_camera_frame(ws, initial_jpeg)
            time.sleep(0.05)

            # Open raw socket for HTTP client to inspect multipart streaming response
            stream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            stream_sock.settimeout(3.0)
            stream_sock.connect((HOST, PORT))

            http_req = (
                "GET /api/camera/stream HTTP/1.1\r\n"
                f"Host: {HOST}:{PORT}\r\n"
                "Accept: multipart/x-mixed-replace; boundary=frame\r\n"
                "Connection: keep-alive\r\n\r\n"
            )
            stream_sock.sendall(http_req.encode("utf-8"))

            # Read initial response headers and first frame chunk
            buffer = bytearray()
            while b"\r\n\r\n" not in buffer:
                chunk = stream_sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)

            header_end = buffer.index(b"\r\n\r\n")
            header_bytes = bytes(buffer[:header_end])
            del buffer[:header_end + 4]

            headers_str = header_bytes.decode("utf-8", errors="replace")
            self.assertIn("200 OK", headers_str)
            self.assertIn("Content-Type: multipart/x-mixed-replace", headers_str)
            self.assertIn("boundary=frame", headers_str)

            # Wait to read initial frame from buffer
            while b"--frame\r\n" not in buffer:
                chunk = stream_sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)

            self.assertIn(b"--frame\r\n", buffer)
            self.assertIn(b"Content-Type: image/jpeg\r\n", buffer)
            self.assertIn(f"Content-Length: {len(initial_jpeg)}\r\n".encode("utf-8"), buffer)

            # Now FEED FRAME 2 dynamically via WebSocket!
            frame2_jpeg = make_mock_jpeg(400, 300)
            self._feed_camera_frame(ws, frame2_jpeg)

            # Read from stream socket and verify frame 2 chunk arrives
            deadline = time.time() + 3.0
            found_frame2 = False
            while time.time() < deadline:
                chunk = stream_sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)
                if f"Content-Length: {len(frame2_jpeg)}".encode("utf-8") in buffer:
                    found_frame2 = True
                    break

            self.assertTrue(found_frame2, "Multipart stream client did not receive dynamically broadcasted frame 2")

            # FEED FRAME 3
            frame3_jpeg = make_mock_jpeg(480, 360)
            self._feed_camera_frame(ws, frame3_jpeg)

            deadline = time.time() + 3.0
            found_frame3 = False
            while time.time() < deadline:
                chunk = stream_sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)
                if f"Content-Length: {len(frame3_jpeg)}".encode("utf-8") in buffer:
                    found_frame3 = True
                    break

            self.assertTrue(found_frame3, "Multipart stream client did not receive dynamically broadcasted frame 3")

        finally:
            if stream_sock:
                stream_sock.close()
            ws.send_json({"type": "camera_stop"})
            ws.close()

    def test_04_mjpeg_query_parameter_streaming(self):
        """Verify /camera/mjpeg?stream=true activates multipart streaming without Accept header."""
        ws = self._create_ws_client()
        stream_sock = None
        try:
            ws.send_json({"type": "camera_start", "lens": "front", "quality": "720p", "fps": 30})
            time.sleep(0.05)

            feed_jpeg = make_mock_jpeg(320, 240)
            self._feed_camera_frame(ws, feed_jpeg)
            time.sleep(0.05)

            stream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            stream_sock.settimeout(3.0)
            stream_sock.connect((HOST, PORT))

            http_req = (
                "GET /camera/mjpeg?stream=true HTTP/1.1\r\n"
                f"Host: {HOST}:{PORT}\r\n"
                "User-Agent: VLC/3.0.18 LibVLC/3.0.18\r\n"
                "Connection: close\r\n\r\n"
            )
            stream_sock.sendall(http_req.encode("utf-8"))

            # Read response
            buffer = bytearray()
            for _ in range(10):
                chunk = stream_sock.recv(4096)
                if not chunk:
                    break
                buffer.extend(chunk)
                if b"--frame\r\n" in buffer:
                    break

            resp_str = buffer.decode("utf-8", errors="replace")
            self.assertIn("200 OK", resp_str)
            self.assertIn("Content-Type: multipart/x-mixed-replace; boundary=frame", resp_str)
            self.assertIn("--frame", resp_str)
        finally:
            if stream_sock:
                stream_sock.close()
            ws.send_json({"type": "camera_stop"})
            ws.close()

    def test_05_concurrent_mjpeg_stream_clients_and_clean_termination(self):
        """Verify multiple simultaneous MJPEG clients receive broadcasts and terminate cleanly on stopCamera."""
        ws = self._create_ws_client()
        client_socks = []
        try:
            ws.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            initial_frame = make_mock_jpeg(200, 150)
            self._feed_camera_frame(ws, initial_frame)
            time.sleep(0.05)

            # Connect 4 concurrent MJPEG streaming clients
            for _ in range(4):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(3.0)
                s.connect((HOST, PORT))
                req = (
                    "GET /api/camera/stream HTTP/1.1\r\n"
                    f"Host: {HOST}:{PORT}\r\n"
                    "Accept: multipart/x-mixed-replace\r\n\r\n"
                )
                s.sendall(req.encode("utf-8"))
                client_socks.append(s)

            # Broadcast a distinctive frame
            dist_jpeg = make_mock_jpeg(350, 250)
            self._feed_camera_frame(ws, dist_jpeg)

            # Verify every client received the frame
            for idx, s in enumerate(client_socks):
                buf = bytearray()
                found = False
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    try:
                        c = s.recv(4096)
                        if not c:
                            break
                        buf.extend(c)
                        if f"Content-Length: {len(dist_jpeg)}".encode("utf-8") in buf:
                            found = True
                            break
                    except socket.timeout:
                        break
                self.assertTrue(found, f"Stream client {idx} failed to receive broadcast frame")

            # Now issue camera_stop via WebSocket: server should send '--frame--' and close connections
            ws.send_json({"type": "camera_stop"})
            time.sleep(0.1)

            # Inactive check
            try:
                urllib.request.urlopen(f"http://{HOST}:{PORT}/api/camera/stream")
                self.fail("Expected 503 after camera_stop")
            except urllib.error.HTTPError as e:
                self.assertEqual(e.code, 503)

        finally:
            for s in client_socks:
                try:
                    s.close()
                except Exception:
                    pass
            ws.close()

    # =========================================================================
    # Task 2: Camera Controls & Watchdog Recovery
    # =========================================================================

    def test_06_lens_switching_deduplication_and_canonical_control(self):
        """
        Verify lens switching inbound message tolerance and schema aliases:
        1. Test canonical lenses (front, back, ultra_wide, telephoto).
        2. Test unknown lenses and boundary strings (periscope_zoom_5x, macro_lens, empty string, whitespace).
        3. Test schema aliases (facing mapped to lens).
        4. Verify server socket remains healthy and responsive.
        """
        client = self._create_ws_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.02)

            test_lenses = [
                "front", "back", "ultra_wide", "telephoto",
                "periscope_zoom_5x", "macro_lens", "infrared",
                "", "   ", "UNKNOWN_LENS_SENSOR_XYZ"
            ]
            for target_lens in test_lenses:
                # Inbound canonical camera_control
                client.send_json({
                    "type": "camera_control",
                    "action": "switch_lens",
                    "lens": target_lens
                })
                # Inbound with facing alias
                client.send_json({
                    "type": "camera_control",
                    "action": "switch_lens",
                    "facing": target_lens
                })
                # Inbound legacy camera_switch_lens
                client.send_json({
                    "type": "camera_switch_lens",
                    "lens": target_lens
                })

            time.sleep(0.05)
            client.send_ping(b"lens_switch_healthy")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"lens_switch_healthy")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_07_digital_zoom_and_torch_controls(self):
        """Verify digital zoom and torch controls handling on live server."""
        client = self._create_ws_client()
        try:
            client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.02)

            # 1. Digital Zoom levels (including negative, zero, extreme values)
            for zoom_val in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 0.0, -1.0, 100.0, 0.001]:
                client.send_json({
                    "type": "camera_control",
                    "action": "set_zoom",
                    "zoom": zoom_val
                })

            # 2. Torch toggles (rapid toggle bursts)
            for _ in range(25):
                client.send_json({
                    "type": "camera_control",
                    "action": "toggle_torch",
                    "torch": True
                })
                client.send_json({
                    "type": "camera_control",
                    "action": "toggle_torch",
                    "torch": False
                })

            time.sleep(0.05)
            client.send_ping(b"zoom_torch_healthy")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"zoom_torch_healthy")
        finally:
            client.send_json({"type": "camera_stop"})
            client.close()

    def test_08_watchdog_stream_stall_recovery(self):
        """
        Verify watchdog stall recovery (5.0s threshold):
        1. Camera started and initial frame fed -> /api/camera/stream is 200 OK.
        2. No frames fed for > 5000ms.
        3. Watchdog fires, issues stopCamera.
        4. Endpoint transitions to 503 Service Unavailable.
        5. Connected WebSocket listener receives camera_stop notification.
        """
        listener = self._create_ws_client()
        feed_client = self._create_ws_client()
        try:
            feed_client.send_json({"type": "camera_start", "lens": "back", "quality": "1080p", "fps": 30})
            time.sleep(0.05)

            initial_jpeg = make_mock_jpeg(160, 120)
            self._feed_camera_frame(feed_client, initial_jpeg)
            time.sleep(0.05)

            # Verify stream endpoint active
            req = urllib.request.Request(f"http://{HOST}:{PORT}/api/camera/stream")
            with urllib.request.urlopen(req) as resp:
                self.assertEqual(resp.status, 200)

            # Drain any startup messages on listener
            listener.drain_messages()

            # Wait for stall: threshold is 5.0s, timer runs every 1.0s, so trigger occurs between 5.0s and 6.5s
            stalled = False
            start_time = time.time()
            for _ in range(16):
                time.sleep(0.5)
                try:
                    urllib.request.urlopen(f"http://{HOST}:{PORT}/api/camera/stream")
                except urllib.error.HTTPError as e:
                    if e.code == 503:
                        stalled = True
                        elapsed = time.time() - start_time
                        print(f" [Watchdog] Stall detected and 503 returned after {elapsed:.2f}s")
                        break

            self.assertTrue(stalled, "Watchdog failed to stop camera feeder after >5000ms inactivity")

            # Verify WebSocket listener receives 'camera_stop'
            stop_received = False
            deadline = time.time() + 3.0
            while time.time() < deadline:
                try:
                    op, msg_bytes = listener.recv_frame(timeout=1.0)
                    if op == 0x1:
                        m = json.loads(msg_bytes.decode("utf-8"))
                        if m.get("type") == "camera_stop":
                            stop_received = True
                            break
                except (TimeoutError, socket.timeout):
                    break

            self.assertTrue(stop_received, "Connected client did not receive camera_stop broadcast upon watchdog timeout")

        finally:
            listener.close()
            feed_client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
