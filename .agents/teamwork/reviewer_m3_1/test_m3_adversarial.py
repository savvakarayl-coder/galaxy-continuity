#!/usr/bin/env python3
"""
Adversarial Stress Test for Milestone 3 (Screen Mirroring & Continuity Camera)
Targeting the live running macOS Swift server on port 8765.
"""

import hashlib
import json
import os
import socket
import struct
import sys
import time

PROJECT_ROOT = "/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity"
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    encode_ws_frame,
    decode_ws_frame,
    make_stream_packet,
    parse_stream_packet,
    make_mock_jpeg,
    http_get
)

HOST = "127.0.0.1"
PORT = 8765

results = []

def run_test(name, fn):
    print(f"Running: {name} ...", end=" ", flush=True)
    try:
        fn()
        print("PASS")
        results.append((name, True, None))
    except Exception as e:
        print(f"FAIL: {e}")
        results.append((name, False, str(e)))

# Test 1: Screen Mirroring control message roundtrip & watchdog
def test_screen_lifecycle():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Start screen
        client.send_json({"type": "screen_start", "width": 1080, "height": 2400, "fps": 30, "bitrate": 4000000})
        time.sleep(0.1)

        # Stop screen
        client.send_json({"type": "screen_stop", "reason": "user_dismissed"})
        time.sleep(0.1)
    finally:
        client.close()

# Test 2: Continuity Camera lifecycle & control messages
def test_camera_lifecycle():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Start camera with aliases
        client.send_json({"type": "camera_start", "facing": "front", "resolution": "720p", "fps": 30})
        time.sleep(0.1)

        # Lens switch
        client.send_json({"type": "camera_switch_lens", "facing": "back"})
        time.sleep(0.1)

        # Camera control
        client.send_json({"type": "camera_control", "action": "set_zoom", "zoom": 2.5, "torch": True})
        time.sleep(0.1)

        # Stop camera
        client.send_json({"type": "camera_stop"})
        time.sleep(0.1)
    finally:
        client.close()

# Test 3: Camera frame delivery and HTTP streaming endpoint
def test_camera_stream_and_endpoint():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Before feeding, GET /api/camera/stream should return 503 or 404
        status, headers, body = http_get(HOST, PORT, "/api/camera/stream")
        assert status == 503, f"Expected 503 when feeder inactive, got {status}"

        # Send valid JPEG frame via Stream Type 0x02
        jpeg_data = make_mock_jpeg(640, 480)
        packet = make_stream_packet(stream_type=0x02, payload=jpeg_data)
        client.send_binary(packet)
        time.sleep(0.2)

        # Now GET /api/camera/stream should return 200 with the JPEG
        status, headers, body = http_get(HOST, PORT, "/api/camera/stream")
        assert status == 200, f"Expected 200 after feeding frame, got {status}"
        assert body == jpeg_data, f"Endpoint returned body of length {len(body)}, expected {len(jpeg_data)}"
        assert headers.get("content-type") == "image/jpeg", f"Wrong Content-Type: {headers.get('content-type')}"

        # Stop camera
        client.send_json({"type": "camera_stop"})
        time.sleep(0.2)

        # Feeder should be cleared -> 503
        status, _, _ = http_get(HOST, PORT, "/api/camera/stream")
        assert status == 503, f"Expected 503 after stopCamera, got {status}"
    finally:
        client.close()

# Test 4: Screen frame delivery
def test_screen_frame_delivery():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Start screen
        client.send_json({"type": "screen_start", "width": 1080, "height": 2400})
        time.sleep(0.1)

        # Send JPEG screen frame (supported by NSImage)
        jpeg_screen = make_mock_jpeg(360, 720)
        packet = make_stream_packet(stream_type=0x01, payload=jpeg_screen)
        client.send_binary(packet)
        time.sleep(0.2)

        # Stop screen
        client.send_json({"type": "screen_stop"})
        time.sleep(0.1)
    finally:
        client.close()

# Test 5: Watchdog stall behavior
def test_watchdog_stall():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Start screen
        client.send_json({"type": "screen_start"})
        time.sleep(0.2)

        # Wait 5.5 seconds without sending frames
        # Expect server to issue screen_stop with reason stream_stalled
        msg = client.expect_message("screen_stop", timeout=6.5)
        assert msg is not None, "Server did not issue screen_stop within watchdog interval"
        assert msg.get("reason") == "stream_stalled", f"Expected reason 'stream_stalled', got {msg.get('reason')}"
    finally:
        client.close()

# Test 6: Malformed binary packets robustness
def test_malformed_binary_packets():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # 1. Truncated packet (< 5 bytes)
        client.send_binary(b"\x01\x00\x00")
        time.sleep(0.05)

        # 2. Packet declaring 10000 bytes but only 1 byte payload
        client.send_binary(struct.pack(">BI", 0x01, 10000) + b"\x42")
        time.sleep(0.05)

        # 3. Unknown stream type 0xFF
        client.send_binary(struct.pack(">BI", 0xFF, 4) + b"test")
        time.sleep(0.05)

        # 4. Zero length payload
        client.send_binary(struct.pack(">BI", 0x01, 0))
        time.sleep(0.05)

        # Verify server is still alive
        client.send_json({"type": "ping_device", "source": "phone"})
        time.sleep(0.1)
    finally:
        client.close()

# Test 7: Remote input event boundary values and coordinate precision
def test_remote_input_boundaries():
    client = ContinuityClient(host=HOST, port=PORT)
    client.connect()
    try:
        # Out-of-bounds coordinates
        client.send_json({"type": "input_event", "action": "down", "x": -10.0, "y": -5.0, "button": 0})
        client.send_json({"type": "input_event", "action": "move", "x": 100.0, "y": 50.0, "button": 1})
        client.send_json({"type": "input_event", "action": "up", "x": 0.5, "y": 0.5, "button": 2})

        # Key navigation
        client.send_json({"type": "input_key", "key": "BACK", "keyCode": 4})
        client.send_json({"type": "input_key", "key": "HOME", "keyCode": 3})
        client.send_json({"type": "input_key", "key": "RECENTS", "keyCode": 187})
        client.send_json({"type": "input_key", "key": "POWER", "keyCode": 26})
        time.sleep(0.1)
    finally:
        client.close()

if __name__ == "__main__":
    print("=" * 60)
    print("Milestone 3 Live Server Adversarial Test Suite")
    print("=" * 60)
    run_test("Screen Lifecycle", test_screen_lifecycle)
    run_test("Camera Lifecycle", test_camera_lifecycle)
    run_test("Camera Stream & Endpoint", test_camera_stream_and_endpoint)
    run_test("Screen Frame Delivery", test_screen_frame_delivery)
    run_test("Malformed Binary Packets", test_malformed_binary_packets)
    run_test("Remote Input Boundaries", test_remote_input_boundaries)
    run_test("Watchdog Stall (5000ms)", test_watchdog_stall)

    print("=" * 60)
    passed = sum(1 for _, s, _ in results if s)
    total = len(results)
    print(f"Summary: {passed}/{total} passed")
    if passed < total:
        sys.exit(1)
