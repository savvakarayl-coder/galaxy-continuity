#!/usr/bin/env python3
"""
Empirical Adversarial Stress Test Suite for RFC 6455 WebSocket Framing & Protocol
Tests boundary lengths, masking, fragmentation, control frame interleaving, and malformed frames.
"""

import base64
import json
import os
import socket
import struct
import sys
import threading
import time
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    DEFAULT_PORT,
    ContinuityClient,
    ContinuityTestHarness,
    MockContinuityServer,
    compute_ws_accept,
    decode_ws_frame,
    encode_ws_frame,
)


class TestAdversarialWebSocketFraming(unittest.TestCase):
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
            self.server.last_clipboard_text = None
            self.server.received_messages.clear()
            self.server.received_binary_frames.clear()

    # -------------------------------------------------------------------------
    # 1. Boundary Lengths (125, 126, 65535, 65536 bytes)
    # -------------------------------------------------------------------------
    def test_boundary_lengths_over_socket(self):
        """Verify boundary payloads (125, 126, 65535, 65536 bytes) over live WebSocket."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            boundaries = [125, 126, 65535, 65536]
            for size in boundaries:
                # Construct JSON message of exact size by padding content
                base_msg = {"type": "clipboard", "contentType": "text/plain", "source": "phone", "content": ""}
                base_len = len(json.dumps(base_msg).encode("utf-8"))
                pad_len = max(0, size - base_len)
                base_msg["content"] = "A" * pad_len
                payload = json.dumps(base_msg).encode("utf-8")

                client.send_frame(opcode=0x1, payload=payload, masked=True)
                time.sleep(0.05)

                with self.server.lock:
                    self.assertIsNotNone(
                        self.server.last_clipboard_text,
                        f"Server should receive clipboard message for boundary size {len(payload)}"
                    )
                    self.assertEqual(
                        self.server.last_clipboard_text,
                        base_msg["content"],
                        f"Payload content should match for boundary size {len(payload)}"
                    )
                    self.server.last_clipboard_text = None
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 2. Masking & Cyclic Mask Patterns
    # -------------------------------------------------------------------------
    def test_masking_with_random_and_cyclic_keys(self):
        """Verify masking with random masks and cyclic patterns."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            test_masks = [
                os.urandom(4),
                b"\x00\x00\x00\x00",
                b"\xff\xff\xff\xff",
                b"\xaa\x55\xaa\x55",
                b"\x12\x34\x56\x78",
                b"\xde\xad\xbe\xef"
            ]

            for i, mask in enumerate(test_masks):
                content = f"Mask-Test-{i}-{mask.hex()}"
                msg = {"type": "clipboard", "content": content, "contentType": "text/plain", "source": "phone"}
                payload = json.dumps(msg).encode("utf-8")

                client.send_frame(opcode=0x1, payload=payload, masked=True, mask_key=mask)
                time.sleep(0.05)

                with self.server.lock:
                    self.assertEqual(
                        self.server.last_clipboard_text,
                        content,
                        f"Unmasked payload should match original with mask {mask.hex()}"
                    )
                    self.server.last_clipboard_text = None
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 3. Unmasked Client Frame Handling (PROTOCOL.md § 6.2)
    # -------------------------------------------------------------------------
    def test_unmasked_client_frame_tolerance(self):
        """PROTOCOL.md § 6.2 requires server to read unmasked client frames without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            msg = {"type": "clipboard", "content": "Unmasked-Client-Payload", "contentType": "text/plain", "source": "phone"}
            payload = json.dumps(msg).encode("utf-8")

            # Send unmasked frame (masked=False)
            client.send_frame(opcode=0x1, payload=payload, masked=False)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(
                    self.server.last_clipboard_text,
                    "Unmasked-Client-Payload",
                    "Server should accept unmasked client frame as required by PROTOCOL.md § 6.2"
                )
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 4. Fragmented Frame Reconstruction
    # -------------------------------------------------------------------------
    def test_fragmented_frame_reconstruction(self):
        """RFC 6455 § 5.4: Fragmented frames (opcode 0x1 fin=0, continuation opcode 0x0 fin=1)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            full_msg = {"type": "clipboard", "content": "FragmentedReconstructionSuccess", "contentType": "text/plain", "source": "phone"}
            full_bytes = json.dumps(full_msg).encode("utf-8")

            # Split in half
            mid = len(full_bytes) // 2
            chunk1 = full_bytes[:mid]
            chunk2 = full_bytes[mid:]

            # Encode frame 1: fin=False (b0 = 0x01), opcode=0x1
            mask1 = os.urandom(4)
            f1 = bytearray()
            f1.append(0x01) # FIN=0, opcode=0x1
            f1.append(0x80 | len(chunk1)) # Masked
            f1.extend(mask1)
            f1.extend(bytes(chunk1[j] ^ mask1[j % 4] for j in range(len(chunk1))))

            # Encode frame 2: fin=True (b0 = 0x80), opcode=0x0 (continuation)
            mask2 = os.urandom(4)
            f2 = bytearray()
            f2.append(0x80 | 0x00) # FIN=1, opcode=0x0
            f2.append(0x80 | len(chunk2)) # Masked
            f2.extend(mask2)
            f2.extend(bytes(chunk2[j] ^ mask2[j % 4] for j in range(len(chunk2))))

            client.sock.sendall(bytes(f1))
            time.sleep(0.02)
            client.sock.sendall(bytes(f2))
            time.sleep(0.1)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(
                received,
                "FragmentedReconstructionSuccess",
                "Server MUST reassemble fragmented WebSocket frames (opcode 0x1 + continuation 0x0)"
            )
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 5. Interleaved Control Frame during Fragmented Stream
    # -------------------------------------------------------------------------
    def test_interleaved_control_frame_during_fragmentation(self):
        """RFC 6455 § 5.4: Ping/Pong control frames interleaved during fragmented message."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            full_msg = {"type": "clipboard", "content": "InterleavedPingPongTest", "contentType": "text/plain", "source": "phone"}
            full_bytes = json.dumps(full_msg).encode("utf-8")

            mid = len(full_bytes) // 2
            chunk1 = full_bytes[:mid]
            chunk2 = full_bytes[mid:]

            # Frame 1: Text chunk 1, FIN=0
            mask1 = os.urandom(4)
            f1 = bytearray()
            f1.append(0x01) # FIN=0, opcode=0x1
            f1.append(0x80 | len(chunk1))
            f1.extend(mask1)
            f1.extend(bytes(chunk1[j] ^ mask1[j % 4] for j in range(len(chunk1))))

            # Frame 2: INTERLEAVED PING (opcode 0x9, FIN=1)
            ping_payload = b"adversarial_ping"
            ping_mask = os.urandom(4)
            f_ping = bytearray()
            f_ping.append(0x89) # FIN=1, opcode=0x9
            f_ping.append(0x80 | len(ping_payload))
            f_ping.extend(ping_mask)
            f_ping.extend(bytes(ping_payload[j] ^ ping_mask[j % 4] for j in range(len(ping_payload))))

            # Frame 3: Text chunk 2, opcode 0x0 (Continuation), FIN=1
            mask2 = os.urandom(4)
            f2 = bytearray()
            f2.append(0x80) # FIN=1, opcode=0x0
            f2.append(0x80 | len(chunk2))
            f2.extend(mask2)
            f2.extend(bytes(chunk2[j] ^ mask2[j % 4] for j in range(len(chunk2))))

            client.sock.sendall(bytes(f1))
            time.sleep(0.01)
            client.sock.sendall(bytes(f_ping))
            time.sleep(0.01)
            client.sock.sendall(bytes(f2))

            # Must receive Pong (opcode 0xA) with identical payload
            opcode, pong_payload = client.recv_frame(timeout=2.0)
            self.assertEqual(opcode, 0xA, "Interleaved Ping must trigger immediate Pong (0xA)")
            self.assertEqual(pong_payload, ping_payload, "Pong payload must match Ping payload")

            time.sleep(0.05)
            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(
                received,
                "InterleavedPingPongTest",
                "Server MUST reassemble message even when control frame is interleaved"
            )
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 6. Malformed Frame Handling
    # -------------------------------------------------------------------------
    def test_malformed_unassigned_opcode(self):
        """Malformed frame with unassigned opcode (e.g. 0x3) should be handled gracefully without server crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Send invalid opcode 0x3
            client.send_frame(opcode=0x3, payload=b"bad_opcode_payload", masked=True)
            time.sleep(0.05)

            # Send valid message after bad opcode to verify connection/server remains healthy
            valid_msg = {"type": "clipboard", "content": "After-Bad-Opcode", "contentType": "text/plain", "source": "phone"}
            client.send_json(valid_msg)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(
                    self.server.last_clipboard_text,
                    "After-Bad-Opcode",
                    "Server should discard unassigned opcode and remain operational"
                )
        finally:
            client.close()

    def test_malformed_rsv_bits_set(self):
        """Frames with reserved RSV bits (bits 4-6) set without extension negotiation."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Byte 0 with RSV1 set (0xC1 = 0x80 FIN + 0x40 RSV1 + 0x01 text)
            frame = bytearray()
            frame.append(0xC1)
            payload = b'{"type":"ping_device"}'
            mask = os.urandom(4)
            frame.append(0x80 | len(payload))
            frame.extend(mask)
            frame.extend(bytes(payload[j] ^ mask[j % 4] for j in range(len(payload))))

            client.sock.sendall(bytes(frame))
            time.sleep(0.05)

            # Follow up with valid message
            valid_msg = {"type": "clipboard", "content": "After-RSV-Frame", "contentType": "text/plain", "source": "phone"}
            client.send_json(valid_msg)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(
                    self.server.last_clipboard_text,
                    "After-RSV-Frame",
                    "Server should tolerate or recover from RSV bit frames without crashing"
                )
        finally:
            client.close()

    def test_malformed_non_utf8_in_text_frame(self):
        """Text frame (opcode 0x1) containing invalid UTF-8 bytes."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            invalid_utf8 = b"\xFF\xFE\xFD\xFC\x80\x81"
            client.send_frame(opcode=0x1, payload=invalid_utf8, masked=True)
            time.sleep(0.05)

            # Valid frame afterwards
            valid_msg = {"type": "clipboard", "content": "After-Bad-UTF8", "contentType": "text/plain", "source": "phone"}
            client.send_json(valid_msg)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(
                    self.server.last_clipboard_text,
                    "After-Bad-UTF8",
                    "Server should drop invalid UTF-8 text frame and remain operational"
                )
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
