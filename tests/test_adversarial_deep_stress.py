#!/usr/bin/env python3
"""
Deep Adversarial Stress Test Suite for RFC 6455 & Protocol Robustness.
Stress-tests:
- Multi-chunk fragmentation (10+ continuation frames)
- Interleaved control frames between every chunk
- Binary frame fragmentation (opcode 0x2)
- Abandoned fragmentation state recovery
- Zero-length continuation frames
- Orphan continuation frames
- Heavy fragmentation (200 chunks)
- File upload directory traversal attempts via POST /api/upload
- Schema variations (Double percentage, Int button)
"""

import json
import os
import socket
import struct
import sys
import time
import unittest
import urllib.request
import urllib.error

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    ContinuityTestHarness,
    MockContinuityServer,
    encode_ws_frame,
    make_stream_packet,
)


class TestAdversarialDeepStress(unittest.TestCase):
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

    def _send_custom_frame(self, sock, opcode: int, payload: bytes, fin: bool = True, masked: bool = True):
        mask_key = os.urandom(4) if masked else b""
        b0 = (0x80 if fin else 0x00) | (opcode & 0x0F)
        b1 = 0x80 if masked else 0x00
        length = len(payload)

        header = bytearray([b0])
        if length <= 125:
            header.append(b1 | length)
        elif length <= 65535:
            header.append(b1 | 126)
            header.extend(struct.pack(">H", length))
        else:
            header.append(b1 | 127)
            header.extend(struct.pack(">Q", length))

        if masked:
            header.extend(mask_key)
            masked_payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
            sock.sendall(bytes(header) + masked_payload)
        else:
            sock.sendall(bytes(header) + payload)

    def test_01_multi_chunk_fragmentation_10_chunks(self):
        """Stress: Split message into 10 fragments (1 initial + 9 continuations)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            full_msg = {
                "type": "clipboard",
                "content": "MultiChunk_10_Fragments_Success_" + ("X" * 500),
                "contentType": "text/plain",
                "source": "phone"
            }
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = max(1, len(full_bytes) // 10)
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                fin = is_last
                self._send_custom_frame(client.sock, opcode=opcode, payload=chunk, fin=fin, masked=True)
                time.sleep(0.005)

            time.sleep(0.05)
            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, full_msg["content"], "10-chunk fragmented message must reassemble fully")
        finally:
            client.close()

    def test_02_interleaved_pings_between_every_continuation_chunk(self):
        """Stress: Interleave Ping between EVERY continuation frame in a 5-chunk message."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            full_msg = {
                "type": "clipboard",
                "content": "Interleaved_Every_Chunk_Verification",
                "contentType": "text/plain",
                "source": "phone"
            }
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = max(1, len(full_bytes) // 5)
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                fin = is_last

                self._send_custom_frame(client.sock, opcode=opcode, payload=chunk, fin=fin, masked=True)

                if not is_last:
                    # Send interleaved ping
                    ping_token = f"ping_chunk_{i}".encode("utf-8")
                    self._send_custom_frame(client.sock, opcode=0x9, payload=ping_token, fin=True, masked=True)
                    op, pong = client.recv_frame(timeout=2.0)
                    self.assertEqual(op, 0xA)
                    self.assertEqual(pong, ping_token)

            time.sleep(0.05)
            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, full_msg["content"], "Message must reassemble despite pings between all chunks")
        finally:
            client.close()

    def test_03_binary_frame_fragmentation(self):
        """Stress: Fragmented Binary Frame (opcode 0x2 FIN=0 + continuation opcode 0x0 FIN=1)."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Create a 5-byte header stream packet (stream_type 0x01) with mock NAL payload
            nal_payload = b"\x00\x00\x00\x01\x65" + (b"\xAA" * 1000)
            binary_packet = make_stream_packet(stream_type=0x01, payload=nal_payload)

            mid = len(binary_packet) // 2
            b_chunk1 = binary_packet[:mid]
            b_chunk2 = binary_packet[mid:]

            # Initial binary fragment: opcode 0x2, fin=False
            self._send_custom_frame(client.sock, opcode=0x2, payload=b_chunk1, fin=False, masked=True)
            time.sleep(0.01)

            # Continuation fragment: opcode 0x0, fin=True
            self._send_custom_frame(client.sock, opcode=0x0, payload=b_chunk2, fin=True, masked=True)
            time.sleep(0.05)

            # Wait for binary frames
            self.assertTrue(
                self.server.wait_for_binary_frames(min_count=1, timeout=2.0),
                "Server must receive and reassemble fragmented binary frame"
            )

            with self.server.lock:
                received_bin = self.server.received_binary_frames[-1]

            self.assertEqual(received_bin, binary_packet, "Reassembled binary payload must match original byte-for-byte")
        finally:
            client.close()

    def test_04_abandoned_fragmentation_state_reset(self):
        """Stress: Start fragmented message (opcode 0x1, fin=0), abandon it, send fresh complete message."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Incomplete fragment 1
            incomplete = b'{"type":"clipboard","content":"Abandoned_Start...'
            self._send_custom_frame(client.sock, opcode=0x1, payload=incomplete, fin=False, masked=True)
            time.sleep(0.01)

            # Interrupt with a completely fresh, unfragmented valid message (opcode 0x1, fin=True)
            fresh_msg = {
                "type": "clipboard",
                "content": "Fresh_Recovery_Message",
                "contentType": "text/plain",
                "source": "phone"
            }
            fresh_bytes = json.dumps(fresh_msg).encode("utf-8")
            self._send_custom_frame(client.sock, opcode=0x1, payload=fresh_bytes, fin=True, masked=True)
            time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, "Fresh_Recovery_Message", "Server must safely reset fragmentation and accept fresh message")
        finally:
            client.close()

    def test_05_zero_length_continuation_frames(self):
        """Stress: Continuation frames with zero payload."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            full_msg = {
                "type": "clipboard",
                "content": "ZeroLengthContinutationsWorks",
                "contentType": "text/plain",
                "source": "phone"
            }
            full_bytes = json.dumps(full_msg).encode("utf-8")
            mid = len(full_bytes) // 2

            # Chunk 1: Initial fragment
            self._send_custom_frame(client.sock, opcode=0x1, payload=full_bytes[:mid], fin=False, masked=True)
            # Empty continuation 1
            self._send_custom_frame(client.sock, opcode=0x0, payload=b"", fin=False, masked=True)
            # Empty continuation 2
            self._send_custom_frame(client.sock, opcode=0x0, payload=b"", fin=False, masked=True)
            # Final chunk
            self._send_custom_frame(client.sock, opcode=0x0, payload=full_bytes[mid:], fin=True, masked=True)
            time.sleep(0.05)

            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, full_msg["content"], "Zero-length continuations must not corrupt payload")
        finally:
            client.close()

    def test_06_orphan_continuation_discarded(self):
        """Stress: Sending continuation frame (0x0) with no preceding fragment must be discarded safely."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Send orphan continuation
            self._send_custom_frame(client.sock, opcode=0x0, payload=b"orphan_bytes", fin=True, masked=True)
            time.sleep(0.02)

            # Verify server is still operational
            client.send_ping(b"alive_orphan")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
            self.assertEqual(pong, b"alive_orphan")
        finally:
            client.close()

    def test_07_heavy_fragmentation_50_chunks(self):
        """Stress: 50 chunks of a 10KB message."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            long_text = "H" * 10000
            full_msg = {
                "type": "clipboard",
                "content": long_text,
                "contentType": "text/plain",
                "source": "phone"
            }
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = len(full_bytes) // 50
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                self._send_custom_frame(client.sock, opcode=opcode, payload=chunk, fin=is_last, masked=True)

            time.sleep(0.1)
            with self.server.lock:
                received = self.server.last_clipboard_text

            self.assertEqual(received, long_text, "50-chunk 10KB payload must match exactly")
        finally:
            client.close()

    def test_08_schema_numeric_button_and_decimal_percentage(self):
        """Schema: Numeric button (0, 1, 2) and decimal percentage (99.5) over socket."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            # Send input_event with integer button 1 (right click)
            client.send_json({
                "type": "input_event",
                "action": "down",
                "x": 0.5,
                "y": 0.5,
                "button": 1
            })
            time.sleep(0.05)

            # Send file_progress with float percentage 99.5
            client.send_json({
                "type": "file_progress",
                "fileId": "schema-test-1",
                "bytesTransferred": 995,
                "totalBytes": 1000,
                "percentage": 99.5,
                "status": "transferring"
            })
            time.sleep(0.05)

            # Verify server processed them
            with self.server.lock:
                msgs = [m for m in self.server.received_messages if m.get("type") in ("input_event", "file_progress")]

            self.assertGreaterEqual(len(msgs), 2)
            input_ev = next(m for m in msgs if m.get("type") == "input_event")
            self.assertEqual(input_ev.get("button"), 1)
            prog_ev = next(m for m in msgs if m.get("type") == "file_progress")
            self.assertEqual(prog_ev.get("percentage"), 99.5)
        finally:
            client.close()

    def test_09_file_upload_traversal_sanitization(self):
        """Security: File upload traversal attempts via POST /api/upload are sanitized."""
        url = f"http://{self.host}:{self.port}/api/upload"
        malicious_filenames = [
            "../../../../etc/passwd",
            "../outside.txt",
            "..%2F..%2Fhack.sh",
            "C:\\Windows\\System32\\cmd.exe",
            "....",
            ".",
            ".."
        ]
        test_payload = b"Adversarial file content for upload security test"

        for raw_name in malicious_filenames:
            req = urllib.request.Request(url, data=test_payload, method="POST")
            req.add_header("Content-Length", str(len(test_payload)))
            req.add_header("X-Filename", raw_name)
            req.add_header("Content-Type", "application/octet-stream")

            with urllib.request.urlopen(req, timeout=3.0) as resp:
                self.assertEqual(resp.status, 200)

            # Verify saved file in server
            with self.server.lock:
                latest = self.server.uploaded_files[-1]
                saved_path = latest["path"]
                saved_name = latest["filename"]

            # Saved name must not allow directory traversal
            self.assertNotIn("/", saved_name)
            self.assertNotEqual(saved_name, "..")
            self.assertNotEqual(saved_name, ".")
            # Saved path must reside strictly inside the uploads temp directory
            upload_dir = os.path.realpath(self.server.downloads_dir)
            real_saved_path = os.path.realpath(saved_path)
            self.assertTrue(
                real_saved_path.startswith(upload_dir),
                f"Saved file {real_saved_path} must be inside upload dir {upload_dir}"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
