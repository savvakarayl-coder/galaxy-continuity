#!/usr/bin/env python3
"""
Adversarial Stress Test Suite for Universal Clipboard (Milestone 2 Challenge)
Tests bidirectional text, image, large payloads, empty strings, corrupted base64,
and echo suppression across RFC 6455 WebSocket transport.
"""

import base64
import hashlib
import json
import os
import struct
import sys
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
)


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TestAdversarialClipboard(unittest.TestCase):
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
    # 1. Bidirectional Text Clipboard: Empty String ("")
    # -------------------------------------------------------------------------
    def test_01_empty_string_clipboard_phone_to_mac(self):
        """Empty string ("") text clipboard sent from phone is accepted without error."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            empty_hash = compute_sha256(b"")
            msg = {
                "type": "clipboard",
                "content": "",
                "contentType": "text/plain",
                "source": "phone",
                "hash": empty_hash
            }
            client.send_json(msg)
            time.sleep(0.05)

            with self.server.lock:
                self.assertIsNotNone(self.server.last_clipboard_text, "Server should register empty clipboard")
                self.assertEqual(self.server.last_clipboard_text, "")
        finally:
            client.close()

    def test_02_empty_string_clipboard_mac_to_phone(self):
        """Empty string clipboard broadcast from Mac is received intact by phone."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            self.server.set_mac_clipboard("")
            msg = client.expect_message("clipboard", timeout=2.0)
            self.assertEqual(msg.get("content"), "")
            self.assertEqual(msg.get("type"), "clipboard")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 2. Large Multi-Megabyte Text Payloads (64-bit frame length)
    # -------------------------------------------------------------------------
    def test_03_multimegabyte_text_payload_2mb(self):
        """Multi-megabyte (2 MB) text payload triggers 64-bit WebSocket length encoding and transfers intact."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 2 MB text with unicode, emojis, and symbols
            chunk = "Hello Continuity! 🚀 Савва \u2603 \u2708\n"
            repeat_count = (2 * 1024 * 1024) // len(chunk.encode("utf-8")) + 1
            huge_text = chunk * repeat_count
            payload_bytes = huge_text.encode("utf-8")
            self.assertGreater(len(payload_bytes), 2 * 1024 * 1024, "Payload must exceed 2 MB")

            text_hash = compute_sha256(payload_bytes)
            msg = {
                "type": "clipboard",
                "content": huge_text,
                "contentType": "text/plain",
                "source": "phone",
                "hash": text_hash
            }
            client.send_json(msg)

            # Wait for 2MB payload to finish receiving
            deadline = time.time() + 5.0
            while time.time() < deadline:
                with self.server.lock:
                    if self.server.last_clipboard_text is not None:
                        break
                time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertIsNotNone(received, "Server must receive 2 MB text payload")
            self.assertEqual(len(received), len(huge_text), "Received length must match exactly")
            self.assertEqual(compute_sha256(received.encode("utf-8")), text_hash, "SHA-256 of 2MB text must match")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 3. Rapid Successive Clipboard Updates (Burst Sync)
    # -------------------------------------------------------------------------
    def test_04_rapid_burst_sync_50_updates(self):
        """Rapid burst of 50 successive distinct clipboard updates without socket deadlock or loss."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            burst_count = 50
            for i in range(burst_count):
                item = f"Burst_Item_{i:04d}_{time.time()}"
                client.send_json({
                    "type": "clipboard",
                    "content": item,
                    "contentType": "text/plain",
                    "source": "phone"
                })

            # Wait for all 50 messages to be received
            deadline = time.time() + 5.0
            while time.time() < deadline:
                with self.server.lock:
                    msgs = [m for m in self.server.received_messages if m.get("type") == "clipboard"]
                    if len(msgs) >= burst_count:
                        break
                time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text
                clipboard_msgs = [m for m in self.server.received_messages if m.get("type") == "clipboard"]

            self.assertEqual(len(clipboard_msgs), burst_count, f"Server must process all {burst_count} burst updates")
            self.assertTrue(received.startswith("Burst_Item_0049"), "Final state must match 50th burst update")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 4. Loop Echo Suppression (Text)
    # -------------------------------------------------------------------------
    def test_05_loop_echo_suppression_text(self):
        """Duplicate clipboard messages with identical content or hash are suppressed and not echoed."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            unique_text = f"Suppression_Test_{time.time()}"
            h = compute_sha256(unique_text.encode("utf-8"))

            # Send first time
            client.send_json({
                "type": "clipboard",
                "content": unique_text,
                "contentType": "text/plain",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            # Send duplicate second time
            client.send_json({
                "type": "clipboard",
                "content": unique_text,
                "contentType": "text/plain",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            # Server must not broadcast echo back to client
            # Drain any immediate frames from socket
            messages = client.drain_messages(timeout=0.1)
            echoes = [m for m in messages if m.get("type") == "clipboard" and m.get("content") == unique_text]
            self.assertEqual(len(echoes), 0, "Server must NEVER echo incoming clipboard message back to client")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 5. Bidirectional Image Clipboard: Valid PNG, JPEG, TIFF
    # -------------------------------------------------------------------------
    def test_06_valid_image_clipboard_png_jpeg_tiff(self):
        """Valid PNG, JPEG, and TIFF payloads transfer successfully."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. 1x1 Red PNG
            png_bytes = (
                b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02"
                b"\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x03\x01"
                b"\x01\x00\x18\xdd\x8d\xb0\x00\x00\x00\x00IEND\xaeB`\x82"
            )
            b64_png = base64.b64encode(png_bytes).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_png,
                "contentType": "image/png",
                "source": "phone",
                "hash": compute_sha256(png_bytes)
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_png)

            # 2. Minimal JPEG (SOI + APP0 + DQT + SOF0 + SOS + EOI)
            jpeg_bytes = b"\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x01\x00`\x00`\x00\x00\xFF\xDB\x00C\x00\xFF\xD9"
            b64_jpeg = base64.b64encode(jpeg_bytes).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_jpeg,
                "contentType": "image/jpeg",
                "source": "phone",
                "hash": compute_sha256(jpeg_bytes)
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_jpeg)

            # 3. Minimal TIFF (Little-endian header: II*\x00 + 4-byte offset to IFD)
            tiff_bytes = b"II*\x00\x08\x00\x00\x00\x00\x00"
            b64_tiff = base64.b64encode(tiff_bytes).decode("ascii")
            client.send_json({
                "type": "clipboard",
                "content": b64_tiff,
                "contentType": "image/tiff",
                "source": "phone",
                "hash": compute_sha256(tiff_bytes)
            })
            time.sleep(0.05)
            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, b64_tiff)
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 6. Large Image Payload (> 1 MB, 64-bit length)
    # -------------------------------------------------------------------------
    def test_07_large_image_payload_over_1mb_64bit_frame(self):
        """Synthetic large image payload (> 1.5 MB) transfers over 64-bit WebSocket frame length."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1.5 MB synthetic image data
            synthetic_img = b"\x89PNG\r\n\x1a\n" + (b"\xAA\xBB\xCC\xDD" * (400 * 1024))
            self.assertGreater(len(synthetic_img), 1.5 * 1024 * 1024)

            b64_large = base64.b64encode(synthetic_img).decode("ascii")
            img_hash = compute_sha256(synthetic_img)

            msg = {
                "type": "clipboard",
                "content": b64_large,
                "contentType": "image/png",
                "source": "phone",
                "hash": img_hash
            }
            # Frame size will exceed 2 MB (> 65535 bytes -> 64-bit frame length)
            client.send_json(msg)

            # Wait for 1.5MB image payload to finish receiving
            deadline = time.time() + 5.0
            while time.time() < deadline:
                with self.server.lock:
                    if self.server.last_clipboard_text is not None:
                        break
                time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertIsNotNone(received, "Server must receive large image payload")
            self.assertEqual(len(received), len(b64_large), "Received Base64 size must match")
            decoded = base64.b64decode(received)
            self.assertEqual(compute_sha256(decoded), img_hash, "Decoded image SHA-256 must match original")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 7. Malformed / Corrupted Base64 Payloads (Graceful Rejection)
    # -------------------------------------------------------------------------
    def test_08_corrupted_base64_payloads_graceful_rejection(self):
        """Malformed and corrupted base64 payloads are handled gracefully without socket closure or crash."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            malformed_cases = [
                "!@#$%^&*()_+~<>?:\"{}|",              # Illegal non-base64 characters
                "iVBORw0KGgoAAAANSUhEUg",              # Truncated base64 (invalid length / missing padding)
                "iVBOR===invalid===padding====",        # Bad padding
                "AAAA\x00\x01\x02\x03BBBB",             # Embedded binary control characters
                "   \t\r\n   ",                         # Pure whitespace in image content
                "Zm9vYmFy\n\n\n\n",                     # Trailing newlines
                base64.b64encode(b"NOT_AN_IMAGE_DATA_RANDOM_NOISE" * 100).decode("ascii") # Valid base64 of non-image bytes
            ]

            for i, bad_b64 in enumerate(malformed_cases):
                msg = {
                    "type": "clipboard",
                    "content": bad_b64,
                    "contentType": "image/png",
                    "source": "phone"
                }
                client.send_json(msg)
                time.sleep(0.02)

                # Send valid ping-pong or text frame immediately to prove connection is healthy
                sentinel = f"Healthy_After_Bad_Payload_{i}"
                client.send_json({
                    "type": "clipboard",
                    "content": sentinel,
                    "contentType": "text/plain",
                    "source": "phone"
                })
                time.sleep(0.03)

                with self.server.lock:
                    self.assertEqual(
                        self.server.last_clipboard_text,
                        sentinel,
                        f"Server must remain fully operational after malformed base64 case {i}"
                    )
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 8. Image Loop Echo Suppression via SHA-256
    # -------------------------------------------------------------------------
    def test_09_image_loop_echo_suppression_sha256(self):
        """Duplicate image payload with identical SHA-256 hash is suppressed and not re-broadcast."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            raw_img = b"\x89PNG\r\n\x1a\n" + (b"\x55" * 1024)
            b64_img = base64.b64encode(raw_img).decode("ascii")
            h = compute_sha256(raw_img)

            # Send first time
            client.send_json({
                "type": "clipboard",
                "content": b64_img,
                "contentType": "image/png",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            # Send duplicate second time
            client.send_json({
                "type": "clipboard",
                "content": b64_img,
                "contentType": "image/png",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            # Server must not broadcast echo
            messages = client.drain_messages(timeout=0.1)
            echoes = [m for m in messages if m.get("type") == "clipboard" and m.get("content") == b64_img]
            self.assertEqual(len(echoes), 0, "Server must not echo identical image clipboard back to sender")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 9. Unicode Normalization, Emojis & RTL in Text Clipboard
    # -------------------------------------------------------------------------
    def test_10_special_unicode_emojis_rtl(self):
        """Text clipboard containing emojis, RTL Arabic, Hebrew, and null bytes transfers accurately."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            special_text = (
                "Emojis: 🚀👨‍👩‍👧‍👦🎉🔥 | "
                "Arabic: مرحبا بالعالم | "
                "Hebrew: שלום עולם | "
                "Math: ∀x ∈ ℝ, x² ≥ 0 | "
                "Symbols:  © ® ™ \u200B\u200C\u200D"
            )
            h = compute_sha256(special_text.encode("utf-8"))

            client.send_json({
                "type": "clipboard",
                "content": special_text,
                "contentType": "text/plain",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, special_text, "Special Unicode and RTL text must match verbatim")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 11. Fragmented Image Payload with Interleaved Control Frames
    # -------------------------------------------------------------------------
    def test_11_fragmented_image_payload_across_continuation_frames(self):
        """Fragmented image base64 payload across 15 continuation frames with interleaved Pings."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 50 KB image payload
            raw_img = b"\x89PNG\r\n\x1a\n" + (b"\x12\x34\x56\x78" * (12 * 1024))
            b64_img = base64.b64encode(raw_img).decode("ascii")
            h = compute_sha256(raw_img)

            full_msg = {
                "type": "clipboard",
                "content": b64_img,
                "contentType": "image/png",
                "source": "phone",
                "hash": h
            }
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = len(full_bytes) // 15
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                fin = is_last

                client.send_frame(opcode=opcode, payload=chunk, fin=fin, masked=True)

                # Interleave ping every 3 chunks
                if i % 3 == 0 and not is_last:
                    ping_token = f"clip_frag_ping_{i}".encode("utf-8")
                    client.send_ping(ping_token)
                    op, pong = client.recv_frame(timeout=2.0)
                    self.assertEqual(op, 0xA)
                    self.assertEqual(pong, ping_token)

            # Wait for message to reassemble
            deadline = time.time() + 3.0
            while time.time() < deadline:
                with self.server.lock:
                    if self.server.last_clipboard_text is not None:
                        break
                time.sleep(0.02)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertIsNotNone(received, "Fragmented image payload must be reassembled")
            self.assertEqual(received, b64_img, "Reassembled base64 image must match original byte-for-byte")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 12. Hash Omission & Spoofed Hash Loop Suppression
    # -------------------------------------------------------------------------
    def test_12_hash_omission_and_spoofed_hash_suppression(self):
        """Omitted hash is handled gracefully; identical hash suppresses repeat update."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # 1. Omitted hash field
            msg_no_hash = {
                "type": "clipboard",
                "content": "NoHashFieldContent_123",
                "contentType": "text/plain",
                "source": "phone"
            }
            client.send_json(msg_no_hash)
            time.sleep(0.05)

            with self.server.lock:
                self.assertEqual(self.server.last_clipboard_text, "NoHashFieldContent_123")

            # 2. Resend identical content with explicit hash
            h = compute_sha256(b"NoHashFieldContent_123")
            client.send_json({
                "type": "clipboard",
                "content": "NoHashFieldContent_123",
                "contentType": "text/plain",
                "source": "phone",
                "hash": h
            })
            time.sleep(0.05)

            # Check that no echo was sent back to client
            messages = client.drain_messages(timeout=0.05)
            self.assertEqual(len(messages), 0, "No echo should be sent back to client")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 13. Alternating Text and Image Burst
    # -------------------------------------------------------------------------
    def test_13_rapid_alternating_text_and_image_burst(self):
        """Rapid burst of 30 alternating text and image updates without type confusion."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            raw_png = b"\x89PNG\r\n\x1a\n" + (b"\x00" * 32)
            b64_png = base64.b64encode(raw_png).decode("ascii")

            burst_total = 30
            for i in range(burst_total):
                if i % 2 == 0:
                    client.send_json({
                        "type": "clipboard",
                        "content": f"Text_Burst_{i}",
                        "contentType": "text/plain",
                        "source": "phone"
                    })
                else:
                    client.send_json({
                        "type": "clipboard",
                        "content": f"{b64_png}_{i}",
                        "contentType": "image/png",
                        "source": "phone"
                    })

            deadline = time.time() + 5.0
            while time.time() < deadline:
                with self.server.lock:
                    msgs = [m for m in self.server.received_messages if m.get("type") == "clipboard"]
                    if len(msgs) >= burst_total:
                        break
                time.sleep(0.05)

            with self.server.lock:
                msgs = [m for m in self.server.received_messages if m.get("type") == "clipboard"]
                last_text = self.server.last_clipboard_text

            self.assertEqual(len(msgs), burst_total, f"All {burst_total} alternating messages must be processed")
            self.assertEqual(last_text, f"{b64_png}_29", "Final payload must match 30th alternating update")
        finally:
            client.close()

    # -------------------------------------------------------------------------
    # 14. Mac Clipboard Broadcast to Phone (Text & Image)
    # -------------------------------------------------------------------------
    def test_14_mac_clipboard_broadcast_to_phone(self):
        """Mac clipboard broadcast correctly dispatches text and image payloads to phone."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Broadcast text from Mac
            mac_text = "Mac_Secret_Token_98765"
            self.server.set_mac_clipboard(mac_text)
            msg1 = client.expect_message("clipboard", timeout=2.0)
            self.assertEqual(msg1.get("content"), mac_text)

            # Broadcast image from Mac
            synthetic_img = b"\x89PNG\r\n\x1a\n" + (b"\x99" * 128)
            b64_img = base64.b64encode(synthetic_img).decode("ascii")
            self.server.broadcast_message({
                "type": "clipboard",
                "content": b64_img,
                "contentType": "image/png",
                "source": "mac",
                "hash": compute_sha256(synthetic_img)
            })
            msg2 = client.expect_message("clipboard", timeout=2.0, predicate=lambda m: m.get("contentType") == "image/png")
            self.assertEqual(msg2.get("content"), b64_img)
            self.assertEqual(msg2.get("contentType"), "image/png")
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
