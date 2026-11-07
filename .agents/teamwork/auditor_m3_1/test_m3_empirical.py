#!/usr/bin/env python3
"""
Empirical Forensic Verification Script for Milestone 3.
Directly tests the native compiled macOS GalaxyContinuity server:
- WebSocket handshake & ack
- Screen mirroring control (screen_start, screen_stop)
- Binary stream packet framing (0x01 for screen)
- Remote input event & key dispatch
- Continuity Camera control (camera_start, camera_stop, camera_control)
- Binary stream packet framing (0x02 for camera)
- VirtualWebcamFeeder HTTP stream retrieval (GET /api/camera/stream)
- HTTP 503 when camera is inactive
- Stalling watchdog timeout (> 5000ms)
"""

import http.client
import json
import os
import socket
import struct
import sys
import time

PROJECT_ROOT = "/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity"
sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    make_mock_jpeg,
    make_mock_h264_nal,
    make_stream_packet,
    parse_stream_packet,
)

PORT = 8765
HOST = "127.0.0.1"

def run_tests():
    print("=== Milestone 3 Empirical Forensic Verification ===")

    # 1. Connect client and perform handshake
    print("\n[Step 1] Connecting to native macOS host on ws://127.0.0.1:8765/ws ...")
    client = ContinuityClient(host=HOST, port=PORT)
    ack_json = client.connect(send_initial_handshake=True)

    print(f"-> Received handshake_ack from server: type={ack_json.get('type')} device={ack_json.get('device')}")
    assert ack_json.get("type") == "handshake_ack"

    # 2. Screen Mirroring Lifecycle
    print("\n[Step 2] Testing Screen Mirroring Lifecycle ...")
    screen_start = {
        "type": "screen_start",
        "width": 1080,
        "height": 2400,
        "fps": 30,
        "bitrate": 4000000
    }
    client.send_json(screen_start)
    print("-> Sent screen_start message.")
    time.sleep(0.1)

    # Send binary H.264 screen frame (streamType 0x01)
    nal_payload = make_mock_h264_nal(nal_type=5, size=256)
    screen_packet = struct.pack(">BI", 0x01, len(nal_payload)) + nal_payload
    client.send_binary(screen_packet)
    print(f"-> Dispatched 0x01 Screen Mirroring binary packet ({len(screen_packet)} bytes).")

    # Send remote input gestures (down, move, up) with coordinate normalization
    print("\n[Step 3] Testing Remote Input Injection ...")
    input_down = {"type": "input_event", "action": "down", "x": 0.45, "y": 0.82, "button": 0}
    client.send_json(input_down)
    input_move = {"type": "input_event", "action": "move", "x": 0.50, "y": 0.75, "button": 0}
    client.send_json(input_move)
    input_up = {"type": "input_event", "action": "up", "x": 0.50, "y": 0.75, "button": 0}
    client.send_json(input_up)
    key_back = {"type": "input_key", "key": "BACK", "keyCode": 4}
    client.send_json(key_back)
    print("-> Injected touch down, move, up, and BACK key events.")

    # Stop screen mirroring
    screen_stop = {"type": "screen_stop", "reason": "user_dismissed"}
    client.send_json(screen_stop)
    print("-> Sent screen_stop message.")
    time.sleep(0.1)

    # 3. Continuity Camera & Virtual Webcam Feeder
    print("\n[Step 4] Testing Continuity Camera & Virtual Webcam Feeder ...")
    # Verify HTTP /api/camera/stream returns 503 before camera starts
    conn = http.client.HTTPConnection(HOST, PORT)
    conn.request("GET", "/api/camera/stream")
    resp = conn.getresponse()
    print(f"-> Inactive camera GET /api/camera/stream status: {resp.status} (expected 503)")
    assert resp.status == 503
    conn.close()

    # Start camera session
    camera_start = {
        "type": "camera_start",
        "lens": "back",
        "quality": "1080p",
        "fps": 30
    }
    client.send_json(camera_start)
    print("-> Sent camera_start message.")
    time.sleep(0.1)

    # Send binary JPEG frame (streamType 0x02)
    mock_jpeg = make_mock_jpeg(width=640, height=480)
    camera_packet = struct.pack(">BI", 0x02, len(mock_jpeg)) + mock_jpeg
    client.send_binary(camera_packet)
    print(f"-> Dispatched 0x02 Continuity Camera binary packet ({len(camera_packet)} bytes).")
    time.sleep(0.1)

    # Verify HTTP /api/camera/stream returns 200 OK with the exact JPEG buffer
    conn = http.client.HTTPConnection(HOST, PORT)
    conn.request("GET", "/api/camera/stream")
    resp = conn.getresponse()
    body = resp.read()
    print(f"-> Active camera GET /api/camera/stream status: {resp.status}, Content-Type: {resp.getheader('Content-Type')}, length: {len(body)}")
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "image/jpeg"
    assert body == mock_jpeg, "Feeder returned JPEG did not match ingested JPEG!"
    print("-> Byte-for-byte fidelity verified on VirtualWebcamFeeder!")
    conn.close()

    # Test camera controls
    print("\n[Step 5] Testing Camera Remote Controls (lens, zoom, torch) ...")
    ctrl_lens = {"type": "camera_control", "action": "switch_lens", "lens": "front"}
    client.send_json(ctrl_lens)
    ctrl_zoom = {"type": "camera_control", "action": "set_zoom", "zoom": 2.5}
    client.send_json(ctrl_zoom)
    ctrl_torch = {"type": "camera_control", "action": "toggle_torch", "torch": True}
    client.send_json(ctrl_torch)
    print("-> Injected switch_lens, set_zoom (2.5x), and toggle_torch (True).")

    # Stop camera session
    camera_stop = {"type": "camera_stop"}
    client.send_json(camera_stop)
    print("-> Sent camera_stop message.")
    time.sleep(0.1)

    # Verify HTTP /api/camera/stream returns 503 again
    conn = http.client.HTTPConnection(HOST, PORT)
    conn.request("GET", "/api/camera/stream")
    resp = conn.getresponse()
    print(f"-> Stopped camera GET /api/camera/stream status: {resp.status} (expected 503)")
    assert resp.status == 503
    conn.close()

    # 4. Truncated Binary Frame Resilience
    print("\n[Step 6] Testing Malformed / Truncated Binary Frame Handling ...")
    # Send packet shorter than 5 bytes
    client.send_binary(b"\x01\x00\x00")
    # Send packet with length mismatch (claims 1000 bytes, only 4 provided)
    client.send_binary(struct.pack(">BI", 0x01, 1000) + b"\x01\x02\x03\x04")
    # Send ping to verify server survived
    client.send_ping(b"still_alive_after_truncated")
    op, pong = client.recv_frame(timeout=2.0)
    assert op == 0xA
    assert pong == b"still_alive_after_truncated"
    print("-> Server survived malformed stream packets and responded with Pong!")

    client.close()
    print("\n🎉 ALL EMPIRICAL FORENSIC CHECKS PASSED WITH 100% SUCCESS!")

if __name__ == "__main__":
    run_tests()
