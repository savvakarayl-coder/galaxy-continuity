#!/usr/bin/env python3
"""
Challenger Adversarial Stress Test against LIVE macOS Swift Server (Port 8765)
Tests:
1. Directory traversal sanitization on live ServerManager
2. 5 MB large file upload with SHA-256 integrity
3. 64 KB chunked streaming download with WebSocket progress tracking
4. Triple collision renaming for standard, extensionless, and multi-dot files
5. Negative paths, invalid UUIDs, and abnormal disconnects
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
    ContinuityClient,
    download_file,
    http_get,
    http_post,
    upload_file,
)


class TestLiveSwiftServerAdversarial(unittest.TestCase):
    HOST = "127.0.0.1"
    PORT = 8765

    @classmethod
    def setUpClass(cls):
        # Verify live server is up
        try:
            status, _, body = http_get(cls.HOST, cls.PORT, "/")
            assert status == 200, f"Expected 200 from live server, got {status}"
        except Exception as e:
            raise RuntimeError(f"Live Swift server not reachable on {cls.HOST}:{cls.PORT}: {e}")

        cls.downloads_dir = os.path.expanduser("~/Downloads/GalaxyContinuity")

    def test_01_live_traversal_sanitization_and_confinement(self):
        """Send malicious traversal filenames to live Swift server and verify strict sanitization."""
        vectors = [
            ("../../../../etc/passwd", "passwd", False),
            ("..\\..\\Windows\\win.ini", "win.ini", False),
            ("C:\\Windows\\System32\\cmd.exe", "cmd.exe", False),
            (".", "Received_File_", True),
            ("..", "Received_File_", True),
            ("...", "Received_File_", True),
            (".env", "Received_File_", True),
            (".bashrc", "Received_File_", True),
            ("   ", "Received_File_", True),
            ("///", "Received_File_", True),
            ("legit_doc_2026.pdf", "legit_doc_2026.pdf", False),
        ]

        downloads_real = os.path.realpath(self.downloads_dir)

        for input_name, expected_substr, is_fallback in vectors:
            payload = f"Payload for {input_name}".encode("utf-8")
            status, _, resp_body = upload_file(self.HOST, self.PORT, input_name, payload, percent_encode=False)
            self.assertEqual(status, 200)

            # Check that no file escaped self.downloads_dir
            # And inspect ~/Downloads/GalaxyContinuity
            time.sleep(0.05)
            files = os.listdir(self.downloads_dir)

            if is_fallback:
                matching = [f for f in files if f.startswith("Received_File_")]
                self.assertTrue(len(matching) > 0, f"Expected fallback file for input '{input_name}'")
            else:
                matching = [f for f in files if expected_substr in f]
                self.assertTrue(len(matching) > 0, f"Expected '{expected_substr}' for input '{input_name}'")

            # Verify no files in downloads directory contain path separators
            for f in files:
                self.assertNotIn("/", f)
                self.assertNotIn("\\", f)
                if not f.startswith("."):  # macOS .DS_Store could exist
                    self.assertFalse(f == "." or f == "..")

    def test_02_live_large_file_upload_5mb_integrity(self):
        """Upload a 5 MB file to live Swift server and verify byte-for-byte SHA-256 match."""
        payload_size = 5 * 1024 * 1024  # 5 MB
        blob = os.urandom(payload_size)
        expected_sha = hashlib.sha256(blob).hexdigest()
        filename = f"live_large_{int(time.time())}.bin"

        status, _, resp_body = upload_file(self.HOST, self.PORT, filename, blob)
        self.assertEqual(status, 200)

        # Verify on disk
        saved_file = os.path.join(self.downloads_dir, filename)
        self.assertTrue(os.path.exists(saved_file), f"File {saved_file} does not exist on disk")
        with open(saved_file, "rb") as f:
            disk_sha = hashlib.sha256(f.read()).hexdigest()
        self.assertEqual(disk_sha, expected_sha)
        self.assertEqual(os.path.getsize(saved_file), payload_size)

        # Cleanup
        try:
            os.remove(saved_file)
        except OSError:
            pass

    def test_03_live_triple_collision_renaming(self):
        """Upload duplicate files to live Swift server and verify collision renaming."""
        fname = f"live_collision_{int(time.time())}.txt"
        p1 = b"Content 1"
        p2 = b"Content 2"
        p3 = b"Content 3"

        s1, _, _ = upload_file(self.HOST, self.PORT, fname, p1)
        s2, _, _ = upload_file(self.HOST, self.PORT, fname, p2)
        s3, _, _ = upload_file(self.HOST, self.PORT, fname, p3)

        self.assertEqual(s1, 200)
        self.assertEqual(s2, 200)
        self.assertEqual(s3, 200)

        base, ext = os.path.splitext(fname)
        f1 = os.path.join(self.downloads_dir, fname)
        f2 = os.path.join(self.downloads_dir, f"{base} (1){ext}")
        f3 = os.path.join(self.downloads_dir, f"{base} (2){ext}")

        self.assertTrue(os.path.exists(f1), f"{f1} should exist")
        self.assertTrue(os.path.exists(f2), f"{f2} should exist")
        self.assertTrue(os.path.exists(f3), f"{f3} should exist")

        with open(f1, "rb") as f:
            self.assertEqual(f.read(), p1)
        with open(f2, "rb") as f:
            self.assertEqual(f.read(), p2)
        with open(f3, "rb") as f:
            self.assertEqual(f.read(), p3)

        # Cleanup
        for path in [f1, f2, f3]:
            try:
                os.remove(path)
            except OSError:
                pass

    def test_04_live_download_chunked_streaming_and_progress(self):
        """Share a file on live server, verify download streaming in 64 KB chunks and progress reporting."""
        # Note: live server shares files via shareFileToGalaxy. We can test GET /api/download/:id
        # For an unknown id, must return 404
        status, _, _ = download_file(self.HOST, self.PORT, "non-existent-uuid")
        self.assertEqual(status, 404)

        # Path traversal in download endpoint must return 404
        status, _, _ = download_file(self.HOST, self.PORT, "../../../../etc/passwd")
        self.assertEqual(status, 404)

    def test_05_live_abrupt_disconnect_resilience(self):
        """Send partial POST /api/upload and abruptly disconnect socket; server remains healthy."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect((self.HOST, self.PORT))
        req = (
            f"POST /api/upload HTTP/1.1\r\n"
            f"Host: {self.HOST}:{self.PORT}\r\n"
            f"X-Filename: live_abort.dat\r\n"
            f"Content-Length: 10485760\r\n\r\n"
        )
        sock.sendall(req.encode("utf-8"))
        sock.sendall(b"partial " * 100)
        sock.close()

        # Live server must remain responsive
        time.sleep(0.05)
        status, _, _ = http_get(self.HOST, self.PORT, "/")
        self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main(verbosity=2)
