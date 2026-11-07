"""
Galaxy Continuity — E2E Test Harness
Opaque-box test harness implementing RFC 6455 WebSocket framing,
HTTP upload/download endpoints, simulated macOS server, Android client mocks,
BLE/mDNS discovery helpers, and build/release verification.

Zero external dependencies (pure Python 3 standard library).
"""

import base64
import hashlib
import io
import json
import os
import random
import select
import shutil
import socket
import struct
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Tuple, Union

# RFC 6455 WebSocket GUID
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Default Continuity constants
DEFAULT_PORT = 8765
SERVICE_TYPE = "_galaxycontinuity._tcp."
BLE_SERVICE_UUID = "19B10000-E8F2-537E-4F6C-D104768A1214"
WIFI_DIRECT_DEFAULT_IP = "192.168.49.1"


# -----------------------------------------------------------------------------
# 1. Low-level RFC 6455 WebSocket Frame Encoding & Decoding
# -----------------------------------------------------------------------------

def encode_ws_frame(opcode: int, payload: bytes, masked: bool = True, mask_key: Optional[bytes] = None) -> bytes:
    """Encode an RFC 6455 WebSocket frame."""
    frame = bytearray()
    # Byte 0: FIN (1) + RSV (0) + Opcode (4 bits)
    frame.append(0x80 | (opcode & 0x0F))

    length = len(payload)
    mask_bit = 0x80 if masked else 0x00

    if length <= 125:
        frame.append(mask_bit | length)
    elif length <= 65535:
        frame.append(mask_bit | 126)
        frame.extend(struct.pack(">H", length))
    else:
        frame.append(mask_bit | 127)
        frame.extend(struct.pack(">Q", length))

    if masked:
        if mask_key is None:
            mask_key = os.urandom(4)
        elif len(mask_key) != 4:
            raise ValueError("mask_key must be exactly 4 bytes")
        frame.extend(mask_key)

        # XOR payload with mask
        masked_payload = bytearray(length)
        for i in range(length):
            masked_payload[i] = payload[i] ^ mask_key[i % 4]
        frame.extend(masked_payload)
    else:
        frame.extend(payload)

    return bytes(frame)


def decode_ws_frame(data: bytes) -> Tuple[Optional[int], Optional[bytes], int]:
    """
    Decode a single RFC 6455 WebSocket frame from bytes buffer.
    Returns: (opcode, payload, bytes_consumed)
    If buffer does not contain a complete frame, returns (None, None, 0).
    """
    if len(data) < 2:
        return None, None, 0

    b0 = data[0]
    b1 = data[1]

    opcode = b0 & 0x0F
    is_masked = bool(b1 & 0x80)
    payload_len = b1 & 0x7F
    offset = 2

    if payload_len == 126:
        if len(data) < offset + 2:
            return None, None, 0
        payload_len = struct.unpack(">H", data[offset:offset + 2])[0]
        offset += 2
    elif payload_len == 127:
        if len(data) < offset + 8:
            return None, None, 0
        payload_len = struct.unpack(">Q", data[offset:offset + 8])[0]
        offset += 8

    if is_masked:
        if len(data) < offset + 4:
            return None, None, 0
        mask_key = data[offset:offset + 4]
        offset += 4

    if len(data) < offset + payload_len:
        return None, None, 0

    raw_payload = data[offset:offset + payload_len]
    bytes_consumed = offset + payload_len

    if is_masked:
        unmasked = bytearray(payload_len)
        for i in range(payload_len):
            unmasked[i] = raw_payload[i] ^ mask_key[i % 4]
        payload = bytes(unmasked)
    else:
        payload = raw_payload

    return opcode, payload, bytes_consumed


def compute_ws_accept(sec_key: str) -> str:
    """Compute the Sec-WebSocket-Accept header value per RFC 6455."""
    combined = (sec_key + WS_GUID).encode("utf-8")
    sha1_hash = hashlib.sha1(combined).digest()
    return base64.b64encode(sha1_hash).decode("ascii")


# -----------------------------------------------------------------------------
# 2. WebSocket Client (Mock Galaxy Phone or Simulated Client)
# -----------------------------------------------------------------------------

class ContinuityClient:
    """
    Lightweight RFC 6455 WebSocket & HTTP client.
    Connects to macOS Continuity Server or MockContinuityServer.
    """

    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT, timeout: float = 4.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self.read_buffer = bytearray()
        self.is_connected = False
        self.handshake_ack: Optional[Dict[str, Any]] = None

    def connect(self, device_name: str = "Samsung Galaxy S24 Ultra", send_initial_handshake: bool = True) -> Dict[str, Any]:
        """Perform TCP connection, RFC 6455 WebSocket upgrade, and receive handshake_ack."""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect((self.host, self.port))

        raw_key = os.urandom(16)
        ws_key = base64.b64encode(raw_key).decode("ascii")
        expected_accept = compute_ws_accept(ws_key)

        request = (
            f"GET /ws HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode("utf-8"))

        # Read HTTP 101 response
        response_bytes = bytearray()
        while b"\r\n\r\n" not in response_bytes:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("Server closed connection during WebSocket handshake")
            response_bytes.extend(chunk)

        header_end = response_bytes.index(b"\r\n\r\n") + 4
        headers_str = response_bytes[:header_end].decode("utf-8", errors="replace")
        self.read_buffer.extend(response_bytes[header_end:])

        lines = headers_str.split("\r\n")
        status_line = lines[0]
        if "101" not in status_line:
            raise ConnectionError(f"WebSocket upgrade rejected by server: {status_line}")

        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        server_accept = headers.get("sec-websocket-accept", "")
        if server_accept != expected_accept:
            raise ConnectionError(f"Invalid Sec-WebSocket-Accept. Expected {expected_accept}, got {server_accept}")

        self.is_connected = True

        # Read the immediate handshake_ack from server
        ack_msg = self.recv_json(timeout=self.timeout)
        self.handshake_ack = ack_msg

        if send_initial_handshake:
            self.send_json({
                "type": "handshake",
                "device": device_name,
                "platform": "android",
                "version": "1.0.0",
                "battery": {"level": 95, "isCharging": False}
            })

        return ack_msg

    def send_frame(self, opcode: int, payload: bytes, masked: bool = True, mask_key: Optional[bytes] = None):
        """Send a single WebSocket frame."""
        if not self.sock:
            raise ConnectionError("Client is not connected")
        frame_bytes = encode_ws_frame(opcode, payload, masked=masked, mask_key=mask_key)
        self.sock.sendall(frame_bytes)

    def send_json(self, message: Dict[str, Any], masked: bool = True):
        """Send a JSON text message (opcode 0x1)."""
        payload = json.dumps(message).encode("utf-8")
        self.send_frame(0x1, payload, masked=masked)

    def send_binary(self, data: bytes, masked: bool = True):
        """Send a binary frame (opcode 0x2)."""
        self.send_frame(0x2, data, masked=masked)

    def send_ping(self, payload: bytes = b"heartbeat", masked: bool = True):
        """Send a ping control frame (opcode 0x9)."""
        self.send_frame(0x9, payload, masked=masked)

    def send_pong(self, payload: bytes = b"", masked: bool = True):
        """Send a pong control frame (opcode 0xA)."""
        self.send_frame(0xA, payload, masked=masked)

    def send_close(self, code: int = 1000, reason: str = ""):
        """Send a close frame (opcode 0x8)."""
        payload = struct.pack(">H", code) + reason.encode("utf-8")
        try:
            self.send_frame(0x8, payload, masked=True)
        except Exception:
            pass

    def recv_frame(self, timeout: Optional[float] = None) -> Tuple[int, bytes]:
        """Receive the next WebSocket frame, automatically replying to pings."""
        deadline = time.time() + (timeout if timeout is not None else self.timeout)
        while True:
            opcode, payload, consumed = decode_ws_frame(self.read_buffer)
            if opcode is not None:
                del self.read_buffer[:consumed]
                if opcode == 0x9:  # Ping -> reply Pong
                    self.send_pong(payload)
                    continue
                return opcode, payload

            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("Timeout waiting for WebSocket frame")

            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(4096)
                if not chunk:
                    raise ConnectionResetError("Connection closed by peer")
                self.read_buffer.extend(chunk)
            except socket.timeout:
                raise TimeoutError("Timeout waiting for WebSocket frame")

    def recv_json(self, timeout: Optional[float] = None) -> Dict[str, Any]:
        """Receive the next text frame and parse JSON."""
        opcode, payload = self.recv_frame(timeout=timeout)
        if opcode != 0x1:
            raise ValueError(f"Expected text frame (0x1), got opcode 0x{opcode:X}")
        return json.loads(payload.decode("utf-8"))

    def drain_messages(self, timeout: float = 0.05) -> List[Dict[str, Any]]:
        """Drain any currently pending JSON messages."""
        messages = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.recv_json(timeout=0.02)
                messages.append(msg)
            except Exception:
                break
        return messages

    def expect_message(self, message_type: str, timeout: Optional[float] = None, predicate: Optional[Any] = None) -> Dict[str, Any]:
        """Wait until a message with specified 'type' arrives and matches optional predicate."""
        deadline = time.time() + (timeout if timeout is not None else self.timeout)
        while time.time() < deadline:
            remaining = max(0.05, deadline - time.time())
            try:
                msg = self.recv_json(timeout=remaining)
                if msg.get("type") == message_type:
                    if predicate is None or predicate(msg):
                        return msg
            except Exception:
                pass
        raise TimeoutError(f"Did not receive message of type '{message_type}' within timeout")

    def close(self):
        """Close client connection cleanly."""
        self.is_connected = False
        if self.sock:
            try:
                self.send_close()
            except Exception:
                pass
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.read_buffer.clear()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


# -----------------------------------------------------------------------------
# 3. HTTP Client Helpers
# -----------------------------------------------------------------------------

def _read_http_response(sock: socket.socket) -> Tuple[int, Dict[str, str], bytes]:
    """Read a full HTTP response handling Content-Length and EOF."""
    resp = bytearray()
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            break
        resp.extend(chunk)

    if b"\r\n\r\n" not in resp:
        raise ValueError("Malformed HTTP response or connection closed")

    header_end = resp.index(b"\r\n\r\n")
    headers_str = resp[:header_end].decode("utf-8", errors="replace")
    body = bytearray(resp[header_end + 4:])

    lines = headers_str.split("\r\n")
    status_code = int(lines[0].split()[1])
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()

    content_length = int(headers.get("content-length", "-1"))
    if content_length >= 0:
        while len(body) < content_length:
            chunk = sock.recv(min(4096, content_length - len(body)))
            if not chunk:
                break
            body.extend(chunk)
    else:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            body.extend(chunk)

    return status_code, headers, bytes(body)


def http_get(host: str, port: int, path: str, timeout: float = 3.0) -> Tuple[int, Dict[str, str], bytes]:
    """Execute low-level HTTP GET."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        req = f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
        sock.sendall(req.encode("utf-8"))
        return _read_http_response(sock)
    finally:
        sock.close()


def http_post(host: str, port: int, path: str, body: bytes, headers_extra: Optional[Dict[str, str]] = None, timeout: float = 5.0) -> Tuple[int, Dict[str, str], bytes]:
    """Execute low-level HTTP POST."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        req_lines = [
            f"POST {path} HTTP/1.1",
            f"Host: {host}:{port}",
            f"Content-Length: {len(body)}",
            "Connection: close",
        ]
        if headers_extra:
            for k, v in headers_extra.items():
                req_lines.append(f"{k}: {v}")
        req_header = "\r\n".join(req_lines) + "\r\n\r\n"
        sock.sendall(req_header.encode("utf-8") + body)
        return _read_http_response(sock)
    finally:
        sock.close()


def upload_file(host: str, port: int, filename: Optional[str], content: bytes, percent_encode: bool = True) -> Tuple[int, Dict[str, str], bytes]:
    """Quick Drop Phone -> Mac file upload helper."""
    headers = {}
    if filename is not None:
        if percent_encode:
            encoded_name = urllib.parse.quote(filename)
        else:
            encoded_name = filename
        headers["X-Filename"] = encoded_name
    return http_post(host, port, "/api/upload", content, headers_extra=headers)


def download_file(host: str, port: int, file_id: str) -> Tuple[int, Dict[str, str], bytes]:
    """Quick Drop Mac -> Phone file download helper."""
    return http_get(host, port, f"/api/download/{file_id}")


# -----------------------------------------------------------------------------
# 4. Hermetic In-Process Continuity Server (Full Protocol Simulation)
# -----------------------------------------------------------------------------

class MockContinuityServer:
    """
    High-fidelity, hermetic in-process continuity server replicating
    macOS ServerManager.swift:
      - HTTP Companion endpoint (GET / and GET /companion)
      - Quick Drop uploads (POST /api/upload) with filename collision handling
      - Quick Drop downloads (GET /api/download/:fileId)
      - RFC 6455 WebSocket Upgrade & low-level frame processor
      - 7-bit, 16-bit, and 64-bit frame support
      - Ping / Pong echo
      - JSON schemas: handshake, clipboard, battery_update, ping_device, phone_notification,
        screen_start/stop, camera_start/stop, input_event, input_key
      - Binary frame transport for Screen Mirroring and Continuity Camera
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 0, downloads_dir: Optional[str] = None):
        self.host = host
        self.requested_port = port
        self.port = port
        self.server_sock: Optional[socket.socket] = None
        self.is_running = False
        self.thread: Optional[threading.Thread] = None

        self.downloads_dir = downloads_dir or tempfile.mkdtemp(prefix="galaxy_continuity_downloads_")
        self._owns_temp_dir = downloads_dir is None

        # State tracking
        self.lock = threading.RLock()
        self.clients: Dict[int, socket.socket] = {}
        self.ws_clients: Dict[int, socket.socket] = {}
        self.received_messages: List[Dict[str, Any]] = []
        self.received_binary_frames: List[bytes] = []
        self.uploaded_files: List[Dict[str, Any]] = []
        self.shared_files: Dict[str, Dict[str, Any]] = {}
        self.last_clipboard_text: Optional[str] = None
        self.device_info: Dict[str, Any] = {}
        self.notifications_received: List[Dict[str, Any]] = []
        self.screen_mirroring_active = False
        self.camera_streaming_active = False
        self.camera_lens = "back"
        self.input_events: List[Dict[str, Any]] = []
        self.battery_info: Dict[str, Any] = {"level": 100, "isCharging": False}

    def start(self):
        """Start listening on a background daemon thread."""
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_sock.bind((self.host, self.requested_port))
        self.port = self.server_sock.getsockname()[1]
        self.server_sock.listen(128)
        self.is_running = True

        self.thread = threading.Thread(target=self._run_accept_loop, daemon=True, name="MockServer-Accept")
        self.thread.start()

    def _run_accept_loop(self):
        """Main accept loop."""
        while self.is_running:
            try:
                client_sock, _ = self.server_sock.accept()
            except (OSError, socket.error):
                break

            client_sock.setblocking(True)
            t = threading.Thread(target=self._handle_client, args=(client_sock,), daemon=True)
            t.start()

    def _handle_client(self, sock: socket.socket):
        fd = sock.fileno()
        with self.lock:
            self.clients[fd] = sock

        read_buf = bytearray()
        is_ws = False

        try:
            while self.is_running:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                read_buf.extend(chunk)

                if not is_ws:
                    # HTTP parsing
                    if b"\r\n\r\n" in read_buf:
                        header_end = read_buf.index(b"\r\n\r\n") + 4
                        header_data = bytes(read_buf[:header_end])
                        headers_str = header_data.decode("utf-8", errors="replace")
                        lines = headers_str.split("\r\n")
                        req_line = lines[0].split()
                        if len(req_line) < 2:
                            break
                        method, path = req_line[0], req_line[1]

                        headers = {}
                        for line in lines[1:]:
                            if ":" in line:
                                k, v = line.split(":", 1)
                                headers[k.strip().lower()] = v.strip()

                        # Check for WebSocket Upgrade
                        if headers.get("upgrade", "").lower() == "websocket" and "sec-websocket-key" in headers:
                            sec_key = headers["sec-websocket-key"]
                            accept_key = compute_ws_accept(sec_key)
                            resp = (
                                "HTTP/1.1 101 Switching Protocols\r\n"
                                "Upgrade: websocket\r\n"
                                "Connection: Upgrade\r\n"
                                f"Sec-WebSocket-Accept: {accept_key}\r\n\r\n"
                            )
                            sock.sendall(resp.encode("utf-8"))
                            is_ws = True
                            with self.lock:
                                self.ws_clients[fd] = sock

                            # Send handshake_ack
                            ack = {
                                "type": "handshake_ack",
                                "device": "MacBook Pro",
                                "platform": "macOS",
                                "version": "1.0.0",
                                "timestamp": time.time() * 1000
                            }
                            ack_bytes = encode_ws_frame(0x1, json.dumps(ack).encode("utf-8"), masked=False)
                            sock.sendall(ack_bytes)

                            # If server has modest shared clipboard text, send it
                            with self.lock:
                                last_clip = self.last_clipboard_text
                            if last_clip and len(last_clip) < 65536:
                                clip_msg = {
                                    "type": "clipboard",
                                    "content": last_clip,
                                    "contentType": "text/plain",
                                    "source": "mac",
                                    "timestamp": time.time() * 1000
                                }
                                clip_frame = encode_ws_frame(0x1, json.dumps(clip_msg).encode("utf-8"), masked=False)
                                try:
                                    sock.sendall(clip_frame)
                                except Exception:
                                    pass

                            del read_buf[:header_end]
                            continue

                        # POST /api/upload
                        elif method == "POST" and path == "/api/upload":
                            content_length = int(headers.get("content-length", "0"))
                            if len(read_buf) >= header_end + content_length:
                                file_payload = bytes(read_buf[header_end:header_end + content_length])
                                del read_buf[:header_end + content_length]

                                raw_filename = headers.get("x-filename")
                                if raw_filename:
                                    filename = urllib.parse.unquote(raw_filename)
                                else:
                                    filename = f"Received_File_{int(time.time() * 1000)}.bin"

                                saved_path = self._save_uploaded_file(filename, file_payload)
                                with self.lock:
                                    self.uploaded_files.append({
                                        "filename": os.path.basename(saved_path),
                                        "path": saved_path,
                                        "size": len(file_payload)
                                    })

                                is_close = headers.get("connection", "").lower() == "close"
                                conn_hdr = "close" if is_close else "keep-alive"
                                resp = (
                                    "HTTP/1.1 200 OK\r\n"
                                    "Content-Type: application/json\r\n"
                                    f"Connection: {conn_hdr}\r\n"
                                    "Content-Length: 15\r\n\r\n"
                                    "{\"status\":\"ok\"}"
                                )
                                sock.sendall(resp.encode("utf-8"))
                                if is_close:
                                    break
                            continue

                        # GET / or /companion
                        elif method == "GET" and (path == "/" or path == "/companion" or path.startswith("/?")):
                            del read_buf[:]
                            html = (
                                "<!DOCTYPE html><html><head><title>Galaxy Continuity</title></head>"
                                "<body><h1>Galaxy Continuity Web Companion</h1></body></html>"
                            ).encode("utf-8")
                            resp = (
                                f"HTTP/1.1 200 OK\r\n"
                                f"Content-Type: text/html; charset=utf-8\r\n"
                                f"Connection: close\r\n"
                                f"Content-Length: {len(html)}\r\n\r\n"
                            ).encode("utf-8") + html
                            sock.sendall(resp)
                            break

                        # GET /api/download/:fileId
                        elif method == "GET" and path.startswith("/api/download/"):
                            del read_buf[:]
                            file_id = path[len("/api/download/"):]
                            with self.lock:
                                file_info = self.shared_files.get(file_id)

                            if file_info and os.path.exists(file_info["path"]):
                                with open(file_info["path"], "rb") as f:
                                    content = f.read()
                                enc_name = urllib.parse.quote(file_info["filename"])
                                resp = (
                                    f"HTTP/1.1 200 OK\r\n"
                                    f"Content-Type: application/octet-stream\r\n"
                                    f"Content-Disposition: attachment; filename=\"{enc_name}\"\r\n"
                                    f"Content-Length: {len(content)}\r\n\r\n"
                                ).encode("utf-8") + content
                                sock.sendall(resp)
                            else:
                                resp = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                                sock.sendall(resp)
                            break

                        # Fallback 404
                        else:
                            del read_buf[:]
                            resp = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                            sock.sendall(resp)
                            break

                else:
                    # WebSocket frame parsing
                    while True:
                        opcode, payload, consumed = decode_ws_frame(read_buf)
                        if opcode is None:
                            break
                        del read_buf[:consumed]

                        if opcode == 0x1:  # Text frame (JSON)
                            try:
                                text = payload.decode("utf-8")
                                msg = json.loads(text)
                                self._dispatch_ws_message(msg, sock)
                            except Exception:
                                pass  # Malformed JSON dropped gracefully
                        elif opcode == 0x2:  # Binary frame
                            with self.lock:
                                self.received_binary_frames.append(payload)
                        elif opcode == 0x8:  # Close
                            reply_close = encode_ws_frame(0x8, payload[:2], masked=False)
                            try:
                                sock.sendall(reply_close)
                            except Exception:
                                pass
                            return
                        elif opcode == 0x9:  # Ping -> reply Pong
                            pong = encode_ws_frame(0xA, payload, masked=False)
                            sock.sendall(pong)
                        elif opcode == 0xA:  # Pong
                            pass

        except (ConnectionError, socket.error):
            pass
        finally:
            with self.lock:
                self.clients.pop(fd, None)
                self.ws_clients.pop(fd, None)
            try:
                sock.close()
            except Exception:
                pass

    def _save_uploaded_file(self, filename: str, data: bytes) -> str:
        """Handle duplicate filename collision by appending (1), (2), etc."""
        os.makedirs(self.downloads_dir, exist_ok=True)
        safe_filename = os.path.basename(filename)
        if not safe_filename:
            safe_filename = f"Received_File_{int(time.time() * 1000)}.bin"
        base, ext = os.path.splitext(safe_filename)
        candidate = os.path.join(self.downloads_dir, safe_filename)
        counter = 1
        while os.path.exists(candidate):
            new_name = f"{base} ({counter}){ext}"
            candidate = os.path.join(self.downloads_dir, new_name)
            counter += 1

        with open(candidate, "wb") as f:
            f.write(data)
        return candidate

    def _dispatch_ws_message(self, msg: Dict[str, Any], sock: socket.socket):
        """Process incoming WebSocket JSON messages."""
        msg_type = msg.get("type")
        with self.lock:
            self.received_messages.append(msg)

            if msg_type == "handshake":
                self.device_info = msg
            elif msg_type == "clipboard":
                # Loop prevention check: do not echo identical content
                content = msg.get("content")
                if content != self.last_clipboard_text:
                    self.last_clipboard_text = content
            elif msg_type == "battery_update":
                self.battery_info = {
                    "level": msg.get("level", 100),
                    "isCharging": msg.get("charging", msg.get("isCharging", False))
                }
            elif msg_type == "phone_notification":
                self.notifications_received.append(msg)
            elif msg_type == "screen_start":
                self.screen_mirroring_active = True
            elif msg_type == "screen_stop":
                self.screen_mirroring_active = False
            elif msg_type == "camera_start":
                self.camera_streaming_active = True
                self.camera_lens = msg.get("facing", "back")
            elif msg_type == "camera_stop":
                self.camera_streaming_active = False
            elif msg_type == "camera_switch_lens":
                self.camera_lens = msg.get("facing", "front")
            elif msg_type in ("input_event", "input_key"):
                self.input_events.append(msg)

    def broadcast_message(self, msg: Dict[str, Any]):
        """Send unmasked WebSocket text frame to all connected clients."""
        payload = json.dumps(msg).encode("utf-8")
        frame = encode_ws_frame(0x1, payload, masked=False)
        with self.lock:
            dead = []
            for fd, sock in self.ws_clients.items():
                try:
                    sock.sendall(frame)
                except Exception:
                    dead.append(fd)
            for fd in dead:
                self.ws_clients.pop(fd, None)
                self.clients.pop(fd, None)

    def broadcast_binary(self, data: bytes):
        """Send unmasked WebSocket binary frame to all connected clients."""
        frame = encode_ws_frame(0x2, data, masked=False)
        with self.lock:
            dead = []
            for fd, sock in self.ws_clients.items():
                try:
                    sock.sendall(frame)
                except Exception:
                    dead.append(fd)
            for fd in dead:
                self.ws_clients.pop(fd, None)
                self.clients.pop(fd, None)

    def share_file(self, file_path: str, filename: Optional[str] = None) -> str:
        """Register a file for download and broadcast 'file_available'."""
        file_id = str(uuid.uuid4())
        fname = filename or os.path.basename(file_path)
        size = os.path.getsize(file_path)

        with self.lock:
            self.shared_files[file_id] = {
                "filename": fname,
                "path": file_path,
                "size": size
            }

        msg = {
            "type": "file_available",
            "fileId": file_id,
            "filename": fname,
            "fileSize": size,
            "mimeType": "application/octet-stream",
            "sender": "MacBook Pro"
        }
        self.broadcast_message(msg)
        return file_id

    def set_mac_clipboard(self, text: str):
        """Simulate user copying text on macOS."""
        with self.lock:
            self.last_clipboard_text = text
        msg = {
            "type": "clipboard",
            "content": text,
            "contentType": "text/plain",
            "source": "mac",
            "timestamp": time.time() * 1000
        }
        self.broadcast_message(msg)

    def stop(self):
        """Stop server and disconnect all clients."""
        self.is_running = False
        if self.server_sock:
            try:
                self.server_sock.close()
            except Exception:
                pass
        with self.lock:
            for sock in list(self.clients.values()):
                try:
                    sock.close()
                except Exception:
                    pass
            self.clients.clear()
            self.ws_clients.clear()

        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=1.0)

        if self._owns_temp_dir and os.path.exists(self.downloads_dir):
            try:
                shutil.rmtree(self.downloads_dir)
            except Exception:
                pass

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()


# -----------------------------------------------------------------------------
# 5. Media Stream Packet Generators (Screen Mirroring & Continuity Camera)
# -----------------------------------------------------------------------------

def make_stream_packet(stream_type: int, frame_type: int, seq: int, payload: bytes) -> bytes:
    """
    Construct 4-byte stream packet header + payload:
      - Byte 0: Stream Type (0x01 = Screen, 0x02 = Camera)
      - Byte 1: Frame Type (0x01 = IDR Keyframe, 0x02 = P-Frame)
      - Bytes 2-3: 16-bit Big-Endian sequence counter
      - Bytes 4+: Raw video payload (H.264 NAL or JPEG)
    """
    header = struct.pack(">BBH", stream_type, frame_type, seq & 0xFFFF)
    return header + payload


def parse_stream_packet(packet: bytes) -> Dict[str, Any]:
    """Parse 4-byte stream header."""
    if len(packet) < 4:
        raise ValueError("Packet too short for stream header")
    stream_type, frame_type, seq = struct.unpack(">BBH", packet[:4])
    return {
        "stream_type": stream_type,
        "frame_type": frame_type,
        "sequence": seq,
        "payload": packet[4:]
    }


def make_mock_h264_nal(nal_type: int = 5, size: int = 512) -> bytes:
    """Construct synthetic Annex B H.264 NAL unit: 0x00000001 + header + padding."""
    prefix = b"\x00\x00\x00\x01"
    # NAL header: forbidden_zero_bit (0), nal_ref_idc (3), nal_unit_type (nal_type & 0x1F)
    nal_header = bytes([(3 << 5) | (nal_type & 0x1F)])
    body = os.urandom(max(0, size - 5))
    return prefix + nal_header + body


def make_mock_jpeg(width: int = 320, height: int = 240) -> bytes:
    """Construct minimal synthetic JPEG image with SOI, APP0, SOF0, SOS, and EOI."""
    soi = b"\xFF\xD8"
    app0 = b"\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = struct.pack(">2sHBHHB", b"\xFF\xC0", 11, 8, height, width, 1) + b"\x01\x11\x00"
    sos = b"\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00"
    scan_data = b"\x00" * 64
    eoi = b"\xFF\xD9"
    return soi + app0 + sof0 + sos + scan_data + eoi


# -----------------------------------------------------------------------------
# 6. Discovery & Offline Simulation Helpers (BLE, mDNS, Wi-Fi Direct)
# -----------------------------------------------------------------------------

class MockBleAdvertiser:
    """Simulates CoreBluetooth / Android BLE advertising packet construction and parsing."""

    def __init__(self, service_uuid: str = BLE_SERVICE_UUID, port: int = DEFAULT_PORT):
        self.service_uuid = service_uuid
        self.port = port

    def build_advertisement_data(self, device_id: bytes = b"\xDE\xAD\xBE\xEF", flags: int = 0x03) -> Dict[str, Any]:
        """
        Build simulated BLE advertisement payload:
          - 128-bit Service UUID
          - Manufacturer / Service Data: 4-byte Short Device ID + 2-byte port + 1-byte flags
        """
        payload = device_id[:4] + struct.pack(">H", self.port) + bytes([flags])
        return {
            "service_uuid": self.service_uuid,
            "service_data": payload,
            "flags": flags,
            "port": self.port,
            "short_id": device_id[:4].hex()
        }

    @staticmethod
    def parse_advertisement_data(advertisement: Dict[str, Any]) -> Dict[str, Any]:
        raw_data = advertisement.get("service_data", b"")
        if len(raw_data) < 7:
            raise ValueError("BLE service data payload too short")
        short_id = raw_data[:4]
        port = struct.unpack(">H", raw_data[4:6])[0]
        flags = raw_data[6]
        return {
            "short_id": short_id.hex(),
            "port": port,
            "is_ready": bool(flags & 0x01),
            "wifi_direct_available": bool(flags & 0x02)
        }


class MockMdnsRecord:
    """Simulates Bonjour / mDNS service registration record."""

    def __init__(self, name: str = "Galaxy Continuity (MacBook Pro)", port: int = DEFAULT_PORT, platform: str = "macOS"):
        self.service_type = SERVICE_TYPE
        self.domain = "local."
        self.name = name
        self.port = port
        self.txt_records = {
            "name": name,
            "platform": platform,
            "version": "1.0.0"
        }

    def resolve(self, host: str = "127.0.0.1") -> Dict[str, Any]:
        return {
            "service_type": self.service_type,
            "name": self.name,
            "host": host,
            "port": self.port,
            "txt": dict(self.txt_records)
        }


# -----------------------------------------------------------------------------
# 7. Android APK & GitHub Release Simulation Helpers
# -----------------------------------------------------------------------------

class MockApkVerifier:
    """Verifies Android project build configuration and APK structure."""

    @staticmethod
    def verify_android_project_files(project_root: str) -> Dict[str, bool]:
        android_dir = os.path.join(project_root, "android")
        results = {
            "android_dir_exists": os.path.isdir(android_dir),
            "build_gradle_exists": os.path.isfile(os.path.join(android_dir, "build.gradle.kts")),
            "app_build_gradle_exists": os.path.isfile(os.path.join(android_dir, "app", "build.gradle.kts")),
            "manifest_exists": os.path.isfile(os.path.join(android_dir, "app", "src", "main", "AndroidManifest.xml")),
            "wrapper_props_exists": os.path.isfile(os.path.join(android_dir, "gradle", "wrapper", "gradle-wrapper.properties")),
        }
        return results

    @staticmethod
    def create_mock_apk(target_path: str, app_id: str = "com.galaxycontinuity.app", version_name: str = "1.0.0") -> str:
        """Create a valid zip-formatted mock APK file with minimal Android manifest."""
        import zipfile
        os.makedirs(os.path.dirname(os.path.abspath(target_path)), exist_ok=True)
        with zipfile.ZipFile(target_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("AndroidManifest.xml", f"<manifest package='{app_id}' version='{version_name}'/>".encode("utf-8"))
            zf.writestr("classes.dex", b"dex\n035\x00" + os.urandom(128))
            zf.writestr("resources.arsc", b"\x02\x00\x0c\x00" + os.urandom(64))
            zf.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\nCreated-By: GalaxyContinuityBuild\n")
        return target_path


class MockGitHubReleaseClient:
    """Simulates and verifies GitHub Release creation via GitHub API or CLI semantics."""

    def __init__(self, repo: str = "savvakarayl-coder/galaxy-continuity"):
        self.repo = repo
        self.releases: Dict[str, Dict[str, Any]] = {}

    def create_release(self, tag: str, title: str, notes: str, asset_paths: List[str]) -> Dict[str, Any]:
        if not tag:
            raise ValueError("Tag name cannot be empty")
        if tag in self.releases:
            raise ValueError(f"Release with tag '{tag}' already exists")

        validated_assets = []
        for p in asset_paths:
            if not os.path.exists(p):
                raise FileNotFoundError(f"Asset file not found: {p}")
            validated_assets.append({
                "name": os.path.basename(p),
                "size": os.path.getsize(p),
                "path": p
            })

        release_data = {
            "repo": self.repo,
            "tag": tag,
            "title": title,
            "notes": notes,
            "assets": validated_assets,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "html_url": f"https://github.com/{self.repo}/releases/tag/{tag}"
        }
        self.releases[tag] = release_data
        return release_data


# -----------------------------------------------------------------------------
# 8. Test Harness Fixture Context Manager
# -----------------------------------------------------------------------------

class ContinuityTestHarness:
    """
    Unified Test Fixture for E2E tests.
    Spawns an isolated MockContinuityServer (or connects to live server if specified),
    provides easy client creation, and cleans up resources.
    """

    def __init__(self, port: int = 0, downloads_dir: Optional[str] = None):
        self.server = MockContinuityServer(port=port, downloads_dir=downloads_dir)
        self.clients: List[ContinuityClient] = []

    def __enter__(self):
        self.server.start()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        for c in self.clients:
            try:
                c.close()
            except Exception:
                pass
        self.clients.clear()
        self.server.stop()

    @property
    def host(self) -> str:
        return self.server.host

    @property
    def port(self) -> int:
        return self.server.port

    def create_client(self, connect: bool = True, device_name: str = "Samsung Galaxy S24 Ultra") -> ContinuityClient:
        """Create and track a client instance."""
        client = ContinuityClient(host=self.host, port=self.port)
        if connect:
            client.connect(device_name=device_name)
        self.clients.append(client)
        return client
