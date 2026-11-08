# Project: Galaxy Continuity (1:1 Apple Continuity Replacement)

## Architecture
Galaxy Continuity provides seamless continuity between macOS (native Swift 6 menu bar host) and Samsung Galaxy (Android Kotlin client) over local network (HTTP/1.1 and RFC 6455 WebSocket on port 8765) with fallback to offline BLE discovery and Wi-Fi Direct, and direct USB loopback via ADB reverse port forwarding.

### High-Level Components
1. **macOS Host (`mac/`)**:
   - `GalaxyContinuityKit`: Core library containing networking (`ServerManager`), clipboard monitoring & injection (`ClipboardSyncService`), file transfer (`QuickDropService`), screen mirroring viewer window & input capture (`ScreenMirroringService`), Continuity Camera CMIO extension / virtual webcam feeder (`ContinuityCameraService`), notification display & quick-reply action handling (`NotificationService`), and Bonjour/BLE discovery (`DiscoveryService`).
   - `GalaxyContinuityApp`: Menu bar application UI (`StatusBarController`, `ScreenMirroringView` & `ScreenMirroringWindowController`, `WebAssets.html` companion, settings, video viewer).
   - `GalaxyContinuityTests`: Automated unit & mock-socket integration test suite.
2. **Android Client (`android/`)**:
   - `ContinuityService`: Foreground service orchestrating WebSocket client, file transfers, and system events with automatic reconnection loop.
   - `ClipboardService`: Bidirectional text and image clipboard sync.
   - `QuickDropHandler`: Uploads files via `POST /api/upload` and downloads available files via `GET /api/download/:fileId`.
   - `ScreenMirroringService`: MediaProjection capture, video streaming, and AccessibilityService for remote touch/key/scroll injection.
   - `ContinuityAccessibilityService`: AccessibilityService for remote touch, gestures, direct text injection (`ACTION_SET_TEXT`), editing keys (`DEL`, `ENTER`), and scroll swipes.
   - `ContinuityCameraService`: Camera2 background video capture streaming frames to macOS.
   - `NotificationForwarderService`: NotificationListenerService forwarding notifications with reply actions, caching content intents, and routing `notification_reply` and `notification_open`.
   - `DiscoveryManager`: NSD (mDNS), BLE advertising/scanning, and Wi-Fi Direct P2P.
   - `app/src/test`: JVM unit test suite using MockWebServer and mock socket testing.
3. **Shared Protocol & Contracts (`shared/PROTOCOL.md`)**:
   - WebSocket JSON control messages (handshake, clipboard, file, screen, camera, notifications, remote input, remote text, remote scroll).
   - Binary frame streams for video and camera.
   - HTTP file transfer endpoints (`POST /api/upload`, `GET /api/download/:fileId`).

---

## Feature Inventory
Every feature from previous runs and current user request is assigned to a milestone below:

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | macOS Test Infrastructure | Refactor `mac/Package.swift` into library + test targets, enable `swift test` | M1 | Done |
| 2 | Android Build & Test Infrastructure | Add Gradle wrapper files, signing configuration in `build.gradle.kts`, test setup | M1 | Done |
| 3 | Shared Protocol Definitions | Codify complete protocol schemas & constants in `shared/PROTOCOL.md` | M1 | Done |
| 4 | Plain Text Clipboard Sync | Bidirectional plain text clipboard transfer between macOS and Galaxy | M2 | Done |
| 5 | Image Clipboard Sync | Bidirectional image payload transfer (`image/png`, TIFF, base64) with loop prevention | M2 | Done |
| 6 | Quick Drop macOS -> Galaxy | File transfer initiated from macOS, downloaded on Galaxy | M2 | Done |
| 7 | Quick Drop Galaxy -> macOS | File transfer initiated from Galaxy (`POST /api/upload`), saved on macOS | M2 | Done |
| 8 | Screen Mirroring Stream | Stream Galaxy screen output to macOS viewer window | M3 | Done |
| 9 | Remote Input Controls | Remote touch, mouse, and key input controls on macOS dispatched to Galaxy | M3 | Done |
| 10 | Continuity Camera Stream | Stream Galaxy Camera2 feed to macOS host | M3 | Done |
| 11 | Virtual Webcam Recognition | macOS recognizes phone camera stream as system webcam input | M3 | Done |
| 12 | Notification Forwarding | Forward Galaxy notifications to macOS notifications center | M4 | Done |
| 13 | Interactive Quick Reply | macOS notification inline reply routed back to Galaxy via `RemoteInput` | M4 | Done |
| 14 | Bonjour / mDNS Discovery | Local network discovery over `_galaxycontinuity._tcp.` on port 8765 | M4 | Done |
| 15 | BLE Peer Discovery | Offline peer advertising and discovery using CoreBluetooth and Android BLE | M4 | Done |
| 16 | Wi-Fi Direct Discovery | Offline high-speed peer negotiation via Wi-Fi Direct P2P | M4 | Done |
| 17 | Automated Protocol Tests | Automated socket/HTTP tests verifying port 8765 communication | E2E Track | Done |
| 18 | Automated Unit/Integration Tests | macOS and Android test suites passing cleanly headless | E2E Track / M5 | Done |
| 19 | Android Production APK Build | Compile production APK (`assembleRelease` / `assembleDebug`) | M5 | Done |
| 20 | GitHub Release v1.0.0 | Create GitHub release `v1.0.0` with APK asset upload via `gh` CLI | M5 | Done |
| 21 | Mac Keyboard Direct Typing into Galaxy | Type on Mac keyboard directly into active input fields on phone | M-IT3-1 | Request R1 |
| 22 | Mac Trackpad Smooth Scrolling | Two-finger scroll gestures on Mac trackpad smoothly scroll phone feeds | M-IT3-1 | Request R1 |
| 23 | iPhone Mirroring Bezel Window Styling | Sleek smartphone rounded bezel design, floating minimal frame on macOS | M-IT3-1 | Request R2 |
| 24 | Notification Click Mirror Focus & Navigation | Clicking forwarded notification focuses mirror window and opens app on Galaxy | M-IT3-1 | Request R2 |
| 25 | Automatic Background Reconnection | Re-establish connection automatically over USB & Wi-Fi without manual IP entry | M-IT3-1 | Request R2 |
| 26 | Android APK Compilation & Galaxy A70 Deployment | Assemble debug APK and install directly to Galaxy A70 (`R58M5763N2Y`) via ADB | M-IT3-2 | Request R3 |
| 27 | Lean Real-Device Functional Verification | Focused functional validation on connected phone and Mac host | M-IT3-2 | Request R3 |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1-M5 | Foundational Continuity & Release | Base continuity system, initial E2E tests, v1.0.0 build | none | DONE |
| M-IT3-1 | iPhone Mirroring Parity & Presentation | Mac keyboard typing, trackpad scrolling, bezel styling, notification click, auto-reconnect | none | IN_PROGRESS |
| M-IT3-2 | Galaxy A70 Deployment & On-Device Validation | `./gradlew assembleDebug`, ADB install to `R58M5763N2Y`, `swift build`, on-device functional verification | M-IT3-1 | PLANNED |

---

## Interface Contracts

### macOS Host ↔ Galaxy Client (Port 8765)
- **Transport**: HTTP/1.1 and RFC 6455 WebSocket at `ws://<host>:8765/ws`. Also available over USB via `adb reverse tcp:8765 tcp:8765`.
- **Handshake Flow**:
  1. Client connects to `/ws` with HTTP Upgrade.
  2. Server responds with 101 Switching Protocols.
  3. Server sends `{"type": "handshake_ack", "device": "<macName>", "version": "1.0.0", "platform": "macOS"}`.
  4. Client sends `{"type": "handshake", "device": "<phoneModel>", "version": "1.0.0", "platform": "Android"}`.
- **Remote Text Input (`input_text`)**:
  - `{"type": "input_text", "text": "<string>"}`
  - Executed on Android via `AccessibilityNodeInfo.ACTION_SET_TEXT` on active input node, with fallback to clipboard paste or ADB `input text`.
- **Remote Scroll Input (`input_scroll`)**:
  - `{"type": "input_scroll", "x": <normalizedX>, "y": <normalizedY>, "dx": <deltaX>, "dy": <deltaY>}`
  - Dispatched via `ContinuityAccessibilityService.dispatchGesture` converting delta into scroll swipe.
- **Remote Key Event (`input_key`)**:
  - `{"type": "input_key", "key": "<keyName>", "keyCode": <int>}`
  - Handles editing keys: `DEL` (67), `ENTER` (66), `TAB` (61), `ESCAPE` (111), `SPACE` (62), `DPAD_*` (19-22).
- **Notification Open (`notification_open`)**:
  - `{"type": "notification_open", "id": "<notifId>", "packageName": "<packageName>"}`
  - Executed on Android by triggering cached `contentIntent` or launching `packageManager.getLaunchIntentForPackage`.
- **Automatic Reconnection**:
  - Android client probes `127.0.0.1:8765` (USB reverse), cached last-known Wi-Fi host IP, and mDNS discovery with exponential backoff (0ms, 1s, 2s, 4s, 10s max).

---

## Code Layout
- `mac/Package.swift`: Swift package defining `GalaxyContinuityKit` (library), `GalaxyContinuity` (executable), and `GalaxyContinuityTests` (test target).
- `mac/Sources/GalaxyContinuityKit/`: Core services and logic (`ScreenMirroringService.swift`, `NotificationService.swift`, `ServerManager.swift`, `ContinuityMessage.swift`).
- `mac/Sources/GalaxyContinuity/`: Menu bar application UI and entry point (`ScreenMirroringView.swift`, `ScreenMirroringWindowController`, `AppDelegate.swift`).
- `mac/Tests/GalaxyContinuityTests/`: Unit and mock socket tests for macOS.
- `android/gradle/`: Gradle wrapper binaries and properties.
- `android/app/src/main/java/com/galaxycontinuity/app/`: Android source code.
  - `service/`: Services (`ContinuityService`, `ScreenMirroringService`, `ContinuityAccessibilityService`, `NotificationForwarderService`, `ClipboardService`, `RemoteInputMapper`).
  - `network/`: `WebSocketClient`, `FileTransferClient`, `NsdDiscovery`.
  - `MainActivity.kt`: Compose UI and status display.
- `shared/PROTOCOL.md`: Authoritative protocol specification.
