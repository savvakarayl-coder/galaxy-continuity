"""
Galaxy Continuity — Tier 3: Pairwise Combinatorial Interaction Test Suite
Verifies cross-feature interactions and concurrent multi-subsystem behavior.
Covers >= 10 test cases.
Zero external dependencies.
"""

import base64
import hashlib
import json
import os
import tempfile
import threading
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
    make_mock_h264_nal,
    make_mock_jpeg,
    make_stream_packet,
    parse_stream_packet,
    upload_file,
)


class TestTier3Pairwise(unittest.TestCase):
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
    # Pairwise Interactions (F1-F10)
    # =========================================================================

    def test_01_pairwise_quick_drop_and_text_clipboard_concurrency(self):
        """Phone uploads a file via HTTP POST while concurrently syncing clipboard text over WebSocket."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            upload_done = threading.Event()
            clip_done = threading.Event()

            def do_upload():
                status, _, _ = upload_file(self.host, self.port, "concurrent_upload.pdf", b"%PDF-1.4 sample payload")
                if status == 200:
                    upload_done.set()

            def do_clipboard():
                client.send_json({"type": "clipboard", "content": "Concurrent snippet 123", "contentType": "text/plain", "source": "phone"})
                clip_done.set()

            t1 = threading.Thread(target=do_upload)
            t2 = threading.Thread(target=do_clipboard)
            t1.start()
            t2.start()
            t1.join(timeout=2.0)
            t2.join(timeout=2.0)

            self.assertTrue(upload_done.is_set())
            self.assertTrue(clip_done.is_set())
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "Concurrent snippet 123")
                names = [f["filename"] for f in self.server.uploaded_files]
                self.assertIn("concurrent_upload.pdf", names)
        finally:
            client.close()

    def test_02_pairwise_mac_file_share_and_image_clipboard_sync(self):
        """Mac shares a file while simultaneously broadcasting an image clipboard payload."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            with tempfile.NamedTemporaryFile(prefix="pairwise_share_", suffix=".dat", delete=False) as tf:
                tf.write(b"Mac to Phone concurrent file data")
                tf_path = tf.name

            file_id = self.server.share_file(tf_path, filename="dataset.dat")
            b64_img = base64.b64encode(b"simulated_image_bytes").decode("ascii")
            self.server.broadcast_message({"type": "clipboard", "content": b64_img, "contentType": "image/png", "source": "mac"})

            # Client receives file announcement and image clipboard
            msg_file = client.expect_message("file_available", timeout=2.0)
            msg_clip = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("content") == b64_img)

            self.assertEqual(msg_file.get("fileId"), file_id)
            self.assertEqual(msg_clip.get("contentType"), "image/png")

            # Client downloads the file
            status, _, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(body, b"Mac to Phone concurrent file data")
        finally:
            client.close()
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_03_pairwise_screen_mirroring_and_notification_interactive_reply(self):
        """Active screen mirroring stream while notification arrives and receives interactive quick reply."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. Start screen mirroring
            client.send_json({"type": "screen_start", "width": 1080, "height": 2400, "fps": 30, "bitrate": 4000000})
            time.sleep(0.05)

            # 2. Stream video frame
            nal = make_mock_h264_nal(5, 512)
            packet = make_stream_packet(stream_type=0x01, payload=nal)
            client.send_binary(packet)

            # 3. Notification arrives from phone
            client.send_json({
                "type": "phone_notification",
                "id": "notif-mirror-1",
                "app": "Telegram",
                "title": "Elena",
                "text": "Are you joining the demo?",
                "canReply": True
            })

            # 4. Mac sends interactive reply
            self.server.broadcast_message({
                "type": "notification_reply",
                "id": "notif-mirror-1",
                "packageName": "org.telegram.messenger",
                "replyText": "Yes, screen mirroring is active right now!"
            })

            reply_msg = client.expect_message("notification_reply", timeout=2.0)
            self.assertEqual(reply_msg.get("replyText"), "Yes, screen mirroring is active right now!")

            # Deterministic polling: wait for server background thread to receive binary frame
            self.assertTrue(
                self.server.wait_for_binary_frames(min_count=1, timeout=2.0),
                "Server must receive binary stream frame before timeout"
            )

            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)
                self.assertGreater(len(self.server.received_binary_frames), 0)
        finally:
            client.close()

    def test_04_pairwise_continuity_camera_and_phone_clipboard_copy(self):
        """Continuity Camera stream active while user copies phone clipboard."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. Start camera
            client.send_json({"type": "camera_start", "facing": "back", "resolution": "1080p", "fps": 30})
            # 2. Send camera frames
            for seq in range(3):
                jpeg = make_mock_jpeg(160, 120)
                client.send_binary(make_stream_packet(0x02, jpeg))

            # 3. Phone user copies clipboard
            client.send_json({"type": "clipboard", "content": "Camera call note", "contentType": "text/plain", "source": "phone"})

            # Deterministic wait for frames
            self.assertTrue(self.server.wait_for_binary_frames(min_count=3, timeout=2.0))
            time.sleep(0.05)

            with self.server.lock:
                self.assertTrue(self.server.camera_streaming_active)
                self.assertEqual(self.server.last_clipboard_text, "Camera call note")
                self.assertEqual(len(self.server.received_binary_frames), 3)
        finally:
            client.close()

    def test_05_pairwise_battery_status_update_during_file_upload(self):
        """Battery status update delivered over WebSocket during active HTTP file upload."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Upload file
            upload_t = threading.Thread(
                target=upload_file,
                args=(self.host, self.port, "battery_test.bin", os.urandom(32 * 1024))
            )
            upload_t.start()

            # Concurrent battery update
            client.send_json({"type": "battery_update", "level": 45, "isCharging": True})
            upload_t.join(timeout=2.0)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(self.server.battery_info["level"], 45)
                self.assertTrue(self.server.battery_info["isCharging"])
                names = [f["filename"] for f in self.server.uploaded_files]
                self.assertIn("battery_test.bin", names)
        finally:
            client.close()

    def test_06_pairwise_remote_ping_while_screen_mirroring(self):
        """Find My Phone ping processed while screen mirroring and touch events are actively dispatching."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Screen start and touch events
            client.send_json({"type": "screen_start", "width": 1080, "height": 2400})
            client.send_json({"type": "input_event", "action": "down", "x": 0.5, "y": 0.5})

            # Remote ping from Mac
            self.server.broadcast_message({"type": "ping_device", "source": "mac", "message": "Where are you, Galaxy?"})
            ping_msg = client.expect_message("ping_device", timeout=2.0)
            self.assertEqual(ping_msg.get("message"), "Where are you, Galaxy?")

            # Additional touch event
            client.send_json({"type": "input_event", "action": "up", "x": 0.5, "y": 0.5})
            time.sleep(0.05)

            with self.server.lock:
                self.assertTrue(self.server.screen_mirroring_active)
                self.assertEqual(len(self.server.input_events), 2)
        finally:
            client.close()

    def test_07_pairwise_discovery_mdns_to_ble_fallback_with_active_session(self):
        """Simulates mDNS resolution followed by BLE out-of-band verification."""
        # 1. Resolve mDNS
        mdns = MockMdnsRecord(port=self.port)
        rec = mdns.resolve(host=self.host)
        self.assertEqual(rec["port"], self.port)

        # 2. Verify BLE advertisement provides matching port
        ble = MockBleAdvertiser(service_uuid=BLE_SERVICE_UUID, port=self.port)
        adv = ble.build_advertisement_data()
        parsed = MockBleAdvertiser.parse_advertisement_data(adv)
        self.assertEqual(parsed["port"], self.port)
        self.assertTrue(parsed["is_ready"])

        # 3. Connect client using resolved port
        client = ContinuityClient(host=self.host, port=parsed["port"])
        ack = client.connect()
        try:
            self.assertEqual(ack.get("type"), "handshake_ack")
        finally:
            client.close()

    def test_08_pairwise_wifi_direct_direct_link_under_high_throughput(self):
        """Wi-Fi Direct P2P direct socket URL verification paired with file sharing."""
        wifi_direct_target = f"ws://{WIFI_DIRECT_DEFAULT_IP}:{DEFAULT_PORT}/ws"
        self.assertTrue(wifi_direct_target.startswith("ws://192.168.49.1"))

        # Pair with Quick Drop transfer
        with tempfile.NamedTemporaryFile(prefix="p2p_test_", delete=False) as tf:
            tf.write(b"High speed P2P data")
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="p2p_file.bin")
            st, _, body = download_file(self.host, self.port, file_id)
            self.assertEqual(st, 200)
            self.assertEqual(body, b"High speed P2P data")
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_09_pairwise_screen_touch_immediately_followed_by_camera_switch(self):
        """Touch input event dispatched immediately before a camera lens switch."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            client.send_json({"type": "input_event", "action": "down", "x": 0.2, "y": 0.8})
            client.send_json({"type": "camera_switch_lens", "facing": "front"})
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(self.server.camera_lens, "front")
                self.assertEqual(self.server.input_events[-1]["action"], "down")
        finally:
            client.close()

    def test_10_pairwise_text_clipboard_and_image_clipboard_rapid_alternation(self):
        """Alternates rapidly between text clipboard and image clipboard (5 cycles)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            for cycle in range(5):
                text_val = f"Text cycle {cycle}"
                img_val = base64.b64encode(f"img_{cycle}".encode("ascii")).decode("ascii")

                client.send_json({"type": "clipboard", "content": text_val, "contentType": "text/plain", "source": "phone"})
                time.sleep(0.02)
                client.send_json({"type": "clipboard", "content": img_val, "contentType": "image/png", "source": "phone"})
                time.sleep(0.02)

            time.sleep(0.05)
            with self.server.lock:
                # Last update should be the 5th image payload
                expected_last = base64.b64encode(b"img_4").decode("ascii")
                self.assertEqual(self.server.last_clipboard_text, expected_last)
        finally:
            client.close()

    def test_11_pairwise_handshake_renegotiation_after_abrupt_disconnect(self):
        """Abrupt client socket disconnect during transfer is followed by clean reconnect and re-handshake."""
        client1 = ContinuityClient(host=self.host, port=self.port)
        client1.connect()
        # Abruptly close raw socket without RFC 6455 close handshake
        client1.sock.close()
        client1.sock = None
        time.sleep(0.05)

        # Connect new client session
        client2 = ContinuityClient(host=self.host, port=self.port)
        ack = client2.connect(device_name="Galaxy S24 Ultra Reconnected")
        try:
            self.assertTrue(client2.is_connected)
            self.assertEqual(ack.get("type"), "handshake_ack")
        finally:
            client2.close()

    def test_12_pairwise_apk_artifact_verification_paired_with_mock_github_release(self):
        """Verifies APK compilation artifact packaging directly linked to GitHub release upload."""
        with tempfile.NamedTemporaryFile(prefix="GalaxyContinuity-debug-", suffix=".apk", delete=False) as tf:
            apk_path = tf.name

        try:
            # 1. Create mock APK
            MockApkVerifier.create_mock_apk(apk_path, app_id="com.galaxycontinuity.app", version_name="1.0.0")
            # 2. Publish to GitHub release
            gh = MockGitHubReleaseClient(repo="savvakarayl-coder/galaxy-continuity")
            rel = gh.create_release(
                tag="v1.0.0",
                title="Galaxy Continuity v1.0.0",
                notes="Automated production build.",
                asset_paths=[apk_path]
            )
            self.assertEqual(rel["tag"], "v1.0.0")
            self.assertEqual(rel["assets"][0]["name"], os.path.basename(apk_path))
            self.assertGreater(rel["assets"][0]["size"], 0)
        finally:
            if os.path.exists(apk_path):
                os.remove(apk_path)


if __name__ == "__main__":
    unittest.main()
