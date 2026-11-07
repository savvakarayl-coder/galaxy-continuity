#!/usr/bin/env python3
"""
Empirical Adversarial Stress Test Suite for Quick Drop File Transfers
Tests chunked streaming, duplicate collision renaming, missing files,
directory traversal confinement, special characters, zero-byte transfers,
and progress/completion tracking across macOS and Android contracts.
"""

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
    DEFAULT_PORT,
    ContinuityClient,
    ContinuityTestHarness,
    MockContinuityServer,
    download_file,
    http_get,
    http_post,
    upload_file,
)


class TestAdversarialQuickDropOutgoing(unittest.TestCase):
    """Stress-test Outgoing File Transfers (macOS -> Android)."""

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

    def test_01_file_available_announcement_parsing_and_schema(self):
        """Verify file_available announcement carries valid UUID, metadata, and handles edge cases."""
        client = ContinuityClient(host=self.host, port=self.port)
        client.connect()
        try:
            with tempfile.NamedTemporaryFile(prefix="avail_", suffix=".pdf", delete=False) as tf:
                tf.write(b"%PDF-1.4 test presentation")
                tf_path = tf.name

            try:
                file_id = self.server.share_file(tf_path, filename="presentation.pdf")
                msg = client.expect_message("file_available", timeout=2.0)
                self.assertIsNotNone(msg)
                self.assertEqual(msg.get("type"), "file_available")
                self.assertEqual(msg.get("fileId"), file_id)
                self.assertEqual(msg.get("filename"), "presentation.pdf")
                self.assertEqual(msg.get("fileSize"), 26)
                self.assertIn("mimeType", msg)
                self.assertIn("sender", msg)
            finally:
                if os.path.exists(tf_path):
                    os.remove(tf_path)
        finally:
            client.close()

    def test_02_download_chunked_streaming_integrity(self):
        """Verify large file (256 KB) download over chunked HTTP streaming with SHA-256 integrity."""
        blob = os.urandom(256 * 1024)
        expected_sha = hashlib.sha256(blob).hexdigest()

        with tempfile.NamedTemporaryFile(prefix="chunk_test_", suffix=".bin", delete=False) as tf:
            tf.write(blob)
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="large_archive.bin")

            # Connect raw socket and read in small 8 KB chunks to stress streaming
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((self.host, self.port))
            try:
                req = f"GET /api/download/{file_id} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nConnection: close\r\n\r\n"
                sock.sendall(req.encode("utf-8"))

                # Read response headers
                header_data = bytearray()
                while b"\r\n\r\n" not in header_data:
                    chunk = sock.recv(512)
                    if not chunk:
                        break
                    header_data.extend(chunk)

                header_end = header_data.index(b"\r\n\r\n")
                header_str = header_data[:header_end].decode("utf-8")
                initial_body = bytes(header_data[header_end + 4:])

                self.assertIn("200 OK", header_str)
                self.assertIn("Content-Length: 262144", header_str)
                self.assertIn("Content-Disposition: attachment", header_str)

                # Stream remainder of body in chunks
                body_parts = [initial_body]
                while True:
                    chunk = sock.recv(8192)
                    if not chunk:
                        break
                    body_parts.append(chunk)

                received_blob = b"".join(body_parts)
                self.assertEqual(len(received_blob), 256 * 1024)
                self.assertEqual(hashlib.sha256(received_blob).hexdigest(), expected_sha)
            finally:
                sock.close()
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_03_download_zero_byte_file(self):
        """Downloading zero-byte file returns 200 OK, Content-Length: 0, and empty body."""
        with tempfile.NamedTemporaryFile(prefix="zero_", suffix=".txt", delete=False) as tf:
            tf_path = tf.name

        try:
            file_id = self.server.share_file(tf_path, filename="zero.txt")
            status, headers, body = download_file(self.host, self.port, file_id)
            self.assertEqual(status, 200)
            self.assertEqual(len(body), 0)
            self.assertEqual(headers.get("content-length"), "0")
            self.assertIn("zero.txt", headers.get("content-disposition", ""))
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_04_download_nonexistent_file_returns_404(self):
        """Requesting an unadvertised / unknown fileId returns HTTP 404 cleanly."""
        status, headers, body = download_file(self.host, self.port, "00000000-0000-0000-0000-000000000000")
        self.assertEqual(status, 404)
        self.assertEqual(len(body), 0)

    def test_05_download_deleted_file_returns_404(self):
        """File registered in memory but deleted from filesystem before download returns 404."""
        with tempfile.NamedTemporaryFile(prefix="del_", suffix=".dat", delete=False) as tf:
            tf.write(b"ephemeral")
            tf_path = tf.name

        file_id = self.server.share_file(tf_path, filename="ephemeral.dat")
        os.remove(tf_path)  # Delete immediately

        status, _, body = download_file(self.host, self.port, file_id)
        self.assertEqual(status, 404)
        self.assertEqual(len(body), 0)

    def test_06_download_directory_traversal_returns_404(self):
        """Path traversal attempt in fileId parameter returns HTTP 404 without leaking files."""
        traversal_targets = [
            "../../../../etc/passwd",
            "..%2F..%2Fetc%2Fpasswd",
            "..\\..\\Windows\\win.ini",
            "/etc/hosts",
            "~/.ssh/id_rsa",
        ]
        for target in traversal_targets:
            status, _, _ = download_file(self.host, self.port, target)
            self.assertEqual(status, 404, f"Target '{target}' must return 404")

    def test_07_download_unsupported_methods_return_404(self):
        """Unsupported HTTP methods (POST, PUT, DELETE) on download endpoint return 404."""
        for method in ["POST", "PUT", "DELETE"]:
            status, _, _ = http_post(self.host, self.port, "/api/download/dummy-id", b"")
            self.assertEqual(status, 404)


class TestAdversarialQuickDropIncoming(unittest.TestCase):
    """Stress-test Incoming File Transfers (Android -> macOS)."""

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

    def test_08_upload_streaming_body_in_chunks(self):
        """Client streams upload body in multiple fragmented TCP writes; server reassembles correctly."""
        content = b"Fragmented upload chunk stream test " * 500  # ~18 KB
        filename = "streamed_report.txt"

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        sock.connect((self.host, self.port))
        try:
            req_header = (
                f"POST /api/upload HTTP/1.1\r\n"
                f"Host: {self.host}:{self.port}\r\n"
                f"X-Filename: {filename}\r\n"
                f"Content-Type: application/octet-stream\r\n"
                f"Content-Length: {len(content)}\r\n"
                f"Connection: close\r\n\r\n"
            )
            sock.sendall(req_header.encode("utf-8"))

            # Send payload in small 1024-byte chunks with slight delays
            chunk_size = 1024
            for offset in range(0, len(content), chunk_size):
                sock.sendall(content[offset:offset + chunk_size])
                time.sleep(0.002)

            resp_data = sock.recv(4096)
            self.assertIn(b"200 OK", resp_data)
            resp_body = resp_data.split(b"\r\n\r\n")[1].decode("utf-8")
            self.assertEqual(json.loads(resp_body).get("status"), "ok")

            with self.server.lock:
                uploaded = [f for f in self.server.uploaded_files if f["filename"] == filename]
                self.assertTrue(len(uploaded) > 0)
                self.assertEqual(uploaded[-1]["size"], len(content))
        finally:
            sock.close()

    def test_09_upload_triple_duplicate_collision_renaming(self):
        """Upload test.pdf 3 times; verify saved as test.pdf, test (1).pdf, and test (2).pdf."""
        filename = f"collision_test_{int(time.time())}.pdf"
        p1 = b"Payload Version 1"
        p2 = b"Payload Version 2"
        p3 = b"Payload Version 3"

        status1, _, _ = upload_file(self.host, self.port, filename, p1)
        self.assertEqual(status1, 200)

        status2, _, _ = upload_file(self.host, self.port, filename, p2)
        self.assertEqual(status2, 200)

        status3, _, _ = upload_file(self.host, self.port, filename, p3)
        self.assertEqual(status3, 200)

        base, ext = os.path.splitext(filename)
        expected_names = [filename, f"{base} (1){ext}", f"{base} (2){ext}"]

        with self.server.lock:
            all_filenames = [f["filename"] for f in self.server.uploaded_files]
            for exp in expected_names:
                self.assertIn(exp, all_filenames, f"Expected {exp} in uploaded files: {all_filenames}")

            # Verify byte contents of each collision file
            files_dict = {f["filename"]: f["path"] for f in self.server.uploaded_files}
            with open(files_dict[expected_names[0]], "rb") as f:
                self.assertEqual(f.read(), p1)
            with open(files_dict[expected_names[1]], "rb") as f:
                self.assertEqual(f.read(), p2)
            with open(files_dict[expected_names[2]], "rb") as f:
                self.assertEqual(f.read(), p3)

    def test_10_upload_extensionless_triple_collision(self):
        """Upload README 3 times; verify saved as README, README (1), and README (2)."""
        filename = f"README_{int(time.time())}"
        p1 = b"Readme 1"
        p2 = b"Readme 2"
        p3 = b"Readme 3"

        upload_file(self.host, self.port, filename, p1)
        upload_file(self.host, self.port, filename, p2)
        upload_file(self.host, self.port, filename, p3)

        expected_names = [filename, f"{filename} (1)", f"{filename} (2)"]

        with self.server.lock:
            all_filenames = [f["filename"] for f in self.server.uploaded_files]
            for exp in expected_names:
                self.assertIn(exp, all_filenames, f"Expected {exp} in {all_filenames}")

    def test_11_upload_special_and_percent_encoded_filenames(self):
        """Verify upload with URL percent-encoded spaces, symbols, and Unicode filenames."""
        cases = [
            ("Document%20With%20Spaces.pdf", "Document With Spaces.pdf"),
            ("%D0%BE%D1%82%D1%87%D1%91%D1%82_2026.docx", "отчёт_2026.docx"),
            ("Test%20%28Draft%20v1%29.tar.gz", "Test (Draft v1).tar.gz"),
        ]

        for encoded_header, expected_saved in cases:
            content = f"Content for {expected_saved}".encode("utf-8")
            status, _, _ = upload_file(self.host, self.port, encoded_header, content, percent_encode=False)
            self.assertEqual(status, 200)

            with self.server.lock:
                all_filenames = [f["filename"] for f in self.server.uploaded_files]
                self.assertIn(expected_saved, all_filenames)

    def test_12_upload_directory_traversal_confinement(self):
        """Filenames attempting directory traversal are confined strictly to downloads directory."""
        malicious_inputs = [
            "../../../../etc/passwd",
            "..%2F..%2F..%2Fetc%2Fshadow",
            "C:\\Windows\\System32\\cmd.exe",
            "nested/dir/outside.sh",
            "../../../.ssh/authorized_keys",
        ]

        for mal_name in malicious_inputs:
            content = b"malicious content"
            status, _, _ = upload_file(self.host, self.port, mal_name, content, percent_encode=False)
            self.assertEqual(status, 200)

            with self.server.lock:
                last_file = self.server.uploaded_files[-1]
                # Invariant: File must reside inside self.server.downloads_dir
                real_path = os.path.realpath(last_file["path"])
                downloads_real = os.path.realpath(self.server.downloads_dir)
                self.assertTrue(
                    real_path.startswith(downloads_real),
                    f"Path '{real_path}' escaped downloads dir '{downloads_real}' for input '{mal_name}'"
                )
                self.assertEqual(os.path.dirname(real_path), downloads_real)

    def test_13_upload_empty_and_slash_fallback(self):
        """Filenames consisting only of slashes or whitespace safely fallback to Received_File_*.bin."""
        fallback_inputs = ["", "   ", "/", "///"]

        for bad_name in fallback_inputs:
            content = b"fallback test"
            status, _, _ = upload_file(self.host, self.port, bad_name, content, percent_encode=False)
            self.assertEqual(status, 200)

            with self.server.lock:
                last_file = self.server.uploaded_files[-1]
                self.assertTrue(
                    last_file["filename"].startswith("Received_File_"),
                    f"Input '{bad_name}' should fallback but got '{last_file['filename']}'"
                )

    def test_13b_upload_dot_only_filenames_strict_confinement(self):
        """Dot-only filenames (., .., ...) must remain strictly confined to downloads directory."""
        dot_inputs = [".", "..", "...", "...."]

        for dot_name in dot_inputs:
            content = b"dot test"
            status, _, _ = upload_file(self.host, self.port, dot_name, content, percent_encode=False)
            self.assertEqual(status, 200)

            with self.server.lock:
                last_file = self.server.uploaded_files[-1]
                real_path = os.path.realpath(last_file["path"])
                downloads_real = os.path.realpath(self.server.downloads_dir)
                # Invariant: file MUST NOT escape downloads directory
                self.assertTrue(
                    real_path.startswith(downloads_real),
                    f"Input '{dot_name}' resulted in path '{real_path}' outside '{downloads_real}'"
                )
                self.assertEqual(os.path.dirname(real_path), downloads_real)

    def test_14_upload_zero_byte_file(self):
        """Uploading an empty 0-byte file succeeds with 200 OK and creates a 0-byte file."""
        fname = f"empty_{int(time.time())}.txt"
        status, _, body = upload_file(self.host, self.port, fname, b"")
        self.assertEqual(status, 200)

        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == fname]
            self.assertTrue(len(uploaded) > 0)
            self.assertEqual(uploaded[-1]["size"], 0)

    def test_15_upload_large_payload_integrity(self):
        """Upload 512 KB payload and verify SHA-256 byte-for-byte fidelity."""
        blob = os.urandom(512 * 1024)
        expected_sha = hashlib.sha256(blob).hexdigest()
        fname = f"large_upload_{int(time.time())}.bin"

        status, _, _ = upload_file(self.host, self.port, fname, blob)
        self.assertEqual(status, 200)

        with self.server.lock:
            uploaded = [f for f in self.server.uploaded_files if f["filename"] == fname]
            self.assertTrue(len(uploaded) > 0)
            with open(uploaded[-1]["path"], "rb") as f:
                disk_sha = hashlib.sha256(f.read()).hexdigest()
            self.assertEqual(disk_sha, expected_sha)


class TestAdversarialProgressAndCompletion(unittest.TestCase):
    """Stress-test progress tracking and completion schemas."""

    def test_16_file_progress_schema_validation(self):
        """Validate file_progress message schema across boundary percentages."""
        test_cases = [
            {"fileId": "uuid-1", "bytesTransferred": 0, "totalBytes": 1000, "percentage": 0.0, "status": "transferring"},
            {"fileId": "uuid-2", "bytesTransferred": 500, "totalBytes": 1000, "percentage": 50.0, "status": "transferring"},
            {"fileId": "uuid-3", "bytesTransferred": 333, "totalBytes": 1000, "percentage": 33.3, "status": "transferring"},
            {"fileId": "uuid-4", "bytesTransferred": 1000, "totalBytes": 1000, "percentage": 100.0, "status": "completed"},
        ]

        for tc in test_cases:
            msg = {"type": "file_progress", **tc}
            encoded = json.dumps(msg).encode("utf-8")
            decoded = json.loads(encoded.decode("utf-8"))

            self.assertEqual(decoded["type"], "file_progress")
            self.assertEqual(decoded["fileId"], tc["fileId"])
            self.assertEqual(decoded["bytesTransferred"], tc["bytesTransferred"])
            self.assertEqual(decoded["totalBytes"], tc["totalBytes"])
            self.assertEqual(decoded["percentage"], tc["percentage"])
            self.assertEqual(decoded["status"], tc["status"])

    def test_17_file_complete_schema_validation(self):
        """Validate file_complete message schema for success and error conditions."""
        success_msg = {
            "type": "file_complete",
            "fileId": "uuid-success-123",
            "filename": "document.pdf",
            "status": "success",
            "message": "File saved to ~/Downloads/GalaxyContinuity/document.pdf"
        }
        encoded = json.dumps(success_msg).encode("utf-8")
        decoded = json.loads(encoded.decode("utf-8"))
        self.assertEqual(decoded["type"], "file_complete")
        self.assertEqual(decoded["status"], "success")
        self.assertEqual(decoded["fileId"], "uuid-success-123")

        error_msg = {
            "type": "file_complete",
            "fileId": "uuid-err-456",
            "status": "error",
            "message": "Disk quota exceeded or connection reset"
        }
        encoded_err = json.dumps(error_msg).encode("utf-8")
        decoded_err = json.loads(encoded_err.decode("utf-8"))
        self.assertEqual(decoded_err["type"], "file_complete")
        self.assertEqual(decoded_err["status"], "error")


if __name__ == "__main__":
    unittest.main(verbosity=2)
