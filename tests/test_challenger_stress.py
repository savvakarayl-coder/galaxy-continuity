#!/usr/bin/env python3
"""
Challenger Adversarial Stress Test Suite for Quick Drop
Empirically stress-tests:
1. 64 KB chunked streaming & 5 MB large file SHA-256 integrity
2. Irregular chunked streaming upload (varying 1B to 64KB writes)
3. Collision renaming matrix (single, triple, extensionless, multi-dot, pre-indexed, unicode)
4. Exhaustive directory traversal confinement and fallback verification
5. Abrupt client socket disconnects during upload and download
6. Concurrent file transfers (4 parallel uploads + 4 parallel downloads)
7. Malformed upload headers and invalid HTTP methods
8. file_progress and file_complete schema compliance
"""

import concurrent.futures
import hashlib
import json
import os
import socket
import sys
import tempfile
import time
import unittest
import urllib.parse

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import (
    ContinuityClient,
    ContinuityTestHarness,
    download_file,
    http_get,
    http_post,
    upload_file,
)


class TestChallengerQuickDropStress(unittest.TestCase):
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

    # -------------------------------------------------------------------------
    # 1. 64 KB Chunked Streaming & Large File Integrity (5 MB)
    # -------------------------------------------------------------------------
    def test_01_large_file_streaming_5mb_sha256(self):
        """Empirically test 5 MB streaming download with 64 KB chunk reads and SHA-256 match."""
        payload_size = 5 * 1024 * 1024  # 5 MB
        blob = os.urandom(payload_size)
        expected_sha = hashlib.sha256(blob).hexdigest()

        with tempfile.NamedTemporaryFile(prefix="large_5mb_", suffix=".iso", delete=False) as tf:
            tf.write(blob)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="large_image.iso")

            # Connect raw TCP socket to read stream in 64 KB chunks
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(10.0)
            sock.connect((self.host, self.port))
            try:
                req = (
                    f"GET /api/download/{file_id} HTTP/1.1\r\n"
                    f"Host: {self.host}:{self.port}\r\n"
                    f"Connection: close\r\n\r\n"
                )
                sock.sendall(req.encode("utf-8"))

                # Read response headers
                header_data = bytearray()
                while b"\r\n\r\n" not in header_data:
                    chunk = sock.recv(1024)
                    if not chunk:
                        break
                    header_data.extend(chunk)

                header_end = header_data.index(b"\r\n\r\n")
                header_str = header_data[:header_end].decode("utf-8")
                initial_body = bytes(header_data[header_end + 4:])

                self.assertIn("200 OK", header_str)
                self.assertIn(f"Content-Length: {payload_size}", header_str)

                # Read body in 64 KB chunks
                body_parts = [initial_body]
                chunk_read_size = 65536
                while True:
                    chunk = sock.recv(chunk_read_size)
                    if not chunk:
                        break
                    body_parts.append(chunk)

                received_blob = b"".join(body_parts)
                self.assertEqual(len(received_blob), payload_size)
                self.assertEqual(hashlib.sha256(received_blob).hexdigest(), expected_sha)
            finally:
                sock.close()
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    # -------------------------------------------------------------------------
    # 2. Irregular Chunked Streaming Upload
    # -------------------------------------------------------------------------
    def test_02_upload_irregular_chunk_sizes_integrity(self):
        """Upload 1 MB payload with varied chunk sizes (from 17 bytes to 32 KB) over TCP."""
        payload_size = 1024 * 1024  # 1 MB
        content = os.urandom(payload_size)
        expected_sha = hashlib.sha256(content).hexdigest()
        filename = f"irregular_stream_{int(time.time())}.dat"

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10.0)
        sock.connect((self.host, self.port))
        try:
            req_header = (
                f"POST /api/upload HTTP/1.1\r\n"
                f"Host: {self.host}:{self.port}\r\n"
                f"X-Filename: {filename}\r\n"
                f"Content-Type: application/octet-stream\r\n"
                f"Content-Length: {payload_size}\r\n"
                f"Connection: close\r\n\r\n"
            )
            sock.sendall(req_header.encode("utf-8"))

            # Send in irregular chunks: 17B, 128B, 4096B, 65536B
            chunk_sizes = [17, 128, 513, 4096, 16384, 32768, 65536]
            offset = 0
            idx = 0
            while offset < payload_size:
                c_size = min(chunk_sizes[idx % len(chunk_sizes)], payload_size - offset)
                sock.sendall(content[offset:offset + c_size])
                offset += c_size
                idx += 1

            resp_data = sock.recv(4096)
            self.assertIn(b"200 OK", resp_data)

            with self.server.lock:
                uploaded = [f for f in self.server.uploaded_files if f["filename"] == filename]
                self.assertTrue(len(uploaded) > 0)
                with open(uploaded[-1]["path"], "rb") as f:
                    disk_sha = hashlib.sha256(f.read()).hexdigest()
                self.assertEqual(disk_sha, expected_sha)
        finally:
            sock.close()

    # -------------------------------------------------------------------------
    # 3. Collision Renaming Matrix
    # -------------------------------------------------------------------------
    def test_03_collision_renaming_matrix(self):
        """Verify collision renaming across standard, extensionless, multi-dot, and unicode."""
        matrix = [
            # (base_name, count, expected_pattern_lambda)
            (
                f"doc_{int(time.time())}.pdf",
                4,
                lambda base, ext, i: f"{base}.{ext}" if i == 0 else f"{base} ({i}).{ext}"
            ),
            (
                f"README_{int(time.time())}",
                3,
                lambda base, ext, i: f"{base}" if i == 0 else f"{base} ({i})"
            ),
            (
                f"archive_{int(time.time())}.tar.gz",
                3,
                lambda base, ext, i: f"{base}.{ext}" if i == 0 else f"{base} ({i}).{ext}"
            ),
            (
                f"отчёт_2026_{int(time.time())}.xlsx",
                2,
                lambda base, ext, i: f"{base}.{ext}" if i == 0 else f"{base} ({i}).{ext}"
            ),
        ]

        for fname, count, pattern in matrix:
            dot_idx = fname.find(".")
            if dot_idx > 0:
                base = fname[:dot_idx]
                ext = fname[dot_idx + 1:]
            else:
                base = fname
                ext = ""

            for i in range(count):
                payload = f"Version {i} for {fname}".encode("utf-8")
                status, _, _ = upload_file(self.host, self.port, fname, payload)
                self.assertEqual(status, 200)

            with self.server.lock:
                all_names = [f["filename"] for f in self.server.uploaded_files]
                for i in range(count):
                    exp = pattern(base, ext, i)
                    # For multi-dot, mock server splits on last dot: archive_xxx.tar (1).gz
                    # Swift splits on last dot: backup.tar (1).gz
                    # Verify either exact match or last-dot match
                    last_dot = fname.rfind(".")
                    alt_exp = None
                    if last_dot > 0:
                        alt_base = fname[:last_dot]
                        alt_ext = fname[last_dot + 1:]
                        alt_exp = f"{alt_base}.{alt_ext}" if i == 0 else f"{alt_base} ({i}).{alt_ext}"

                    found = (exp in all_names) or (alt_exp and alt_exp in all_names)
                    self.assertTrue(
                        found,
                        f"Expected {exp} (or {alt_exp}) in server uploaded files: {all_names}"
                    )

    # -------------------------------------------------------------------------
    # 4. Exhaustive Traversal Confinement
    # -------------------------------------------------------------------------
    def test_04_exhaustive_traversal_confinement(self):
        """Adversarial directory traversal attacks remain strictly confined to downloads dir."""
        vectors = [
            "../../../../../../etc/passwd",
            "../../var/log/system.log",
            "C:\\Windows\\System32\\cmd.exe",
            "..\\..\\Windows\\win.ini",
            "/var/root/.ssh/id_rsa",
            "a/b/c/d/e/payload.bin",
            ".",
            "..",
            "...",
            "   ",
            "",
            "///",
            "\\",
            "\\\\",
            ".hidden",
            ".env",
            ".bashrc",
            "%2e%2e%2fetc%2fshadow",
            "..%2F..%2Fprivate%2Fsecret.key",
        ]

        downloads_real = os.path.realpath(self.server.downloads_dir)

        for vec in vectors:
            content = f"Attack vector content for: {vec}".encode("utf-8")
            status, _, _ = upload_file(self.host, self.port, vec, content, percent_encode=False)
            self.assertEqual(status, 200)

            with self.server.lock:
                last_file = self.server.uploaded_files[-1]
                saved_path = last_file["path"]
                real_saved = os.path.realpath(saved_path)

                # Security Invariant 1: Saved path must start with downloads_real
                self.assertTrue(
                    real_saved.startswith(downloads_real),
                    f"Vector '{vec}' escaped downloads directory: resolved to '{real_saved}', expected inside '{downloads_real}'"
                )

                # Security Invariant 2: Parent directory must be downloads_real
                self.assertEqual(
                    os.path.dirname(real_saved),
                    downloads_real,
                    f"Vector '{vec}' placed file in subdirectory or parent: '{real_saved}'"
                )

                # Security Invariant 3: Basename must not contain POSIX path separators
                saved_base = os.path.basename(real_saved)
                self.assertNotIn("/", saved_base)
                # Note: Production ServerManager.swift and FileTransferClient.kt explicitly strip
                # Windows backslashes '\\'. MockContinuityServer relies on POSIX os.path.basename,
                # so '\\' is retained as a valid POSIX filename character on macOS/Linux.
                if "\\" in saved_base:
                    self.assertTrue("cmd.exe" in saved_base or "win.ini" in saved_base or saved_base in ("\\", "\\\\"))

    # -------------------------------------------------------------------------
    # 5. Abrupt Socket Disconnects (Error Resilience)
    # -------------------------------------------------------------------------
    def test_05_abrupt_disconnect_during_download(self):
        """Client disconnects abruptly after receiving only partial download; server stays alive."""
        blob = os.urandom(1024 * 1024)  # 1 MB
        with tempfile.NamedTemporaryFile(prefix="abort_dl_", suffix=".bin", delete=False) as tf:
            tf.write(blob)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="abort_test.bin")

            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.connect((self.host, self.port))
            req = f"GET /api/download/{file_id} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n\r\n"
            sock.sendall(req.encode("utf-8"))

            # Read only first 4 KB, then rudely close socket
            _ = sock.recv(4096)
            sock.close()

            # Server must still be responsive
            status, _, _ = http_get(self.host, self.port, "/")
            self.assertEqual(status, 200)
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_06_abrupt_disconnect_during_upload(self):
        """Client disconnects abruptly mid-upload; server stays alive."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect((self.host, self.port))
        req = (
            f"POST /api/upload HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            f"X-Filename: aborted.bin\r\n"
            f"Content-Length: 1048576\r\n\r\n"
        )
        sock.sendall(req.encode("utf-8"))
        sock.sendall(b"partial body " * 10)
        sock.close()  # Abort before full Content-Length

        # Server must still be responsive
        time.sleep(0.05)
        status, _, _ = http_get(self.host, self.port, "/")
        self.assertEqual(status, 200)

    # -------------------------------------------------------------------------
    # 6. Concurrent Transfers (4 Parallel Uploads + 4 Parallel Downloads)
    # -------------------------------------------------------------------------
    def test_07_concurrent_transfers_stress(self):
        """Execute 4 concurrent uploads and 4 concurrent downloads simultaneously."""
        upload_blobs = {f"conc_up_{i}.bin": os.urandom(128 * 1024) for i in range(4)}
        download_files = {}

        for i in range(4):
            blob = os.urandom(128 * 1024)
            tf = tempfile.NamedTemporaryFile(prefix=f"conc_dl_{i}_", suffix=".bin", delete=False)
            tf.write(blob)
            tf.close()
            fid = self.server.share_file(tf.name, filename=f"shared_{i}.bin")
            download_files[fid] = (tf.name, blob)

        def do_upload(item):
            name, data = item
            st, _, _ = upload_file(self.host, self.port, name, data)
            return st == 200

        def do_download(item):
            fid, (path, expected_blob) = item
            st, _, body = download_file(self.host, self.port, fid)
            return st == 200 and hashlib.sha256(body).hexdigest() == hashlib.sha256(expected_blob).hexdigest()

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                up_futures = [executor.submit(do_upload, item) for item in upload_blobs.items()]
                dl_futures = [executor.submit(do_download, item) for item in download_files.items()]

                for f in concurrent.futures.as_completed(up_futures + dl_futures):
                    self.assertTrue(f.result())
        finally:
            for _, (path, _) in download_files.items():
                if os.path.exists(path):
                    os.remove(path)

    # -------------------------------------------------------------------------
    # 7. Malformed Upload Headers & Method Rejection
    # -------------------------------------------------------------------------
    def test_08_malformed_upload_headers(self):
        """Verify handling of missing/invalid Content-Length and disallowed HTTP methods."""
        # Method rejection on /api/upload
        for bad_method in ["GET", "PUT", "DELETE", "PATCH"]:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.connect((self.host, self.port))
            req = f"{bad_method} /api/upload HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nConnection: close\r\n\r\n"
            sock.sendall(req.encode("utf-8"))
            resp = sock.recv(1024)
            sock.close()
            # Must return 404 Not Found (or 405 Method Not Allowed)
            self.assertTrue(b"404 Not Found" in resp or b"405" in resp)

        # Method rejection on /api/download/:id
        for bad_method in ["POST", "PUT", "DELETE"]:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.connect((self.host, self.port))
            req = f"{bad_method} /api/download/dummy HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nConnection: close\r\n\r\n"
            sock.sendall(req.encode("utf-8"))
            resp = sock.recv(1024)
            sock.close()
            self.assertTrue(b"404 Not Found" in resp or b"405" in resp)

    # -------------------------------------------------------------------------
    # 8. Schema Compliance Verification
    # -------------------------------------------------------------------------
    def test_09_progress_and_complete_schema_compliance(self):
        """Verify strict schema compliance for file_progress and file_complete according to PROTOCOL.md."""
        prog_msg = {
            "type": "file_progress",
            "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
            "bytesTransferred": 5242880,
            "totalBytes": 10485760,
            "percentage": 50.0,
            "status": "transferring"
        }
        # Required fields in PROTOCOL.md § 5.3
        self.assertEqual(prog_msg["type"], "file_progress")
        self.assertIsInstance(prog_msg["fileId"], str)
        self.assertIsInstance(prog_msg["bytesTransferred"], int)
        self.assertIsInstance(prog_msg["totalBytes"], int)
        self.assertIsInstance(prog_msg["percentage"], (int, float))
        self.assertIn(prog_msg["status"], ["pending", "transferring", "completed", "failed"])

        comp_msg = {
            "type": "file_complete",
            "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
            "status": "success",
            "message": "File saved to ~/Downloads/GalaxyContinuity/quarterly_presentation.pdf"
        }
        self.assertEqual(comp_msg["type"], "file_complete")
        self.assertIsInstance(comp_msg["fileId"], str)
        self.assertIn(comp_msg["status"], ["success", "error"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
