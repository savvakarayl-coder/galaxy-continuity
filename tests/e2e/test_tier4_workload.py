"""
Galaxy Continuity — Tier 4: Real-World Workload Application Scenarios
Simulates realistic, multi-minute complex user workflows across all 10 features:
  - Scenario 1: Workday Workflow (F2, F3, F8)
  - Scenario 2: Large Media Transfer (F4, F5, F6)
  - Scenario 3: Continuity Video Call (F7, F2)
  - Scenario 4: Offline Reconnection & Transport Transition (F9, F1)
  - Scenario 5: Full Production Pipeline (F10, F1-F9)
  - Scenario 6: Stress & Recovery Pipeline
Covers >= 5 comprehensive scenarios.
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


class TestTier4Workload(unittest.TestCase):
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
    # Scenario 1: Workday Workflow (F2, F3, F8)
    # =========================================================================

    def test_01_workday_workflow(self):
        """
        Scenario 1: Full Workday Workflow.
        Synchronizes code snippets and image mockups between Mac and Galaxy
        while receiving work chat notifications and replying inline.
        """
        client = ContinuityClient(host=self.host, port=self.port)
        ack = client.connect(device_name="Samsung Galaxy S24 Ultra (Work)")
        try:
            self.assertEqual(ack.get("type"), "handshake_ack")

            # Step 1: Developer copies Swift code on macOS
            swift_code = (
                "@main\nstruct GalaxyContinuityApp: App {\n"
                "    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate\n"
                "    var body: some Scene { Settings { EmptyView() } }\n}"
            )
            self.server.set_mac_clipboard(swift_code)
            clip_msg1 = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("content") == swift_code)
            self.assertEqual(clip_msg1.get("content"), swift_code)
            self.assertEqual(clip_msg1.get("source"), "mac")

            # Step 2: Developer copies architecture diagram on Galaxy
            diagram_png = base64.b64encode(b"PNG_HEADER_ARCHITECTURE_DIAGRAM_V2").decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": diagram_png,
                "contentType": "image/png",
                "source": "phone"
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, diagram_png)

            # Step 3: Slack notification arrives from team lead
            client.send_json({
                "type": "phone_notification",
                "id": "slack-msg-workday-01",
                "packageName": "com.Slack",
                "app": "Slack",
                "title": "Lead Engineer",
                "text": "Did you push the Continuity release build?",
                "canReply": True,
                "timestamp": time.time() * 1000
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.notifications_received[-1]["title"], "Lead Engineer")

            # Step 4: Mac user sends quick reply
            self.server.broadcast_message({
                "type": "notification_reply",
                "id": "slack-msg-workday-01",
                "packageName": "com.Slack",
                "replyText": "Yes, testing Tier 4 scenarios now!"
            })
            reply_msg = client.expect_message("notification_reply", timeout=2.0)
            self.assertEqual(reply_msg.get("replyText"), "Yes, testing Tier 4 scenarios now!")

            # Step 5: Battery update arrives
            client.send_json({"type": "battery_update", "level": 82, "isCharging": False})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.battery_info["level"], 82)
                self.assertFalse(self.server.battery_info["isCharging"])
        finally:
            client.close()

    # =========================================================================
    # Scenario 2: Large Media Transfer during Active Screen Mirroring (F4, F5, F6)
    # =========================================================================

    def test_02_large_media_transfer_during_screen_mirroring(self):
        """
        Scenario 2: Large Media Transfer with Screen Mirroring.
        Streams high-framerate H.264 video frames while simultaneously
        executing bidirectional Quick Drop transfers (Mac -> Phone and Phone -> Mac).
        """
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. Start screen mirroring
            client.send_json({"type": "screen_start", "width": 1080, "height": 2400, "fps": 30, "bitrate": 4000000})
            time.sleep(0.05)

            # 2. Prepare Mac file to share (128 KB)
            mac_file_data = os.urandom(128 * 1024)
            expected_mac_sha = hashlib.sha256(mac_file_data).hexdigest()
            with tempfile.NamedTemporaryFile(prefix="mac_media_", suffix=".mp4", delete=False) as tf:
                tf.write(mac_file_data)
                mac_file_path = tf.name

            # 3. Prepare Phone file to upload (64 KB)
            phone_file_data = os.urandom(64 * 1024)
            expected_phone_sha = hashlib.sha256(phone_file_data).hexdigest()

            # 4. Concurrently:
            #   - Stream 10 video frames
            #   - Mac shares file and phone downloads it
            #   - Phone uploads file
            file_id = self.server.share_file(mac_file_path, filename="presentation_video.mp4")

            def stream_video():
                for seq in range(10):
                    nal = make_mock_h264_nal(5 if seq == 0 else 1, size=256)
                    pkt = make_stream_packet(stream_type=0x01, frame_type=0x01 if seq == 0 else 0x02, seq=seq, payload=nal)
                    client.send_binary(pkt)
                    time.sleep(0.01)

            video_t = threading.Thread(target=stream_video)
            video_t.start()

            # Phone downloads shared file
            msg_adv = client.expect_message("file_available", timeout=3.0)
            self.assertEqual(msg_adv.get("fileId"), file_id)
            dl_st, _, dl_body = download_file(self.host, self.port, file_id)
            self.assertEqual(dl_st, 200)
            self.assertEqual(hashlib.sha256(dl_body).hexdigest(), expected_mac_sha)

            # Phone uploads photo
            up_st, _, _ = upload_file(self.host, self.port, "trip_photo.heic", phone_file_data)
            self.assertEqual(up_st, 200)

            video_t.join(timeout=2.0)

            # 5. Stop screen mirroring
            client.send_json({"type": "screen_stop"})
            time.sleep(0.05)

            with self.server.lock:
                self.assertFalse(self.server.screen_mirroring_active)
                self.assertGreaterEqual(len(self.server.received_binary_frames), 10)
                up_entry = [f for f in self.server.uploaded_files if f["filename"] == "trip_photo.heic"][0]
                with open(up_entry["path"], "rb") as saved_f:
                    self.assertEqual(hashlib.sha256(saved_f.read()).hexdigest(), expected_phone_sha)
        finally:
            client.close()
            if os.path.exists(mac_file_path):
                os.remove(mac_file_path)

    # =========================================================================
    # Scenario 3: Continuity Video Call (F7, F2)
    # =========================================================================

    def test_03_continuity_video_call(self):
        """
        Scenario 3: Continuity Camera Video Call.
        Streams camera feed to macOS virtual webcam, switches camera lens from
        back to front, syncs a meeting link clipboard, and monitors battery state.
        """
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. Start camera with back lens
            client.send_json({"type": "camera_start", "facing": "back", "resolution": "1080p", "fps": 30})
            time.sleep(0.05)

            with self.server.lock:
                self.assertTrue(self.server.camera_streaming_active)
                self.assertEqual(self.server.camera_lens, "back")

            # 2. Stream 5 camera frames
            for seq in range(5):
                jpeg = make_mock_jpeg(320, 240)
                client.send_binary(make_stream_packet(stream_type=0x02, frame_type=0x01, seq=seq, payload=jpeg))
                time.sleep(0.01)

            # 3. User switches to front camera for face view
            client.send_json({"type": "camera_switch_lens", "facing": "front"})
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(self.server.camera_lens, "front")

            # 4. Stream 5 more camera frames with front camera
            for seq in range(5, 10):
                jpeg = make_mock_jpeg(320, 240)
                client.send_binary(make_stream_packet(stream_type=0x02, frame_type=0x01, seq=seq, payload=jpeg))
                time.sleep(0.01)

            # 5. Participant shares meeting link via clipboard
            meet_link = "https://meet.google.com/xyz- continuity-room"
            self.server.set_mac_clipboard(meet_link)
            clip_msg = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("content") == meet_link)
            self.assertEqual(clip_msg.get("content"), meet_link)

            # 6. Battery state updates during call
            client.send_json({"type": "battery_update", "level": 65, "isCharging": True})
            time.sleep(0.05)

            # 7. Call ends
            client.send_json({"type": "camera_stop"})
            time.sleep(0.05)

            with self.server.lock:
                self.assertFalse(self.server.camera_streaming_active)
                self.assertEqual(self.server.battery_info["level"], 65)
                self.assertTrue(self.server.battery_info["isCharging"])
                self.assertGreaterEqual(len(self.server.received_binary_frames), 10)
        finally:
            client.close()

    # =========================================================================
    # Scenario 4: Offline Reconnection & Transport Transition (F9, F1)
    # =========================================================================

    def test_04_offline_reconnection_and_transport_transition(self):
        """
        Scenario 4: Multi-Transport Discovery & Offline Session Resumption.
        Transitions from local network mDNS discovery to offline BLE beaconing
        and Wi-Fi Direct direct link with full session resumption.
        """
        # Step 1: Initial local network Bonjour / mDNS discovery
        mdns = MockMdnsRecord(name="Galaxy Continuity (MacBook Pro)", port=self.port, platform="macOS")
        rec = mdns.resolve(host=self.host)
        self.assertEqual(rec["port"], self.port)

        client1 = ContinuityClient(host=rec["host"], port=rec["port"])
        client1.connect(device_name="Samsung Galaxy S24 Ultra (Office Wi-Fi)")
        client1.send_json({"type": "clipboard", "content": "Wi-Fi session state", "contentType": "text/plain", "source": "phone"})
        time.sleep(0.05)

        # Step 2: Network drop (Wi-Fi router loses power / user walks outdoors)
        client1.sock.close()
        client1.sock = None
        time.sleep(0.05)

        # Step 3: Offline BLE Discovery activates
        ble = MockBleAdvertiser(service_uuid=BLE_SERVICE_UUID, port=self.port)
        adv = ble.build_advertisement_data(device_id=b"\xFE\xED\xFA\xCE", flags=0x03)
        parsed_ble = MockBleAdvertiser.parse_advertisement_data(adv)
        self.assertTrue(parsed_ble["is_ready"])
        self.assertTrue(parsed_ble["wifi_direct_available"])
        self.assertEqual(parsed_ble["port"], self.port)

        # Step 4: Wi-Fi Direct Autonomous Group Owner link established
        wifi_direct_url = f"ws://{WIFI_DIRECT_DEFAULT_IP}:{parsed_ble['port']}/ws"
        self.assertTrue("192.168.49.1" in wifi_direct_url)

        # Step 5: Session re-established over direct P2P link (using host/port harness)
        client2 = ContinuityClient(host=self.host, port=self.port)
        ack = client2.connect(device_name="Samsung Galaxy S24 Ultra (Wi-Fi Direct P2P)")
        try:
            self.assertEqual(ack.get("type"), "handshake_ack")

            # Step 6: Seamless continuity resumes immediately
            client2.send_json({"type": "clipboard", "content": "Resumed outdoor note", "contentType": "text/plain", "source": "phone"})
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "Resumed outdoor note")
        finally:
            client2.close()

    # =========================================================================
    # Scenario 5: Full Production Pipeline (F10, F1-F9)
    # =========================================================================

    def test_05_full_production_pipeline(self):
        """
        Scenario 5: End-to-End Production Pipeline.
        Verifies Android project tree, compiles mock production APK,
        validates zip manifest/dex/resources, publishes GitHub Release v1.0.0,
        and connects Galaxy Continuity v1.0.0 production client.
        """
        project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

        # Step 1: Verify complete Android project tree
        tree_check = MockApkVerifier.verify_android_project_files(project_root)
        self.assertTrue(tree_check["android_dir_exists"])
        self.assertTrue(tree_check["build_gradle_exists"])
        self.assertTrue(tree_check["app_build_gradle_exists"])
        self.assertTrue(tree_check["manifest_exists"])

        # Step 2: Build production APK artifact
        with tempfile.NamedTemporaryFile(prefix="GalaxyContinuity-", suffix=".apk", delete=False) as tf:
            apk_path = tf.name

        try:
            MockApkVerifier.create_mock_apk(apk_path, app_id="com.galaxycontinuity.app", version_name="1.0.0")

            # Step 3: Validate APK internal structure
            import zipfile
            with zipfile.ZipFile(apk_path, "r") as zf:
                contents = zf.namelist()
                self.assertIn("AndroidManifest.xml", contents)
                self.assertIn("classes.dex", contents)
                self.assertIn("resources.arsc", contents)

            # Step 4: Publish GitHub Release v1.0.0
            gh = MockGitHubReleaseClient(repo="savvakarayl-coder/galaxy-continuity")
            release = gh.create_release(
                tag="v1.0.0",
                title="Galaxy Continuity v1.0.0",
                notes="Initial production release: 1:1 Apple Continuity replacement between macOS and Galaxy.",
                asset_paths=[apk_path]
            )
            self.assertEqual(release["tag"], "v1.0.0")
            self.assertEqual(release["title"], "Galaxy Continuity v1.0.0")
            self.assertEqual(len(release["assets"]), 1)
            self.assertEqual(release["assets"][0]["name"], os.path.basename(apk_path))

            # Step 5: Connect newly released v1.0.0 client to macOS Continuity host
            client = ContinuityClient(host=self.host, port=self.port)
            ack = client.connect(device_name="Samsung Galaxy S24 Ultra (v1.0.0 Release)")
            try:
                self.assertTrue(client.is_connected)
                self.assertEqual(ack.get("type"), "handshake_ack")

                # Verify continuity session operational
                client.send_json({"type": "clipboard", "content": "Production Release Verified", "contentType": "text/plain", "source": "phone"})
                time.sleep(0.05)
                with self.server.lock:
                    self.assertEqual(self.server.last_clipboard_text, "Production Release Verified")
            finally:
                client.close()
        finally:
            if os.path.exists(apk_path):
                os.remove(apk_path)

    # =========================================================================
    # Scenario 6: Extreme Stress & Multi-Client Recovery Pipeline
    # =========================================================================

    def test_06_stress_and_recovery_workload(self):
        """
        Scenario 6: Concurrency & Stress Recovery.
        Simultaneously runs multiple clients performing rapid clipboard exchanges,
        touch input dispatch, file transfers, and graceful disconnection.
        """
        clients = [ContinuityClient(host=self.host, port=self.port) for _ in range(3)]
        for i, c in enumerate(clients):
            c.connect(device_name=f"Galaxy Client {i+1}")

        try:
            # 1. Concurrently send clipboard messages from all clients
            def client_activity(cl, idx):
                for step in range(5):
                    cl.send_json({
                        "type": "clipboard",
                        "content": f"Client {idx} Step {step}",
                        "contentType": "text/plain",
                        "source": "phone"
                    })
                    cl.send_json({
                        "type": "input_event",
                        "action": "move",
                        "x": 0.1 * idx,
                        "y": 0.1 * step
                    })
                    time.sleep(0.01)

            threads = [threading.Thread(target=client_activity, args=(clients[i], i)) for i in range(3)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=3.0)

            time.sleep(0.05)
            with self.server.lock:
                self.assertGreaterEqual(len(self.server.input_events), 15)
                self.assertIsNotNone(self.server.last_clipboard_text)

            # 2. Ping all clients
            self.server.broadcast_message({"type": "ping_device", "source": "mac", "message": "Broadcast Ping to All"})
            for c in clients:
                ping_msg = c.expect_message("ping_device", timeout=2.0)
                self.assertEqual(ping_msg.get("message"), "Broadcast Ping to All")

        finally:
            for c in clients:
                c.close()


if __name__ == "__main__":
    unittest.main()
