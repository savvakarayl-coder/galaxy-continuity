# Project: Galaxy Continuity (1:1 Apple Continuity Replacement)

## Architecture
Galaxy Continuity provides seamless continuity between macOS (native Swift 6 menu bar host) and Samsung Galaxy (Android Kotlin client) over local network (HTTP/1.1 and RFC 6455 WebSocket on port 8765) with fallback to offline BLE discovery and Wi-Fi Direct.

### High-Level Components
1. **macOS Host (`mac/`)**:
   - `GalaxyContinuityKit`: Core library containing networking (`ServerManager`), clipboard monitoring & injection (`ClipboardSyncService`), file transfer (`QuickDropService`), screen mirroring viewer window & input capture (`ScreenMirroringService`), Continuity Camera CMIO extension / virtual webcam feeder (`ContinuityCameraService`), notification display & quick-reply action handling (`NotificationService`), and Bonjour/BLE discovery (`DiscoveryService`).
   - `GalaxyContinuityApp`: Menu bar application UI (`StatusBarController`, `WebAssets.html` companion, settings, video viewer).
   - `GalaxyContinuityTests`: Automated unit & mock-socket integration test suite.
2. **Android Client (`android/`)**:
   - `ContinuityService`: Foreground service orchestrating WebSocket client, file transfers, and system events.
   - `ClipboardService`: Bidirectional text and image clipboard sync.
   - `QuickDropHandler`: Uploads files via `POST /api/upload` and downloads available files via `GET /api/download/:fileId`.
   - `ScreenMirroringService`: MediaProjection capture, video streaming, and AccessibilityService for remote touch/key injection.
   - `ContinuityCameraService`: Camera2 background video capture streaming frames to macOS.
   - `NotificationForwarderService`: NotificationListenerService forwarding notifications with reply actions and routing `notification_reply` back to apps.
   - `DiscoveryManager`: NSD (mDNS), BLE advertising/scanning, and Wi-Fi Direct P2P.
   - `app/src/test`: JVM unit test suite using MockWebServer and mock socket testing.
3. **Shared Protocol & Contracts (`shared/PROTOCOL.md`)**:
   - WebSocket JSON control messages (handshake, clipboard, file, screen, camera, notifications).
   - Binary frame streams for video and camera.
   - HTTP file transfer endpoints (`POST /api/upload`, `GET /api/download/:fileId`).

---

## Feature Inventory
Every feature from the user request and survey is assigned to a milestone below:

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | macOS Test Infrastructure | Refactor `mac/Package.swift` into library + test targets, enable `swift test` | M1 | Survey |
| 2 | Android Build & Test Infrastructure | Add Gradle wrapper files, signing configuration in `build.gradle.kts`, test setup | M1 | Survey |
| 3 | Shared Protocol Definitions | Codify complete protocol schemas & constants in `shared/PROTOCOL.md` | M1 | Survey |
| 4 | Plain Text Clipboard Sync | Bidirectional plain text clipboard transfer between macOS and Galaxy | M2 | Request R1 |
| 5 | Image Clipboard Sync | Bidirectional image payload transfer (`image/png`, TIFF, base64) with loop prevention | M2 | Request R1 |
| 6 | Quick Drop macOS -> Galaxy | File transfer initiated from macOS, downloaded on Galaxy | M2 | Request R1 |
| 7 | Quick Drop Galaxy -> macOS | File transfer initiated from Galaxy (`POST /api/upload`), saved on macOS | M2 | Request R1 |
| 8 | Screen Mirroring Stream | Stream Galaxy screen output to macOS viewer window | M3 | Request R1 |
| 9 | Remote Input Controls | Remote touch, mouse, and key input controls on macOS dispatched to Galaxy | M3 | Request R1 |
| 10 | Continuity Camera Stream | Stream Galaxy Camera2 feed to macOS host | M3 | Request R1 |
| 11 | Virtual Webcam Recognition | macOS recognizes phone camera stream as system webcam input | M3 | Request R1 |
| 12 | Notification Forwarding | Forward Galaxy notifications to macOS notifications center | M4 | Request R1 |
| 13 | Interactive Quick Reply | macOS notification inline reply routed back to Galaxy via `RemoteInput` | M4 | Request R1 |
| 14 | Bonjour / mDNS Discovery | Local network discovery over `_galaxycontinuity._tcp.` on port 8765 | M4 | Request R1 |
| 15 | BLE Peer Discovery | Offline peer advertising and discovery using CoreBluetooth and Android BLE | M4 | Request R1 |
| 16 | Wi-Fi Direct Discovery | Offline high-speed peer negotiation via Wi-Fi Direct P2P | M4 | Request R1 |
| 17 | Automated Protocol Tests | Automated socket/HTTP tests verifying port 8765 communication | E2E Track | Request R3 |
| 18 | Automated Unit/Integration Tests | macOS and Android test suites passing cleanly headless | E2E Track / M5 | Request R3 |
| 19 | Android Production APK Build | Compile production APK (`assembleRelease` / `assembleDebug`) | M5 | Request R2 |
| 20 | GitHub Release v1.0.0 | Create GitHub release `v1.0.0` with APK asset upload via `gh` CLI | M5 | Request R2 |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Architecture & Test Harness Enablement | `mac/Package.swift` target refactoring, Android Gradle wrapper & build configuration, shared protocol specification | none | DONE |
| M2 | Universal Clipboard & Quick Drop Parity | Bidirectional plain text + image clipboard sync, bidirectional Quick Drop file transfers | M1 | DONE |

| M3 | Screen Mirroring & Continuity Camera | Screen capture & remote input injection, Camera2 capture & macOS virtual camera ingestion | M1 | DONE |
| M4 | Notification Sync & Multi-Transport Discovery | Notification forwarding with interactive quick reply, mDNS + BLE + Wi-Fi Direct discovery | M1 | DONE |
| M5 | Final Verification & GitHub Release | 100% E2E test pass (Tiers 1-4), Tier 5 adversarial coverage hardening, APK build & GitHub release `v1.0.0` | M2, M3, M4, E2E Track | DONE |
| E2E | E2E Testing Track | Independent opaque-box test runner and test cases covering Tiers 1-4 | M1 | DONE |

---

## Interface Contracts

### macOS Host ↔ Galaxy Client (Port 8765)
- **Transport**: HTTP/1.1 and RFC 6455 WebSocket at `ws://<host>:8765/ws`.
- **Handshake Flow**:
  1. Client connects to `/ws` with HTTP Upgrade.
  2. Server responds with 101 Switching Protocols.
  3. Server sends `{"type": "handshake_ack", "device": "<macName>", "version": "1.0.0", "platform": "macOS"}`.
  4. Client sends `{"type": "handshake", "device": "<phoneModel>", "version": "1.0.0", "platform": "Android"}`.
- **Clipboard JSON**:
  - `{"type": "clipboard", "contentType": "text/plain"|"image/png", "payload": "<string|base64>", "hash": "<sha256>", "timestamp": 123456789}`
- **Quick Drop**:
  - Announce: `{"type": "file_available", "fileId": "<uuid>", "fileName": "<name>", "fileSize": <bytes>, "mimeType": "<mime>"}`
  - Download: `GET /api/download/:fileId`
  - Upload: `POST /api/upload` with header `X-Filename: <encodedName>`
- **Screen Mirroring**:
  - Start/Stop: `{"type": "screen_start", "fps": 30, "bitrate": 2000000}`, `{"type": "screen_stop"}`
  - Frame delivery: Binary frame packet `[0x01][4-byte len][payload]` or WebSocket binary frame.
  - Remote Input: `{"type": "input_event", "action": "down"|"up"|"move", "x": 0.5, "y": 0.5}`, `{"type": "input_key", "keyCode": 66}`
- **Continuity Camera**:
  - Start/Stop: `{"type": "camera_start", "lens": "back"|"front", "quality": "1080p"}`, `{"type": "camera_stop"}`
  - Stream delivery: Binary frame packet `[0x02][4-byte len][payload]` or MJPEG stream.
- **Notifications**:
  - Outbound: `{"type": "phone_notification", "id": "<id>", "app": "<appName>", "title": "<title>", "text": "<text>", "canReply": true, "timestamp": 123456789}`
  - Quick Reply: `{"type": "notification_reply", "id": "<id>", "replyText": "<text>"}`
- **Discovery**:
  - Bonjour/mDNS service type: `_galaxycontinuity._tcp.` on port 8765.
  - BLE Service UUID: `19B10000-E8F2-537E-4F6C-D104768A1214`.
  - Wi-Fi Direct P2P Group Owner IP: `192.168.49.1:8765`.

---

## Code Layout
- `mac/Package.swift`: Swift package defining `GalaxyContinuityKit` (library), `GalaxyContinuity` (executable), and `GalaxyContinuityTests` (test target).
- `mac/Sources/GalaxyContinuityKit/`: Core services and logic.
- `mac/Sources/GalaxyContinuity/`: Menu bar application UI and entry point.
- `mac/Tests/GalaxyContinuityTests/`: Unit and mock socket tests for macOS.
- `android/gradle/`: Gradle wrapper binaries and properties.
- `android/app/src/main/java/com/galaxycontinuity/app/`: Android source code.
  - `services/`: Foreground services (ContinuityService, ScreenMirroringService, CameraService, NotificationForwarderService, ClipboardService).
  - `network/`: WebSocketClient, FileTransferClient, DiscoveryManager (NSD, BLE, Wi-Fi Direct).
  - `ui/`: Compose activities and screens.
- `android/app/src/test/`: Android JVM unit tests.
- `shared/PROTOCOL.md`: Authoritative protocol specification.
- `tests/e2e/`: Opaque-box E2E test harness and test suites.
