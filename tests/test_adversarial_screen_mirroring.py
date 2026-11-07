#!/usr/bin/env python3
"""
Adversarial Stress Test Suite for Screen Mirroring (Milestone 3 Challenge).
Thoroughly stress-tests:
1. 5-byte binary packet framing (stream type 0x01, UInt32 BE length), corrupted headers (<5 bytes),
   zero-length payloads, declared length exceeding actual buffer, arbitrary stream types, and 1MB payloads.
2. Remote touch input boundaries (negative coordinates x: -0.5, y: -0.2; excess coordinates x: 2.5, y: 3.0;
   extreme values; unknown action names like 'hover_scroll_pinch'; rapid gesture spam).
3. Remote key events (standard keys 'BACK', 'HOME', 'RECENTS', 'ENTER'; unknown keys 'HYPER_DIMENSIONAL_BUTTON';
   boundary key codes; rapid key event spam).
4. Session lifecycle (screen_start with zero dimensions, redundant screen_stop idempotence, rapid start/stop cycles).
5. Watchdog stall recovery (>5000ms inactivity recovery emitting screen_stop on live macOS server).
"""

import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    ContinuityTestHarness,
    MockContinuityServer,
    decode_ws_frame,
    encode_ws_frame,
    make_stream_packet,
    parse_stream_packet,
)


def make_5byte_packet(stream_type: int, payload: bytes, declared_len: int = None) -> bytes:
    if declared_len is None:
        declared_len = len(payload)
    return struct.pack(">BI", stream_type, declared_len) + payload


class TestAdversarialScreenMirroring(unittest.TestCase):
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

    def setUp(self):
        with self.server.lock:
            self.server.received_messages.clear()
            self.server.received_binary_frames.clear()
            self.server.input_events.clear()
            self.server.screen_mirroring_active = False

    # =========================================================================
    # Part 1: 5-Byte Binary Packet Framing
    # =========================================================================

    def test_01_screen_stream_packet_framing_h264_nal(self):
        """Standard Screen Mirroring binary packet with H.264 Annex B NAL unit."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            nal_payload = b"\x00\x00\x00\x01\x65\x88\x84\x00\x10\x20\x30"
            packet = make_5byte_packet(0x01, nal_payload)
            self.assertEqual(len(packet), 5 + len(nal_payload))
            self.assertEqual(packet[0], 0x01)

            parsed = parse_stream_packet(packet)
            self.assertEqual(parsed["stream_type"], 0x01)
            self.assertEqual(parsed["payload"], nal_payload)

            # Transmit over WebSocket opcode 0x2
            client.send_binary(packet)
            self.assertTrue(self.server.wait_for_binary_frames(min_count=1, timeout=1.0))
            with self.server.lock:
                self.assertEqual(len(self.server.received_binary_frames), 1)
                self.assertEqual(self.server.received_binary_frames[0], packet)
        finally:
            client.close()

    def test_02_screen_stream_packet_zero_length_payload(self):
        """Zero-length payload stream packet (exactly 5 bytes) parses cleanly."""
        packet = make_5byte_packet(0x01, b"")
        self.assertEqual(len(packet), 5)

        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x01)
        self.assertEqual(parsed["payload"], b"")

        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_binary(packet)
            self.assertTrue(self.server.wait_for_binary_frames(min_count=1, timeout=1.0))
            with self.server.lock:
                self.assertEqual(self.server.received_binary_frames[-1], packet)
        finally:
            client.close()

    def test_03_screen_stream_packet_truncated_headers(self):
        """Headers shorter than 4 bytes (0, 1, 2, 3 bytes) raise ValueError without crash."""
        for sz in range(4):
            truncated = b"\x01\x00\x00\x00"[:sz]
            with self.assertRaises(ValueError):
                parse_stream_packet(truncated)

    def test_04_screen_stream_packet_declared_length_exceeding_buffer(self):
        """Declared length larger than actual provided bytes is safely bounded."""
        packet = make_5byte_packet(0x01, b"\xAA\xBB\xCC", declared_len=10000)
        self.assertEqual(len(packet), 8)
        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x01)
        self.assertEqual(parsed["payload"], b"\xAA\xBB\xCC")

    def test_05_screen_stream_packet_large_1mb_payload(self):
        """Stream packet carrying 1 MB video frame roundtrips reliably over WebSocket."""
        one_mb = 1024 * 1024
        large_frame = b"\x00\x00\x00\x01\x65" + (b"\xFF" * (one_mb - 5))
        packet = make_5byte_packet(0x01, large_frame)

        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x01)
        self.assertEqual(len(parsed["payload"]), one_mb)

        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_binary(packet)
            self.assertTrue(self.server.wait_for_binary_frames(min_count=1, timeout=2.0))
            with self.server.lock:
                self.assertEqual(len(self.server.received_binary_frames[-1]), 5 + one_mb)
        finally:
            client.close()

    def test_06_screen_stream_packet_rapid_stream(self):
        """Stream of 50 consecutive binary video frames without socket stall or frame drop."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for i in range(50):
                chunk = struct.pack(">I", i) * 64
                pkt = make_5byte_packet(0x01, chunk)
                client.send_binary(pkt)

            self.assertTrue(self.server.wait_for_binary_frames(min_count=50, timeout=3.0))
            with self.server.lock:
                self.assertEqual(len(self.server.received_binary_frames), 50)
        finally:
            client.close()

    # =========================================================================
    # Part 2: Remote Touch Input Boundaries
    # =========================================================================

    def test_07_touch_input_negative_coordinates(self):
        """Remote touch with negative coordinates (x: -0.5, y: -0.2) is accepted safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            msg = {"type": "input_event", "action": "down", "x": -0.5, "y": -0.2, "button": 0}
            client.send_json(msg)
            time.sleep(0.05)
            with self.server.lock:
                evt = self.server.input_events[-1]
                self.assertEqual(evt["x"], -0.5)
                self.assertEqual(evt["y"], -0.2)
        finally:
            client.close()

    def test_08_touch_input_excess_coordinates(self):
        """Remote touch with excess coordinates (x: 2.5, y: 3.0) is accepted safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            msg = {"type": "input_event", "action": "move", "x": 2.5, "y": 3.0, "button": 0}
            client.send_json(msg)
            time.sleep(0.05)
            with self.server.lock:
                evt = self.server.input_events[-1]
                self.assertEqual(evt["x"], 2.5)
                self.assertEqual(evt["y"], 3.0)
        finally:
            client.close()

    def test_09_touch_input_extreme_coordinates(self):
        """Extreme coordinates (x: -1e9, y: 1e9) do not cause arithmetic exceptions."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            msg = {"type": "input_event", "action": "up", "x": -1000000000.0, "y": 1000000000.0}
            client.send_json(msg)
            time.sleep(0.05)
            with self.server.lock:
                evt = self.server.input_events[-1]
                self.assertEqual(evt["x"], -1000000000.0)
                self.assertEqual(evt["y"], 1000000000.0)
        finally:
            client.close()

    def test_10_touch_input_unknown_action_name(self):
        """Unknown action ('hover_scroll_pinch') is parsed without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            msg = {"type": "input_event", "action": "hover_scroll_pinch", "x": 0.5, "y": 0.5}
            client.send_json(msg)
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.input_events[-1]["action"], "hover_scroll_pinch")
        finally:
            client.close()

    def test_11_touch_input_rapid_gesture_spam(self):
        """Rapid gesture spam (200 consecutive input events) executes cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for i in range(200):
                norm = (i % 100) / 100.0
                client.send_json({
                    "type": "input_event",
                    "action": "move",
                    "x": norm,
                    "y": norm,
                    "button": i % 3
                })
            time.sleep(0.1)
            with self.server.lock:
                self.assertEqual(len(self.server.input_events), 200)
        finally:
            client.close()

    # =========================================================================
    # Part 3: Remote Key Events
    # =========================================================================

    def test_12_remote_key_standard_navigation(self):
        """Standard navigation keys ('BACK', 'HOME', 'RECENTS', 'ENTER') parse correctly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            keys = [
                ("BACK", 4),
                ("HOME", 3),
                ("RECENTS", 187),
                ("ENTER", 66),
                ("POWER", 26)
            ]
            for key, code in keys:
                client.send_json({"type": "input_key", "key": key, "keyCode": code})

            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(len(self.server.input_events), len(keys))
                for i, (key, code) in enumerate(keys):
                    self.assertEqual(self.server.input_events[i]["key"], key)
                    self.assertEqual(self.server.input_events[i]["keyCode"], code)
        finally:
            client.close()

    def test_13_remote_key_unknown_button_and_negative_code(self):
        """Unknown key ('HYPER_DIMENSIONAL_BUTTON') with negative/excessive keyCode parses safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({
                "type": "input_key",
                "key": "HYPER_DIMENSIONAL_BUTTON",
                "keyCode": 999999
            })
            client.send_json({
                "type": "input_key",
                "key": "UNKNOWN_SUPER_KEY",
                "keyCode": -1
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.input_events[-2]["key"], "HYPER_DIMENSIONAL_BUTTON")
                self.assertEqual(self.server.input_events[-1]["keyCode"], -1)
        finally:
            client.close()

    # =========================================================================
    # Part 4: Session Lifecycle & Idempotence
    # =========================================================================

    def test_14_screen_start_zero_and_negative_dimensions(self):
        """screen_start with zero or negative dimensions does not crash server."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "screen_start", "width": 0, "height": 0, "fps": 0, "bitrate": 0})
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)

            client.send_json({"type": "screen_start", "width": -1080, "height": -2400})
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)
        finally:
            client.close()

    def test_15_screen_stop_consecutive_idempotence(self):
        """Consecutive screen_stop calls when already stopped are strictly idempotent."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            self.server.screen_mirroring_active = False
            for _ in range(5):
                client.send_json({"type": "screen_stop", "reason": "repeated_stop"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.screen_mirroring_active)
        finally:
            client.close()

    def test_16_rapid_screen_start_stop_cycling(self):
        """10 rapid alternating screen_start and screen_stop cycles preserve state consistency."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for _ in range(10):
                client.send_json({"type": "screen_start", "width": 1080, "height": 2400})
                client.send_json({"type": "screen_stop", "reason": "cycle"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.screen_mirroring_active)
        finally:
            client.close()


class TestLiveMacScreenMirroringAdversarial(unittest.TestCase):
    """
    Direct empirical tests against the live native macOS GalaxyContinuity server (port 8765).
    Verifies live binary frame parsing, input event dispatch, and watchdog stall recovery.
    """
    HOST = "127.0.0.1"
    PORT = 8765
    server_process = None

    @classmethod
    def setUpClass(cls):
        # Check if already listening
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            s.connect((cls.HOST, cls.PORT))
            s.close()
            return  # Already listening
        except Exception:
            s.close()

        # Launch debug binary
        bin_path = os.path.join(PROJECT_ROOT, "mac/.build/arm64-apple-macosx/debug/GalaxyContinuity")
        if not os.path.exists(bin_path):
            raise unittest.SkipTest(f"Binary not found at {bin_path}")

        cls.server_process = subprocess.Popen(
            [bin_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        # Poll until port is open
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

    def test_01_live_binary_frame_stream_and_ping_alive(self):
        """Live macOS server ingests Screen Mirroring binary frames without socket disruption."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            # Drain handshake_ack and initial state
            time.sleep(0.05)
            client.drain_messages()

            # Send valid screen packet
            nal = b"\x00\x00\x00\x01\x65\x88\x84\x11\x22"
            pkt = make_5byte_packet(0x01, nal)
            client.send_binary(pkt)
            time.sleep(0.02)

            # Send ping to verify socket health
            client.send_ping(b"live_screen_alive")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"live_screen_alive")
        finally:
            client.close()

    def test_02_live_corrupted_binary_packets_tolerance(self):
        """Live macOS server drops truncated binary frames (<5 bytes) safely."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            # Send corrupted short headers (1 to 4 bytes)
            for sz in range(1, 5):
                client.send_binary(b"\x01\x00\x00\x00"[:sz])

            time.sleep(0.02)
            # Verify server is still alive
            client.send_ping(b"after_corrupt")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"after_corrupt")
        finally:
            client.close()

    def test_03_live_remote_touch_and_key_events(self):
        """Live macOS server accepts boundary touch and key events without crashing."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            # Boundary touch
            client.send_json({"type": "input_event", "action": "down", "x": -0.5, "y": -0.2})
            client.send_json({"type": "input_event", "action": "move", "x": 2.5, "y": 3.0})
            client.send_json({"type": "input_event", "action": "hover_scroll_pinch", "x": 0.5, "y": 0.5})

            # Boundary keys
            client.send_json({"type": "input_key", "key": "BACK", "keyCode": 4})
            client.send_json({"type": "input_key", "key": "HYPER_DIMENSIONAL_BUTTON", "keyCode": 999999})

            time.sleep(0.05)
            # Verify server is responsive
            client.send_ping(b"after_inputs")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"after_inputs")
        finally:
            client.close()

    def test_04_live_stalling_watchdog_recovery(self):
        """Live macOS server ScreenMirroringService watchdog fires screen_stop when inactive >5000ms."""
        client = ContinuityClient(host=self.HOST, port=self.PORT)
        client.connect(send_initial_handshake=True)
        try:
            time.sleep(0.05)
            client.drain_messages()

            # Start screen mirroring session
            client.send_json({"type": "screen_start", "width": 1080, "height": 2400, "fps": 30, "bitrate": 4000000})

            # Feed 1 frame to establish active stream
            pkt = make_5byte_packet(0x01, b"\x00\x00\x00\x01\x65\x00\x00")
            client.send_binary(pkt)
            time.sleep(0.1)

            # Drain any messages during stream
            client.drain_messages()

            # Now STALL the stream (send no frames for > 5.5 seconds)
            # The watchdog timer in ScreenMirroringService checks every 1.0s and if Date().timeIntervalSince(last) > 5.0,
            # it issues stopMirroring(reason: "stream_stalled"), which broadcasts screen_stop.
            start_stall = time.time()
            stalled_stop_received = False

            # Wait up to 7.5 seconds for the watchdog broadcast
            deadline = time.time() + 7.5
            while time.time() < deadline:
                try:
                    msg = client.recv_json(timeout=1.0)
                    if msg.get("type") == "screen_stop" and msg.get("reason") == "stream_stalled":
                        stalled_stop_received = True
                        break
                except (TimeoutError, ValueError):
                    pass

            self.assertTrue(
                stalled_stop_received,
                f"Expected screen_stop with reason 'stream_stalled' after >5000ms inactivity, elapsed: {time.time() - start_stall:.2f}s"
            )
        finally:
            # Clean up by sending a stop just in case
            try:
                client.send_json({"type": "screen_stop", "reason": "test_cleanup"})
            except Exception:
                pass
            client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
