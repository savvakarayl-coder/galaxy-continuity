"""
Galaxy Continuity — Tier 2: Boundary Value Analysis & Negative Edge Cases
Exhaustively tests boundary values, malformed payloads, oversized frames,
empty strings, missing headers, path traversals, and error conditions across all 10 features.
Covers >= 50 test cases.
Zero external dependencies.
"""

import base64
import hashlib
import json
import os
import socket
import tempfile
import time
import unittest

from tests.e2e.harness import (
    BLE_SERVICE_UUID,
    DEFAULT_PORT,
    SERVICE_TYPE,
    WIFI_DIRECT_DEFAULT_IP,
    ContinuityClient,
    ContinuityTestHarness,
    MockApkVerifier,
    MockBleAdvertiser,
    MockGitHubReleaseClient,
    MockMdnsRecord,
    download_file,
    encode_ws_frame,
    http_get,
    http_post,
    make_mock_jpeg,
    make_stream_packet,
    parse_stream_packet,
    upload_file,
)


class TestTier2Boundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.harness = ContinuityTestHarness()
        cls.harness.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.harness.__exit__(None, None, None)

    def setUp(self):
        self.host = self.harness.host
        self.port = self.harness.port
        self.server = self.harness.server
        with self.server.lock:
            self.server.last_clipboard_text = None
            self.server.received_messages.clear()
            self.server.received_binary_frames.clear()
            self.server.input_events.clear()
            self.server.notifications_received.clear()

    # =========================================================================
    # Feature 1: Handshake & Protocol Framing Boundary Cases
    # =========================================================================

    def test_01_handshake_missing_sec_websocket_key(self):
        """GET /ws with Upgrade: websocket but missing Sec-WebSocket-Key fails upgrade."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect((self.host, self.port))
        try:
            req = f"GET /ws HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            sock.sendall(req.encode("utf-8"))
            resp = sock.recv(1024)
            # Must NOT return 101 Switching Protocols
            self.assertNotIn(b"101 Switching Protocols", resp)
        finally:
            sock.close()

    def test_02_handshake_non_websocket_path_returns_404(self):
        """Requesting an invalid path returns HTTP 404 Not Found."""
        status, _, _ = http_get(self.host, self.port, "/nonexistent_invalid_path_404")
        self.assertEqual(status, 404)

    def test_03_handshake_wrong_method_post_ws_returns_404(self):
        """POST /ws returns 404 instead of upgrading."""
        status, _, _ = http_post(self.host, self.port, "/ws", b"")
        self.assertEqual(status, 404)

    def test_04_unmasked_client_frame_handling(self):
        """Server accepts unmasked client frames (mask bit = 0) without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Send text frame with masked=False
            msg = {"type": "battery_update", "level": 99, "isCharging": False}
            unmasked_frame = encode_ws_frame(0x1, json.dumps(msg).encode("utf-8"), masked=False)
            client.sock.sendall(unmasked_frame)
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.battery_info["level"], 99)
        finally:
            client.close()

    def test_05_malformed_json_frame_dropped_without_crash(self):
        """Malformed JSON text payload is safely discarded and connection stays alive."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Send broken non-JSON text
            client.send_frame(0x1, b"BROKEN_JSON_{{{[[[", masked=True)
            time.sleep(0.05)
            # Verify server did not crash by sending a valid message immediately after
            client.send_json({"type": "battery_update", "level": 55, "isCharging": True})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.battery_info["level"], 55)
        finally:
            client.close()

    def test_06_unknown_message_type_ignored(self):
        """Unknown message type is ignored safely without dropping connection."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "quantum_teleportation_event", "param": 42})
            time.sleep(0.05)
            client.send_ping(b"still_alive")
            opcode, payload = client.recv_frame(timeout=2.0)
            self.assertEqual(opcode, 0xA)  # Pong received
        finally:
            client.close()

    # =========================================================================
    # Feature 2: Bidirectional Text Clipboard Boundary Cases
    # =========================================================================

    def test_07_text_clipboard_empty_string(self):
        """Empty string clipboard content is handled without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "clipboard", "content": "", "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "")
        finally:
            client.close()

    def test_08_text_clipboard_massive_payload_1mb(self):
        """Massive 1 MB text clipboard (64-bit frame length) transfers intact."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1 MB text
            huge_text = "GalaxyContinuity2026" * 52428  # ~1,048,560 bytes
            client.send_json({"type": "clipboard", "content": huge_text, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.2)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, huge_text)
        finally:
            client.close()

    def test_09_text_clipboard_special_control_characters(self):
        """Control characters (tab, newline, null-byte escape) survive serialization."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            control_str = "Line 1\r\nLine 2\tTabbed\x1b[31mRed\x1b[0m"
            client.send_json({"type": "clipboard", "content": control_str, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, control_str)
        finally:
            client.close()

    def test_10_text_clipboard_rtl_and_unicode_normalization(self):
        """Right-to-left Arabic, Hebrew, and complex emoji sequences transfer faithfully."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            complex_str = "مرحبا بالعالم | שלום עולם | 👨‍👩‍👧‍👦 🏳️‍🌈 🛰️"
            client.send_json({"type": "clipboard", "content": complex_str, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, complex_str)
        finally:
            client.close()

    def test_11_text_clipboard_missing_content_type(self):
        """Clipboard message missing contentType defaults cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "clipboard", "content": "No content type provided", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "No content type provided")
        finally:
            client.close()

    def test_12_rapid_successive_text_clipboard_burst(self):
        """Burst of 20 distinct clipboard updates in rapid succession."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for i in range(20):
                client.send_json({"type": "clipboard", "content": f"Burst update {i}", "source": "phone"})
            time.sleep(0.1)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "Burst update 19")
        finally:
            client.close()

    # =========================================================================
    # Feature 3: Bidirectional Image Clipboard Boundary Cases
    # =========================================================================

    def test_13_image_clipboard_empty_payload(self):
        """Image clipboard message with empty base64 content is handled without crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "clipboard", "content": "", "contentType": "image/png", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "")
        finally:
            client.close()

    def test_14_image_clipboard_invalid_corrupted_base64(self):
        """Corrupted base64 payload is received without server crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({
                "type": "clipboard",
                "content": "!@#$%^&*()_+NonValidBase64",
                "contentType": "image/png",
                "source": "phone"
            })
            time.sleep(0.05)
            # Server remains responsive
            client.send_ping(b"heartbeat_after_corrupt")
            opcode, _ = client.recv_frame(timeout=2.0)
            self.assertEqual(opcode, 0xA)
        finally:
            client.close()

    def test_15_image_clipboard_truncated_base64(self):
        """Truncated base64 data string (odd length without padding) handled cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "clipboard", "content": "abc12", "contentType": "image/png", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "abc12")
        finally:
            client.close()

    def test_16_image_clipboard_large_image_2mb(self):
        """Large synthetic image base64 frame (>64KB exercising 64-bit frame length) is processed completely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            raw_blob = os.urandom(128 * 1024)
            b64_large = base64.b64encode(raw_blob).decode("ascii")
            client.send_json({"type": "clipboard", "content": b64_large, "contentType": "image/png", "source": "phone"})
            time.sleep(0.1)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_large)
        finally:
            client.close()

    def test_17_image_clipboard_unsupported_content_type(self):
        """Unusual image MIME type (image/webp) accepted without failure."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            b64_webp = base64.b64encode(b"RIFF....WEBP").decode("ascii")
            client.send_json({"type": "clipboard", "content": b64_webp, "contentType": "image/webp", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_webp)
        finally:
            client.close()

    # =========================================================================
    # Feature 4: Quick Drop (Mac -> Phone) Boundary Cases
    # =========================================================================

    def test_18_download_nonexistent_file_id_returns_404(self):
        """Downloading unknown fileId returns HTTP 404 Not Found."""
        status, _, _ = download_file(self.host, self.port, "00000000-0000-0000-0000-000000000000")
        self.assertEqual(status, 404)

    def test_19_download_deleted_file_on_disk_returns_404(self):
        """Shared file registered in memory but deleted from disk returns 404."""
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(b"soon to be deleted")
            tf_path = tf.name
        file_id = self.server.share_file(tf_path, filename="deleted.txt")
        os.remove(tf_path)  # Delete on disk
        status, _, _ = download_file(self.host, self.port, file_id)
        self.assertEqual(status, 404)

    def test_20_download_zero_byte_file(self):
        """Downloading an empty 0-byte shared file succeeds with 200 OK and 0 bytes."""
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf_path = tf.name
        try:
            file_id = self.server.share_file(tf_path, filename="empty.txt")
            status, headers, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(len(body), 0)
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_21_download_file_id_path_traversal_attempt(self):
        """Path traversal attempt in fileId parameter returns 404."""
        status, _, _ = download_file(self.host, self.port, "../../etc/passwd")
        self.assertEqual(status, 404)

    def test_22_download_unsupported_http_method_post(self):
        """POST to /api/download/:fileId returns 404 Not Found."""
        status, _, _ = http_post(self.host, self.port, "/api/download/any-id", b"")
        self.assertEqual(status, 404)

    # =========================================================================
    # Feature 5: Quick Drop (Phone -> Mac) Boundary Cases
    # =========================================================================

    def test_23_upload_zero_byte_file(self):
        """Uploading empty 0-byte file succeeds with 200 OK."""
        status, _, body = upload_file(self.host, self.port, "zero.dat", b"")
        self.assertEqual(status, 200)
        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == "zero.dat"]
            self.assertTrue(len(uploaded) > 0)
            self.assertEqual(uploaded[0]["size"], 0)

    def test_24_upload_missing_content_length(self):
        """POST /api/upload missing Content-Length defaults length to 0 safely."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect((self.host, self.port))
        try:
            req = f"POST /api/upload HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nConnection: close\r\n\r\n"
            sock.sendall(req.encode("utf-8"))
            resp = sock.recv(1024)
            self.assertIn(b"200 OK", resp)
        finally:
            sock.close()

    def test_25_upload_unsupported_method_put(self):
        """PUT /api/upload is rejected with 404 Not Found."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect((self.host, self.port))
        try:
            req = f"PUT /api/upload HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nConnection: close\r\n\r\n"
            sock.sendall(req.encode("utf-8"))
            resp = sock.recv(1024)
            self.assertIn(b"404 Not Found", resp)
        finally:
            sock.close()

    def test_26_upload_unsupported_method_get(self):
        """GET /api/upload returns 404 Not Found."""
        status, _, _ = http_get(self.host, self.port, "/api/upload")
        self.assertEqual(status, 404)

    def test_27_upload_extreme_filename_length(self):
        """Upload with long 150-character filename is safely written to disk."""
        long_name = "A" * 140 + ".txt"
        status, _, _ = upload_file(self.host, self.port, long_name, b"Long filename test")
        self.assertEqual(status, 200)
        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == long_name]
            self.assertTrue(len(uploaded) > 0)

    def test_28_upload_filename_path_traversal_sanitization(self):
        """Filename with path traversal components ../../ is stripped to base name."""
        traversal_name = "../../etc/malicious.sh"
        status, _, _ = upload_file(self.host, self.port, traversal_name, b"echo bad")
        self.assertEqual(status, 200)
        with self.server.lock:
            # File must be stored within self.server.downloads_dir
            for f in self.server.uploaded_files:
                self.assertTrue(f["path"].startswith(self.server.downloads_dir))

    # =========================================================================
    # Feature 6: Screen Mirroring Boundary Cases
    # =========================================================================

    def test_29_screen_input_coordinates_out_of_bounds_negative(self):
        """Remote touch with negative coordinates is accepted without server crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "input_event", "action": "down", "x": -0.5, "y": -0.2})
            time.sleep(0.05)
            with self.server.lock:
                last_evt = self.server.input_events[-1]
                self.assertEqual(last_evt["x"], -0.5)
        finally:
            client.close()

    def test_30_screen_input_coordinates_out_of_bounds_excess(self):
        """Remote touch with coordinates exceeding 1.0 handled safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "input_event", "action": "move", "x": 2.5, "y": 3.0})
            time.sleep(0.05)
            with self.server.lock:
                last_evt = self.server.input_events[-1]
                self.assertEqual(last_evt["x"], 2.5)
        finally:
            client.close()

    def test_31_screen_input_unknown_action(self):
        """Unknown input event action ('hover_scroll_pinch') is parsed without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "input_event", "action": "hover_scroll_pinch", "x": 0.5, "y": 0.5})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.input_events[-1]["action"], "hover_scroll_pinch")
        finally:
            client.close()

    def test_32_screen_input_unknown_key_code(self):
        """Unknown key identifier string is accepted safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "input_key", "key": "HYPER_DIMENSIONAL_BUTTON"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.input_events[-1]["key"], "HYPER_DIMENSIONAL_BUTTON")
        finally:
            client.close()

    def test_33_screen_start_zero_dimensions(self):
        """screen_start with width=0, height=0 does not crash server."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "screen_start", "width": 0, "height": 0, "fps": 0, "bitrate": 0})
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)
        finally:
            client.close()

    def test_34_screen_stop_when_already_stopped(self):
        """Calling screen_stop when inactive is idempotent and safe."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            self.server.screen_mirroring_active = False
            client.send_json({"type": "screen_stop"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.screen_mirroring_active)
        finally:
            client.close()

    # =========================================================================
    # Feature 7: Continuity Camera Boundary Cases
    # =========================================================================

    def test_35_camera_switch_lens_unknown_lens(self):
        """camera_switch_lens with unusual lens name handled gracefully."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "camera_switch_lens", "facing": "periscope_zoom_5x"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.camera_lens, "periscope_zoom_5x")
        finally:
            client.close()

    def test_36_camera_start_zero_fps(self):
        """camera_start with fps: 0 is parsed without crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "camera_start", "facing": "front", "resolution": "720p", "fps": 0})
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.camera_streaming_active)
        finally:
            client.close()

    def test_37_camera_stop_when_not_started(self):
        """camera_stop when camera stream is not running is idempotent."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            self.server.camera_streaming_active = False
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.camera_streaming_active)
        finally:
            client.close()

    def test_38_camera_corrupted_stream_packet_short_header(self):
        """Stream packet with < 5 bytes raises ValueError in parser safely (PROTOCOL.md § 4.2)."""
        with self.assertRaises(ValueError):
            parse_stream_packet(b"\x01\x01\x00")

    def test_39_camera_stream_packet_zero_length_payload(self):
        """Stream packet with empty 0-byte payload parses correctly."""
        packet = make_stream_packet(stream_type=0x02, payload=b"")
        parsed = parse_stream_packet(packet)
        self.assertEqual(parsed["stream_type"], 0x02)
        self.assertEqual(parsed["length"], 0)
        self.assertEqual(len(parsed["payload"]), 0)

    # =========================================================================
    # Feature 8: Notification Sync Boundary Cases
    # =========================================================================

    def test_40_notification_missing_id(self):
        """Notification missing 'id' attribute is accepted without failure."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "phone_notification", "app": "Messages", "title": "Bob", "text": "Hi"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.notifications_received[-1]["title"], "Bob")
        finally:
            client.close()

    def test_41_notification_empty_title_and_text(self):
        """Notification with empty title and empty text is processed cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "phone_notification", "id": "empty-1", "app": "SilentApp", "title": "", "text": ""})
            time.sleep(0.05)
            with self.server.lock:
                last_n = self.server.notifications_received[-1]
                self.assertEqual(last_n["title"], "")
                self.assertEqual(last_n["text"], "")
        finally:
            client.close()

    def test_42_notification_massive_text_body_10kb(self):
        """Long notification message with 10 KB body is received intact."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            huge_msg = "NotificationTextContent" * 450  # ~10 KB
            client.send_json({"type": "phone_notification", "id": "huge-1", "app": "Email", "title": "Report", "text": huge_msg})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.notifications_received[-1]["text"], huge_msg)
        finally:
            client.close()

    def test_43_notification_reply_nonexistent_id(self):
        """Dispatching quick reply for unknown notification ID is handled safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            reply = {"type": "notification_reply", "id": "ghost-id-404", "replyText": "Testing reply to ghost"}
            self.server.broadcast_message(reply)
            msg = client.expect_message("notification_reply", timeout=2.0)
            self.assertEqual(msg.get("id"), "ghost-id-404")
        finally:
            client.close()

    def test_44_notification_reply_empty_reply_text(self):
        """Notification reply with empty text is preserved cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            reply = {"type": "notification_reply", "id": "n-1", "replyText": ""}
            self.server.broadcast_message(reply)
            msg = client.expect_message("notification_reply", timeout=2.0)
            self.assertEqual(msg.get("replyText"), "")
        finally:
            client.close()

    # =========================================================================
    # Feature 9: Peer Discovery Boundary Cases
    # =========================================================================

    def test_45_ble_advertisement_data_truncated(self):
        """Parsing BLE service data with < 7 bytes raises ValueError."""
        with self.assertRaises(ValueError):
            MockBleAdvertiser.parse_advertisement_data({"service_data": b"\x01\x02\x03"})

    def test_46_ble_advertisement_reserved_flags(self):
        """BLE advertising flags with high bits set parsed without crashing."""
        raw_ad = {"service_data": b"\xAA\xBB\xCC\xDD" + b"\x22\x3D" + bytes([0xFE])}
        parsed = MockBleAdvertiser.parse_advertisement_data(raw_ad)
        self.assertEqual(parsed["short_id"], "aabbccdd")
        self.assertEqual(parsed["port"], 8765)
        self.assertFalse(parsed["is_ready"])  # 0xFE & 0x01 == 0
        self.assertTrue(parsed["wifi_direct_available"])  # 0xFE & 0x02 != 0

    def test_47_mdns_port_boundary_zero_and_max(self):
        """mDNS records with boundary ports (0 and 65535) handle resolution."""
        rec0 = MockMdnsRecord(port=0)
        rec_max = MockMdnsRecord(port=65535)
        self.assertEqual(rec0.resolve()["port"], 0)
        self.assertEqual(rec_max.resolve()["port"], 65535)

    def test_48_mdns_txt_record_empty_values(self):
        """mDNS record with empty string TXT entries is valid."""
        rec = MockMdnsRecord(name="")
        rec.txt_records["platform"] = ""
        resolved = rec.resolve()
        self.assertEqual(resolved["txt"]["platform"], "")

    def test_49_wifi_direct_socket_timeout_on_unreachable_ip(self):
        """Connecting client to unreachable address times out cleanly without hang."""
        client = ContinuityClient(host="127.0.0.1", port=59999, timeout=0.1)
        with self.assertRaises((socket.timeout, OSError, ConnectionError)):
            client.connect()

    # =========================================================================
    # Feature 10: Android APK Build & GitHub Release Boundary Cases
    # =========================================================================

    def test_50_apk_verifier_missing_manifest_fails(self):
        """MockApkVerifier flags missing Android directory correctly."""
        with tempfile.TemporaryDirectory() as empty_dir:
            res = MockApkVerifier.verify_android_project_files(empty_dir)
            self.assertFalse(res["android_dir_exists"])
            self.assertFalse(res["manifest_exists"])

    def test_51_github_release_empty_tag_raises_error(self):
        """Attempting to create release with empty tag raises ValueError."""
        gh = MockGitHubReleaseClient()
        with self.assertRaises(ValueError):
            gh.create_release(tag="", title="Release", notes="", asset_paths=[])

    def test_52_github_release_nonexistent_asset_raises_error(self):
        """Attempting to attach nonexistent file to release raises FileNotFoundError."""
        gh = MockGitHubReleaseClient()
        with self.assertRaises(FileNotFoundError):
            gh.create_release(
                tag="v1.0.0",
                title="v1.0.0",
                notes="",
                asset_paths=["/path/to/nonexistent_apk_file_9999.apk"]
            )


if __name__ == "__main__":
    unittest.main()
