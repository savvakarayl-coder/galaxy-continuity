#!/usr/bin/env python3
"""
Empirical Adversarial Test Suite directly targeting the NATIVE macOS ServerManager.
"""

import base64
import json
import os
import socket
import struct
import sys
import time
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    compute_ws_accept,
    decode_ws_frame,
    encode_ws_frame,
)

PORT = 8765
HOST = "127.0.0.1"


class TestNativeMacServerAdversarial(unittest.TestCase):

    def setUp(self):
        # Verify server is listening
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect((HOST, PORT))
        s.close()

    def test_01_boundary_lengths(self):
        """Native Mac server: boundary payloads (125, 126, 65535, 65536 bytes)."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            for size in [125, 126, 65535, 65536]:
                base_msg = {"type": "ping_device", "source": "phone", "message": ""}
                base_len = len(json.dumps(base_msg).encode("utf-8"))
                pad_len = max(0, size - base_len)
                base_msg["message"] = "M" * pad_len
                payload = json.dumps(base_msg).encode("utf-8")

                client.send_frame(opcode=0x1, payload=payload, masked=True)
                time.sleep(0.05)
                # Send a small ping to verify server socket is healthy and responsive
                client.send_ping(b"alive_boundary")
                op, pong = client.recv_frame(timeout=2.0)
                self.assertEqual(op, 0xA, f"Server should respond with pong after boundary size {len(payload)}")
                self.assertEqual(pong, b"alive_boundary")
        finally:
            client.close()

    def test_02_masking_and_cyclic_patterns(self):
        """Native Mac server: masking with random and cyclic masks."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            masks = [
                os.urandom(4),
                b"\x00\x00\x00\x00",
                b"\xff\xff\xff\xff",
                b"\xaa\x55\xaa\x55",
                b"\xca\xfe\xba\xbe"
            ]
            for mask in masks:
                msg = {"type": "ping_device", "source": "phone", "message": f"Mask-{mask.hex()}"}
                payload = json.dumps(msg).encode("utf-8")
                client.send_frame(opcode=0x1, payload=payload, masked=True, mask_key=mask)
                time.sleep(0.02)
                client.send_ping(b"alive_mask")
                op, pong = client.recv_frame(timeout=2.0)
                self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_03_unmasked_client_frame_handling(self):
        """Native Mac server: unmasked client frame tolerance (PROTOCOL.md § 6.2)."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            msg = {"type": "ping_device", "source": "phone", "message": "unmasked_client"}
            payload = json.dumps(msg).encode("utf-8")
            # Send unmasked
            client.send_frame(opcode=0x1, payload=payload, masked=False)
            time.sleep(0.02)
            client.send_ping(b"alive_unmasked")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA, "Server should stay alive and respond to pong after unmasked frame")
        finally:
            client.close()

    def test_04_fragmented_frame_handling(self):
        """Native Mac server: fragmented frame (opcode 0x1 FIN=0, continuation opcode 0x0 FIN=1)."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            full_msg = {"type": "ping_device", "source": "phone", "message": "fragmented_native_test"}
            full_bytes = json.dumps(full_msg).encode("utf-8")
            mid = len(full_bytes) // 2
            chunk1 = full_bytes[:mid]
            chunk2 = full_bytes[mid:]

            # Frame 1: FIN=0, opcode=0x1
            mask1 = os.urandom(4)
            f1 = bytearray([0x01, 0x80 | len(chunk1)])
            f1.extend(mask1)
            f1.extend(bytes(chunk1[j] ^ mask1[j % 4] for j in range(len(chunk1))))

            # Frame 2: FIN=1, opcode=0x0
            mask2 = os.urandom(4)
            f2 = bytearray([0x80 | 0x00, 0x80 | len(chunk2)])
            f2.extend(mask2)
            f2.extend(bytes(chunk2[j] ^ mask2[j % 4] for j in range(len(chunk2))))

            client.sock.sendall(bytes(f1))
            time.sleep(0.02)
            client.sock.sendall(bytes(f2))
            time.sleep(0.05)

            # Check if server remains operational
            client.send_ping(b"alive_frag")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA, "Server must respond to ping after fragmented frame")
        finally:
            client.close()

    def test_05_interleaved_ping_during_fragmentation(self):
        """Native Mac server: interleaved Ping during fragmented frame stream."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            full_msg = {"type": "ping_device", "source": "phone", "message": "interleaved_stream"}
            full_bytes = json.dumps(full_msg).encode("utf-8")
            mid = len(full_bytes) // 2
            chunk1 = full_bytes[:mid]
            chunk2 = full_bytes[mid:]

            # Frame 1: FIN=0, opcode=0x1
            mask1 = os.urandom(4)
            f1 = bytearray([0x01, 0x80 | len(chunk1)])
            f1.extend(mask1)
            f1.extend(bytes(chunk1[j] ^ mask1[j % 4] for j in range(len(chunk1))))

            # Interleaved Ping: FIN=1, opcode=0x9
            ping_body = b"interleaved_ping"
            pmask = os.urandom(4)
            fping = bytearray([0x89, 0x80 | len(ping_body)])
            fping.extend(pmask)
            fping.extend(bytes(ping_body[j] ^ pmask[j % 4] for j in range(len(ping_body))))

            # Frame 2: Continuation, FIN=1, opcode=0x0
            mask2 = os.urandom(4)
            f2 = bytearray([0x80, 0x80 | len(chunk2)])
            f2.extend(mask2)
            f2.extend(bytes(chunk2[j] ^ mask2[j % 4] for j in range(len(chunk2))))

            client.sock.sendall(bytes(f1))
            time.sleep(0.01)
            client.sock.sendall(bytes(fping))
            time.sleep(0.01)
            client.sock.sendall(bytes(f2))

            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA, "Server must reply with Pong (0xA) for interleaved Ping")
            self.assertEqual(pong, ping_body, "Pong payload must match Ping payload")
        finally:
            client.close()

    def test_06_malformed_unassigned_opcodes(self):
        """Native Mac server: unassigned opcodes (0x3, 0x7, 0xB, 0xF)."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            for bad_op in [0x3, 0x7, 0xB, 0xF]:
                client.send_frame(opcode=bad_op, payload=b"bad_op_payload", masked=True)
                time.sleep(0.02)
                client.send_ping(b"alive_bad_op")
                op, pong = client.recv_frame(timeout=2.0)
                self.assertEqual(op, 0xA, f"Server should remain operational after bad opcode {bad_op}")
        finally:
            client.close()

    def test_07_malformed_rsv_bits(self):
        """Native Mac server: RSV bits set."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            for rsv_byte in [0x91, 0xA1, 0xC1, 0xF1]: # various RSV combinations
                payload = b'{"type":"ping_device"}'
                mask = os.urandom(4)
                f = bytearray([rsv_byte, 0x80 | len(payload)])
                f.extend(mask)
                f.extend(bytes(payload[j] ^ mask[j % 4] for j in range(len(payload))))
                client.sock.sendall(bytes(f))
                time.sleep(0.02)

            client.send_ping(b"alive_rsv")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA, "Server should remain operational after RSV frames")
        finally:
            client.close()

    def test_08_multi_chunk_fragmentation_10_chunks(self):
        """Native Mac server: 10-chunk fragmented message reassembly."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            full_msg = {"type": "ping_device", "source": "phone", "message": "MultiChunk10_" + ("Z" * 400)}
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = max(1, len(full_bytes) // 10)
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                fin = is_last

                mask = os.urandom(4)
                f = bytearray([(0x80 if fin else 0x00) | opcode, 0x80 | len(chunk)])
                f.extend(mask)
                f.extend(bytes(chunk[j] ^ mask[j % 4] for j in range(len(chunk))))
                client.sock.sendall(bytes(f))
                time.sleep(0.005)

            time.sleep(0.05)
            client.send_ping(b"alive_multichunk")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_09_interleaved_pings_between_chunks(self):
        """Native Mac server: Interleaved Pings between every continuation chunk."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            full_msg = {"type": "ping_device", "source": "phone", "message": "InterleavedPingNative"}
            full_bytes = json.dumps(full_msg).encode("utf-8")
            chunk_size = max(1, len(full_bytes) // 4)
            chunks = [full_bytes[i:i + chunk_size] for i in range(0, len(full_bytes), chunk_size)]

            for i, chunk in enumerate(chunks):
                is_first = (i == 0)
                is_last = (i == len(chunks) - 1)
                opcode = 0x1 if is_first else 0x0
                fin = is_last

                mask = os.urandom(4)
                f = bytearray([(0x80 if fin else 0x00) | opcode, 0x80 | len(chunk)])
                f.extend(mask)
                f.extend(bytes(chunk[j] ^ mask[j % 4] for j in range(len(chunk))))
                client.sock.sendall(bytes(f))

                if not is_last:
                    ptoken = f"p_{i}".encode("utf-8")
                    pmask = os.urandom(4)
                    fp = bytearray([0x89, 0x80 | len(ptoken)])
                    fp.extend(pmask)
                    fp.extend(bytes(ptoken[j] ^ pmask[j % 4] for j in range(len(ptoken))))
                    client.sock.sendall(bytes(fp))

                    op, pong = client.recv_frame(timeout=2.0)
                    self.assertEqual(op, 0xA)
                    self.assertEqual(pong, ptoken)

            time.sleep(0.05)
            client.send_ping(b"alive_interleaved_all")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_10_abandoned_fragmentation_reset(self):
        """Native Mac server: Abandoned fragmented message followed by fresh frame."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            incomplete = b'{"type":"ping_device","message":"incomplete...'
            mask = os.urandom(4)
            f = bytearray([0x01, 0x80 | len(incomplete)])
            f.extend(mask)
            f.extend(bytes(incomplete[j] ^ mask[j % 4] for j in range(len(incomplete))))
            client.sock.sendall(bytes(f))
            time.sleep(0.01)

            # Interrupt with complete frame
            fresh = json.dumps({"type": "ping_device", "source": "phone", "message": "fresh"}).encode("utf-8")
            mask2 = os.urandom(4)
            f2 = bytearray([0x81, 0x80 | len(fresh)])
            f2.extend(mask2)
            f2.extend(bytes(fresh[j] ^ mask2[j % 4] for j in range(len(fresh))))
            client.sock.sendall(bytes(f2))
            time.sleep(0.05)

            client.send_ping(b"alive_abandoned")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_11_zero_length_continuation_frames(self):
        """Native Mac server: Zero-length continuation frames."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            full_msg = {"type": "ping_device", "source": "phone", "message": "zero_len_cont"}
            full_bytes = json.dumps(full_msg).encode("utf-8")
            mid = len(full_bytes) // 2

            # Chunk 1
            mask1 = os.urandom(4)
            f1 = bytearray([0x01, 0x80 | mid])
            f1.extend(mask1)
            f1.extend(bytes(full_bytes[:mid][j] ^ mask1[j % 4] for j in range(mid)))
            client.sock.sendall(bytes(f1))

            # Zero-length continuation
            f_zero = bytearray([0x00, 0x80])
            f_zero.extend(os.urandom(4))
            client.sock.sendall(bytes(f_zero))

            # Chunk 2
            rest = full_bytes[mid:]
            mask2 = os.urandom(4)
            f2 = bytearray([0x80, 0x80 | len(rest)])
            f2.extend(mask2)
            f2.extend(bytes(rest[j] ^ mask2[j % 4] for j in range(len(rest))))
            client.sock.sendall(bytes(f2))
            time.sleep(0.05)

            client.send_ping(b"alive_zero_len")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_12_orphan_continuation_discard(self):
        """Native Mac server: Orphan continuation frame discarded safely."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            payload = b"orphan_bytes"
            mask = os.urandom(4)
            f = bytearray([0x80, 0x80 | len(payload)])
            f.extend(mask)
            f.extend(bytes(payload[j] ^ mask[j % 4] for j in range(len(payload))))
            client.sock.sendall(bytes(f))
            time.sleep(0.02)

            client.send_ping(b"alive_orphan_native")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()

    def test_13_file_upload_traversal_sanitization(self):
        """Native Mac server: POST /api/upload with path traversal attempts."""
        traversal_attempts = [
            "../../../../tmp/hacked_outside.txt",
            "..%2F..%2Fhacked_outside.txt",
            "C:\\Windows\\System32\\cmd.exe",
            ".hidden_traversal",
            "...."
        ]
        target_dir = os.path.expanduser("~/Downloads/GalaxyContinuity")
        payload = b"Malicious upload attempt payload content"

        for raw_filename in traversal_attempts:
            req = f"POST /api/upload HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nContent-Length: {len(payload)}\r\nX-Filename: {raw_filename}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect((HOST, PORT))
            s.sendall(req.encode("utf-8") + payload)
            resp = s.recv(4096).decode("utf-8", errors="replace")
            s.close()
            self.assertIn("200 OK", resp)

        # Verify that no file was created in /tmp/
        self.assertFalse(os.path.exists("/tmp/hacked_outside.txt"))

    def test_14_schema_button_and_percentage(self):
        """Native Mac server: ContinuityMessage with numeric button (0) and float percentage (75.5)."""
        client = ContinuityClient(host=HOST, port=PORT)
        client.connect(send_initial_handshake=True)
        try:
            btn_msg = {"type": "input_event", "action": "down", "x": 0.5, "y": 0.5, "button": 0}
            client.send_frame(opcode=0x1, payload=json.dumps(btn_msg).encode("utf-8"), masked=True)
            time.sleep(0.02)

            prog_msg = {"type": "file_progress", "fileId": "nat-1", "bytesTransferred": 755, "totalBytes": 1000, "percentage": 75.5, "status": "transferring"}
            client.send_frame(opcode=0x1, payload=json.dumps(prog_msg).encode("utf-8"), masked=True)
            time.sleep(0.02)

            client.send_ping(b"alive_schema")
            op, pong = client.recv_frame(timeout=2.0)
            self.assertEqual(op, 0xA)
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
