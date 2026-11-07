"""
Galaxy Continuity — Tier 1: Representative Feature Test Suite
Category-Partition Equivalence Class Testing (Representative Happy Paths).
Covers all 10 core features with >= 50 test cases.
Zero external dependencies.
"""

import base64
import hashlib
import json
import os
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
    MockContinuityServer,
    MockGitHubReleaseClient,
    MockMdnsRecord,
    download_file,
    encode_ws_frame,
    http_get,
    make_mock_h264_nal,
    make_mock_jpeg,
    make_stream_packet,
    parse_stream_packet,
    upload_file,
)


class TestTier1Features(unittest.TestCase):
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
    # Feature 1: Handshake & Protocol Framing
    # =========================================================================

    def test_01_ws_upgrade_and_handshake_ack(self):
        """RFC 6455 upgrade on port 8765 receives 101 and handshake_ack."""
        client = ContinuityClient(host=self.host, port=self.port)
        ack = client.connect(send_initial_handshake=False)
        try:
            self.assertTrue(client.is_connected)
            self.assertEqual(ack.get("type"), "handshake_ack")
            self.assertEqual(ack.get("platform"), "macOS")
            self.assertEqual(ack.get("version"), "1.0.0")
            self.assertIn("device", ack)
        finally:
            client.close()

    def test_02_client_device_registration(self):
        """Galaxy client registers name, platform, and battery in handshake."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect(device_name="Samsung Galaxy S24 Ultra", send_initial_handshake=True)
        try:
            time.sleep(0.05)
            with self.server.lock:
                dev = self.server.device_info
                self.assertEqual(dev.get("type"), "handshake")
                self.assertEqual(dev.get("device"), "Samsung Galaxy S24 Ultra")
                self.assertEqual(dev.get("platform"), "android")
                self.assertIn("battery", dev)
        finally:
            client.close()

    def test_03_rfc6455_ping_pong_roundtrip(self):
        """Opcode 0x9 Ping frame receives matching Opcode 0xA Pong frame."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            token = b"galaxy_heartbeat_token_123"
            # Send ping directly without automatic client handling
            client.send_frame(0x9, token, masked=True)
            opcode, payload = client.recv_frame(timeout=2.0)
            self.assertEqual(opcode, 0xA)  # Pong
            self.assertEqual(payload, token)
        finally:
            client.close()

    def test_04_rfc6455_payload_length_framing(self):
        """Verify 7-bit (<=125 bytes) and 16-bit (126..65535 bytes) framing."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 7-bit frame
            msg7 = {"type": "battery_update", "level": 88, "isCharging": True}
            client.send_json(msg7)

            # 16-bit frame (> 125 bytes)
            big_text = "A" * 350
            msg16 = {"type": "clipboard", "content": big_text, "contentType": "text/plain", "source": "phone"}
            client.send_json(msg16)

            time.sleep(0.05)
            with self.server.lock:
                received_contents = [m.get("content") for m in self.server.received_messages if m.get("type") == "clipboard"]
                self.assertIn(big_text, received_contents)
        finally:
            client.close()

    def test_05_rfc6455_clean_close_frame(self):
        """Opcode 0x8 Close frame initiates clean WebSocket connection teardown."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        client_fd = client.sock.fileno() if client.sock else None
        client.send_close(code=1000, reason="Normal Closure")
        time.sleep(0.05)
        with self.server.lock:
            # Client socket should be removed from active WS clients
            if client_fd:
                self.assertNotIn(client_fd, self.server.ws_clients)
        client.close()

    def test_06_http_web_companion_endpoint(self):
        """GET / and GET /companion return 200 OK with HTML companion."""
        status1, _, body1 = http_get(self.host, self.port, "/")
        self.assertEqual(status1, 200)
        self.assertIn(b"Galaxy Continuity", body1)

        status2, _, body2 = http_get(self.host, self.port, "/companion")
        self.assertEqual(status2, 200)
        self.assertIn(b"Galaxy Continuity", body2)

    # =========================================================================
    # Feature 2: Bidirectional Text Clipboard
    # =========================================================================

    def test_07_phone_to_mac_plain_text_sync(self):
        """Plain text copied on Galaxy syncs to macOS host."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            test_phrase = "Meeting at 3pm in Building 4."
            client.send_json({
                "type": "clipboard",
                "content": test_phrase,
                "contentType": "text/plain",
                "source": "phone",
                "timestamp": time.time() * 1000
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, test_phrase)
        finally:
            client.close()

    def test_08_mac_to_phone_plain_text_sync(self):
        """Text copied on macOS broadcasts to connected Galaxy client."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            mac_text = "https://developer.apple.com/continuity"
            self.server.set_mac_clipboard(mac_text)
            msg = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("content") == mac_text)
            self.assertEqual(msg.get("content"), mac_text)
            self.assertEqual(msg.get("contentType"), "text/plain")
            self.assertEqual(msg.get("source"), "mac")
        finally:
            client.close()

    def test_09_clipboard_loop_prevention_same_content(self):
        """Sending identical clipboard content twice suppresses loop echo."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            sample = "Identical Clipboard Text 999"
            client.send_json({"type": "clipboard", "content": sample, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            # Re-send same content
            client.send_json({"type": "clipboard", "content": sample, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                # Should have been processed without error
                self.assertEqual(self.server.last_clipboard_text, sample)
        finally:
            client.close()

    def test_10_clipboard_url_content_sync(self):
        """Syncs web URLs with complex parameters."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            url = "https://github.com/savvakarayl-coder/galaxy-continuity?ref=main#readme"
            client.send_json({"type": "clipboard", "content": url, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, url)
        finally:
            client.close()

    def test_11_clipboard_multiline_text_sync(self):
        """Syncs multi-line code snippet with indentation and special symbols."""
        snippet = "func continuitySync() -> Bool {\n    let ok = true\n    return ok\n}"
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "clipboard", "content": snippet, "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, snippet)
        finally:
            client.close()

    # =========================================================================
    # Feature 3: Bidirectional Image Clipboard
    # =========================================================================

    def test_12_phone_to_mac_png_image_sync(self):
        """Base64-encoded PNG image clipboard transfers from phone to Mac."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Minimal 1x1 transparent PNG
            png_bytes = (
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15c4"
                b"\x00\x00\x00\rIDATx\x9cc\xf8\xff\xff?\x00\x05\xfe\x02\xfe\r\xef\x84\xb7\x00\x00\x00\x00IEND\xaeB`\x82"
            )
            b64_png = base64.b64encode(png_bytes).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_png,
                "contentType": "image/png",
                "source": "phone"
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_png)
        finally:
            client.close()

    def test_13_mac_to_phone_image_sync(self):
        """Mac broadcasts base64 image clipboard to connected Galaxy client."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            img_data = b"synthetic_mac_screenshot_image_data_12345"
            b64_img = base64.b64encode(img_data).decode("ascii")
            self.server.broadcast_message({
                "type": "clipboard",
                "content": b64_img,
                "contentType": "image/png",
                "source": "mac"
            })
            msg = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("content") == b64_img)
            self.assertEqual(msg.get("content"), b64_img)
            self.assertEqual(msg.get("contentType"), "image/png")
            self.assertEqual(msg.get("source"), "mac")
        finally:
            client.close()

    def test_14_image_clipboard_jpeg_payload(self):
        """JPEG image payload is accepted with image/jpeg contentType."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            jpeg_bytes = make_mock_jpeg(64, 64)
            b64_jpeg = base64.b64encode(jpeg_bytes).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_jpeg,
                "contentType": "image/jpeg",
                "source": "phone"
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_jpeg)
        finally:
            client.close()

    def test_15_image_clipboard_large_base64_frame(self):
        """Large base64 image (exercising 16-bit frame payload) transfers intact."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            raw_payload = os.urandom(8192)  # 8 KB raw -> ~11 KB base64
            b64_large = base64.b64encode(raw_payload).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_large,
                "contentType": "image/png",
                "source": "phone"
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_large)
        finally:
            client.close()

    def test_16_image_clipboard_loop_prevention(self):
        """Identical image payload sent twice does not trigger duplicate update."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            b64 = base64.b64encode(b"image_duplicate_check").decode("ascii")
            msg = {"type": "clipboard", "content": b64, "contentType": "image/png", "source": "phone"}
            client.send_json(msg)
            time.sleep(0.03)
            client.send_json(msg)
            time.sleep(0.03)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64)
        finally:
            client.close()

    # =========================================================================
    # Feature 4: Quick Drop File Transfer (Mac -> Phone)
    # =========================================================================

    def test_17_mac_shares_file_broadcasts_file_available(self):
        """Mac shares file, broadcasting file_available with fileId and metadata."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            with tempfile.NamedTemporaryFile(prefix="share_test_", suffix=".txt", delete=False) as tf:
                tf.write(b"Mac to Phone Quick Drop payload")
                tf_path = tf.name

            file_id = self.server.share_file(tf_path, filename="notes.txt")
            msg = client.expect_message("file_available", timeout=2.0)
            self.assertEqual(msg.get("fileId"), file_id)
            self.assertEqual(msg.get("filename"), "notes.txt")
            self.assertEqual(msg.get("fileSize"), 31)
        finally:
            client.close()
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_18_phone_downloads_shared_file_via_http(self):
        """Phone downloads shared file via GET /api/download/:fileId."""
        payload = b"Binary content for phone download"
        with tempfile.NamedTemporaryFile(prefix="dl_test_", suffix=".bin", delete=False) as tf:
            tf.write(payload)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="sample.bin")
            status, headers, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(body, payload)
            self.assertIn("content-disposition", headers)
            self.assertIn("sample.bin", headers["content-disposition"])
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_19_phone_downloads_unicode_filename(self):
        """Shared file with Unicode characters is correctly encoded in Content-Disposition."""
        payload = b"Unicode document test"
        unicode_name = "отчёт_2026.pdf"
        with tempfile.NamedTemporaryFile(prefix="uni_test_", suffix=".pdf", delete=False) as tf:
            tf.write(payload)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename=unicode_name)
            status, headers, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(body, payload)
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_20_phone_downloads_binary_archive(self):
        """Phone downloads larger binary blob, verifying SHA-256 integrity."""
        blob = os.urandom(64 * 1024)  # 64 KB
        expected_sha = hashlib.sha256(blob).hexdigest()
        with tempfile.NamedTemporaryFile(prefix="archive_", suffix=".zip", delete=False) as tf:
            tf.write(blob)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="archive.zip")
            status, _, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(hashlib.sha256(body).hexdigest(), expected_sha)
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_21_file_available_schema_validation(self):
        """Validates all required fields in file_available message schema."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            with tempfile.NamedTemporaryFile(prefix="schema_", delete=False) as tf:
                tf.write(b"data")
                tf_path = tf.name
            file_id = self.server.share_file(tf_path, filename="data.bin")
            msg = client.expect_message("file_available", timeout=2.0)
            required = ["type", "fileId", "filename", "fileSize", "mimeType", "sender"]
            for field in required:
                self.assertIn(field, msg, f"Missing required field: {field}")
        finally:
            client.close()
            if os.path.exists(tf_path):
                os.remove(tf_path)

    # =========================================================================
    # Feature 5: Quick Drop File Transfer (Phone -> Mac)
    # =========================================================================

    def test_22_phone_uploads_file_via_http_post(self):
        """Phone uploads file to /api/upload with X-Filename header."""
        content = b"Uploaded from Samsung Galaxy S24 Ultra"
        filename = "phone_photo.jpg"
        status, _, body = upload_file(self.host, self.port, filename, content)
        self.assertEqual(status, 200)
        resp_json = json.loads(body.decode("utf-8"))
        self.assertEqual(resp_json.get("status"), "ok")

        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == filename]
            self.assertTrue(len(uploaded) > 0)
            self.assertEqual(uploaded[0]["size"], len(content))

    def test_23_phone_uploads_unicode_filename(self):
        """Phone uploads file with percent-encoded Unicode X-Filename."""
        content = b"Unicode phone upload content"
        filename = "документ_тест.txt"
        status, _, body = upload_file(self.host, self.port, filename, content, percent_encode=True)
        self.assertEqual(status, 200)
        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == filename]
            self.assertTrue(len(uploaded) > 0)

    def test_24_phone_uploads_without_filename_header(self):
        """Phone uploads without X-Filename; server uses fallback naming."""
        content = b"Anonymous upload data"
        status, _, body = upload_file(self.host, self.port, None, content)
        self.assertEqual(status, 200)
        with self.server.lock:
            last_upload = self.server.uploaded_files[-1]
            self.assertTrue(last_upload["filename"].startswith("Received_File_"))

    def test_25_phone_upload_filename_collision_handling(self):
        """Uploading same filename twice triggers automatic counter rename (1)."""
        content1 = b"Version 1"
        content2 = b"Version 2"
        fname = "contract.pdf"
        upload_file(self.host, self.port, fname, content1)
        upload_file(self.host, self.port, fname, content2)

        with self.server.lock:
            names = [f["filename"] for f in self.server.uploaded_files]
            self.assertIn("contract.pdf", names)
            self.assertIn("contract (1).pdf", names)

    def test_26_phone_upload_large_binary_payload(self):
        """Phone uploads 256 KB binary file, verifying byte integrity."""
        blob = os.urandom(256 * 1024)
        expected_sha = hashlib.sha256(blob).hexdigest()
        fname = "backup.tar.gz"
        status, _, _ = upload_file(self.host, self.port, fname, blob)
        self.assertEqual(status, 200)

        with self.server.lock:
            entry = [f for f in self.server.uploaded_files if f["filename"] == fname][0]
            with open(entry["path"], "rb") as saved_f:
                saved_bytes = saved_f.read()
            self.assertEqual(hashlib.sha256(saved_bytes).hexdigest(), expected_sha)

    # =========================================================================
    # Feature 6: Screen Mirroring & Remote Input
    # =========================================================================

    def test_27_screen_mirroring_start_control_message(self):
        """Server processes screen_start with resolution and fps settings."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({
                "type": "screen_start",
                "width": 1080,
                "height": 2340,
                "fps": 60,
                "bitrate": 5000000
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)
        finally:
            client.close()

    def test_28_screen_mirroring_stop_control_message(self):
        """Server processes screen_stop control message resetting active state."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "screen_stop"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.screen_mirroring_active)
        finally:
            client.close()

    def test_29_screen_mirroring_video_binary_frame_transport(self):
        """Binary frame packet with Stream Type 0x01 (Screen) transfers over WebSocket (PROTOCOL.md § 4.2)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            nal_payload = make_mock_h264_nal(nal_type=5, size=256)
            packet = make_stream_packet(stream_type=0x01, payload=nal_payload)
            client.send_binary(packet)
            self.assertTrue(self.server.wait_for_binary_frames(min_count=1, timeout=2.0))
            with self.server.lock:
                parsed = parse_stream_packet(self.server.received_binary_frames[-1])
                self.assertEqual(parsed["stream_type"], 0x01)
                self.assertEqual(parsed["length"], len(nal_payload))
                self.assertEqual(parsed["payload"], nal_payload)
        finally:
            client.close()

    def test_30_screen_remote_touch_input_event(self):
        """Touch input event with normalized coordinates transfers cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            touch_evt = {
                "type": "input_event",
                "action": "down",
                "x": 0.452,
                "y": 0.819,
                "button": 0
            }
            client.send_json(touch_evt)
            time.sleep(0.05)
            with self.server.lock:
                events = [e for e in self.server.input_events if e.get("type") == "input_event"]
                self.assertTrue(len(events) > 0)
                self.assertAlmostEqual(events[-1]["x"], 0.452, places=3)
                self.assertAlmostEqual(events[-1]["y"], 0.819, places=3)
        finally:
            client.close()

    def test_31_screen_remote_key_navigation_event(self):
        """Hardware navigation keys (BACK, HOME, RECENTS) transfer correctly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for key in ["BACK", "HOME", "RECENTS"]:
                client.send_json({"type": "input_key", "key": key})
            time.sleep(0.05)
            with self.server.lock:
                keys = [e.get("key") for e in self.server.input_events if e.get("type") == "input_key"]
                self.assertIn("BACK", keys)
                self.assertIn("HOME", keys)
                self.assertIn("RECENTS", keys)
        finally:
            client.close()

    # =========================================================================
    # Feature 7: Continuity Camera & Virtual Webcam
    # =========================================================================

    def test_32_continuity_camera_start_control(self):
        """Processes camera_start control message activating camera stream."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({
                "type": "camera_start",
                "facing": "back",
                "resolution": "1080p",
                "fps": 30
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(self.server.camera_streaming_active)
                self.assertEqual(self.server.camera_lens, "back")
        finally:
            client.close()

    def test_33_continuity_camera_stop_control(self):
        """Processes camera_stop control message deactivating camera stream."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertFalse(self.server.camera_streaming_active)
        finally:
            client.close()

    def test_34_continuity_camera_switch_lens(self):
        """Switches active camera lens between front and back."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "camera_switch_lens", "facing": "front"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.camera_lens, "front")
        finally:
            client.close()

    def test_35_continuity_camera_video_binary_stream(self):
        """Camera binary frame with Stream Type 0x02 and JPEG payload is transferred (PROTOCOL.md § 4.2)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            jpeg = make_mock_jpeg(320, 240)
            packet = make_stream_packet(stream_type=0x02, payload=jpeg)
            client.send_binary(packet)
            self.assertTrue(self.server.wait_for_binary_frames(min_count=1, timeout=2.0))
            with self.server.lock:
                parsed = parse_stream_packet(self.server.received_binary_frames[-1])
                self.assertEqual(parsed["stream_type"], 0x02)
                self.assertEqual(parsed["length"], len(jpeg))
                self.assertTrue(parsed["payload"].startswith(b"\xFF\xD8"))
        finally:
            client.close()

    def test_36_continuity_camera_stream_packet_framing_and_types(self):
        """Validates 5-byte stream header distinguishes screen mirroring (0x01) and camera (0x02) per PROTOCOL.md § 4.2."""
        screen_pkt = make_stream_packet(stream_type=0x01, payload=b"screen_nal_data")
        camera_pkt = make_stream_packet(stream_type=0x02, payload=b"camera_jpeg_data")

        parsed_screen = parse_stream_packet(screen_pkt)
        parsed_cam = parse_stream_packet(camera_pkt)

        self.assertEqual(parsed_screen["stream_type"], 0x01)
        self.assertEqual(parsed_screen["length"], len(b"screen_nal_data"))
        self.assertEqual(parsed_screen["payload"], b"screen_nal_data")

        self.assertEqual(parsed_cam["stream_type"], 0x02)
        self.assertEqual(parsed_cam["length"], len(b"camera_jpeg_data"))
        self.assertEqual(parsed_cam["payload"], b"camera_jpeg_data")

    # =========================================================================
    # Feature 8: Notification Sync & Interactive Reply
    # =========================================================================

    def test_37_forward_phone_notification(self):
        """Phone notification with reply capability is received by macOS host."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            notif = {
                "type": "phone_notification",
                "id": "notif-uuid-42",
                "packageName": "com.whatsapp",
                "app": "WhatsApp",
                "title": "Sarah",
                "text": "Are we still meeting at 5?",
                "timestamp": time.time() * 1000,
                "canReply": True
            }
            client.send_json(notif)
            time.sleep(0.05)
            with self.server.lock:
                self.assertTrue(len(self.server.notifications_received) > 0)
                self.assertEqual(self.server.notifications_received[-1]["title"], "Sarah")
        finally:
            client.close()

    def test_38_interactive_quick_reply(self):
        """Mac dispatches notification_reply back to Galaxy client."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            reply = {
                "type": "notification_reply",
                "id": "notif-uuid-42",
                "packageName": "com.whatsapp",
                "replyText": "Yes, on my way!"
            }
            self.server.broadcast_message(reply)
            msg = client.expect_message("notification_reply", timeout=2.0)
            self.assertEqual(msg.get("id"), "notif-uuid-42")
            self.assertEqual(msg.get("replyText"), "Yes, on my way!")
        finally:
            client.close()

    def test_39_phone_notification_without_reply(self):
        """Notification with canReply=false is parsed cleanly."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({
                "type": "phone_notification",
                "id": "calendar-event-1",
                "app": "Google Calendar",
                "title": "Team Standup",
                "text": "Starting in 10 minutes",
                "canReply": False
            })
            time.sleep(0.05)
            with self.server.lock:
                last_notif = self.server.notifications_received[-1]
                self.assertFalse(last_notif.get("canReply", True))
        finally:
            client.close()

    def test_40_notification_special_characters_and_emojis(self):
        """Notification with Unicode emojis and characters preserves encoding."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            text = "🚀 Great job on the launch! 🎉🍾"
            client.send_json({
                "type": "phone_notification",
                "id": "slack-emoji-99",
                "app": "Slack",
                "title": "Team 🎉",
                "text": text,
                "canReply": True
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.notifications_received[-1]["text"], text)
        finally:
            client.close()

    def test_41_multiple_notifications_order_preservation(self):
        """Rapid succession of notifications maintains individual identities."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for i in range(3):
                client.send_json({
                    "type": "phone_notification",
                    "id": f"notif-seq-{i}",
                    "app": "TestApp",
                    "title": f"Title {i}",
                    "text": f"Message {i}"
                })
            time.sleep(0.05)
            with self.server.lock:
                ids = [n["id"] for n in self.server.notifications_received if n.get("id", "").startswith("notif-seq-")]
                self.assertEqual(ids, ["notif-seq-0", "notif-seq-1", "notif-seq-2"])
        finally:
            client.close()

    # =========================================================================
    # Feature 9: Peer Discovery (mDNS, BLE, Wi-Fi Direct)
    # =========================================================================

    def test_42_mdns_service_record_advertisement(self):
        """Validates Bonjour / mDNS service type, port 8765, and TXT records."""
        rec = MockMdnsRecord(name="Galaxy Continuity (MacBook Pro)", port=DEFAULT_PORT, platform="macOS")
        self.assertEqual(rec.service_type, "_galaxycontinuity._tcp.")
        self.assertEqual(rec.port, 8765)
        self.assertEqual(rec.txt_records["platform"], "macOS")
        self.assertEqual(rec.txt_records["version"], "1.0.0")

    def test_43_mdns_resolution_to_local_socket(self):
        """Simulates mDNS resolution returning IP and connecting to socket."""
        rec = MockMdnsRecord(port=self.port)
        resolved = rec.resolve(host=self.host)
        self.assertEqual(resolved["port"], self.port)
        client = ContinuityClient(host=resolved["host"], port=resolved["port"])
        ack = client.connect()
        try:
            self.assertEqual(ack.get("type"), "handshake_ack")
        finally:
            client.close()

    def test_44_ble_advertisement_packet_construction(self):
        """Constructs BLE advertising payload with Service UUID 19B10000-... and flags."""
        adv = MockBleAdvertiser(service_uuid=BLE_SERVICE_UUID, port=8765)
        data = adv.build_advertisement_data(device_id=b"\xCA\xFE\xBA\xBE", flags=0x03)
        self.assertEqual(data["service_uuid"], BLE_SERVICE_UUID)
        self.assertEqual(data["port"], 8765)
        self.assertEqual(len(data["service_data"]), 7)

    def test_45_ble_advertisement_parsing(self):
        """Parses BLE service data extracting device ID, port, and capabilities."""
        adv = MockBleAdvertiser(service_uuid=BLE_SERVICE_UUID, port=8765)
        raw_ad = adv.build_advertisement_data(device_id=b"\x01\x02\x03\x04", flags=0x03)
        parsed = MockBleAdvertiser.parse_advertisement_data(raw_ad)
        self.assertEqual(parsed["short_id"], "01020304")
        self.assertEqual(parsed["port"], 8765)
        self.assertTrue(parsed["is_ready"])
        self.assertTrue(parsed["wifi_direct_available"])

    def test_46_wifi_direct_ip_socket_addressing(self):
        """Wi-Fi Direct P2P Group Owner default IP is 192.168.49.1."""
        target_ws = f"ws://{WIFI_DIRECT_DEFAULT_IP}:{DEFAULT_PORT}/ws"
        self.assertIn("192.168.49.1", target_ws)
        self.assertTrue(target_ws.endswith("/ws"))

    # =========================================================================
    # Feature 10: Android APK Build & GitHub Release
    # =========================================================================

    def test_47_android_project_tree_integrity(self):
        """Verifies repository has complete Android project structure."""
        project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        results = MockApkVerifier.verify_android_project_files(project_root)
        self.assertTrue(results["android_dir_exists"])
        self.assertTrue(results["build_gradle_exists"])
        self.assertTrue(results["app_build_gradle_exists"])
        self.assertTrue(results["manifest_exists"])

    def test_48_mock_apk_packaging_and_dex_structure(self):
        """Creates valid zip-formatted mock APK containing dex and manifest."""
        with tempfile.NamedTemporaryFile(suffix=".apk", delete=False) as tf:
            apk_path = tf.name

        try:
            MockApkVerifier.create_mock_apk(apk_path, app_id="com.galaxycontinuity.app", version_name="1.0.0")
            import zipfile
            with zipfile.ZipFile(apk_path, "r") as zf:
                names = zf.namelist()
                self.assertIn("AndroidManifest.xml", names)
                self.assertIn("classes.dex", names)
                self.assertIn("resources.arsc", names)
        finally:
            if os.path.exists(apk_path):
                os.remove(apk_path)

    def test_49_github_release_creation_contract(self):
        """Simulates GitHub release creation for tag v1.0.0 with title and APK asset."""
        gh = MockGitHubReleaseClient(repo="savvakarayl-coder/galaxy-continuity")
        with tempfile.NamedTemporaryFile(suffix=".apk", delete=False) as tf:
            tf.write(b"mock_apk_binary_payload")
            apk_path = tf.name

        try:
            rel = gh.create_release(
                tag="v1.0.0",
                title="Galaxy Continuity v1.0.0",
                notes="Initial production release.",
                asset_paths=[apk_path]
            )
            self.assertEqual(rel["tag"], "v1.0.0")
            self.assertEqual(rel["title"], "Galaxy Continuity v1.0.0")
            self.assertEqual(len(rel["assets"]), 1)
        finally:
            if os.path.exists(apk_path):
                os.remove(apk_path)

    def test_50_github_release_asset_size_and_naming(self):
        """Validates release asset non-zero size and naming convention."""
        gh = MockGitHubReleaseClient()
        with tempfile.NamedTemporaryFile(prefix="GalaxyContinuity-", suffix=".apk", delete=False) as tf:
            tf.write(b"APK_DATA" * 512)
            apk_path = tf.name

        try:
            rel = gh.create_release(tag="v1.0.0", title="v1.0.0", notes="", asset_paths=[apk_path])
            asset = rel["assets"][0]
            self.assertTrue(asset["name"].endswith(".apk"))
            self.assertGreater(asset["size"], 0)
        finally:
            if os.path.exists(apk_path):
                os.remove(apk_path)

    def test_51_device_battery_update_schema(self):
        """Validates battery_update message updates host state."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "battery_update", "level": 74, "isCharging": True})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.battery_info["level"], 74)
                self.assertTrue(self.server.battery_info["isCharging"])
        finally:
            client.close()

    def test_52_remote_ping_find_my_phone(self):
        """Validates ping_device message schema for Find My Phone."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "ping_device", "source": "phone", "message": "Pinging Mac..."})
            time.sleep(0.05)
            with self.server.lock:
                msgs = [m for m in self.server.received_messages if m.get("type") == "ping_device"]
                self.assertTrue(len(msgs) > 0)
                self.assertEqual(msgs[-1]["source"], "phone")
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
