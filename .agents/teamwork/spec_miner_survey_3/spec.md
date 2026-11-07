# Galaxy Continuity — Comprehensive Specification & Protocol Survey

## 1. Executive Summary & Authoritative Specification Hierarchy

This specification documents the authoritative protocols, schemas, discovery mechanisms, build/release pipeline, and mock test harnesses for **Galaxy Continuity** — an end-to-end 1:1 Apple Continuity replacement between macOS and Samsung Galaxy devices.

### Authoritative Specification Sources
1. **User Request & Requirements**: `.agents/teamwork/ORIGINAL_REQUEST.md` (R1 Continuity Feature Parity, R2 Android APK Build & GitHub Release, R3 Headless Verification).
2. **Repository Protocol Doc**: `shared/PROTOCOL.md`.
3. **macOS Reference Implementation**:
   - `mac/Sources/GalaxyContinuity/Services/ServerManager.swift` (BSD Socket HTTP/1.1 & RFC 6455 WebSocket Engine)
   - `mac/Sources/GalaxyContinuity/Services/BonjourService.swift` (Bonjour / mDNS Publisher)
   - `mac/Sources/GalaxyContinuity/Services/ClipboardSyncService.swift` (NSPasteboard Monitor & Injector)
   - `mac/Sources/GalaxyContinuity/Models/ContinuityMessage.swift` (Codable Protocol Schema)
   - `mac/Sources/GalaxyContinuity/WebCompanion/WebAssets.swift` (Browser Client Reference)
4. **Android Reference Implementation**:
   - `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` (OkHttp WebSocket Client)
   - `android/app/src/main/java/com/galaxycontinuity/app/network/NsdDiscovery.kt` (Android NSD / mDNS Client)
   - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` (Foreground Service)
   - `android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt` (Android ClipboardManager)
   - `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt` (Notification Listener)
5. **Release & CI Infrastructure**:
   - `.github/workflows/build-apk.yml` (GitHub Actions Android build & release workflow)
   - Target Git Remote: `git@github.com:savvakarayl-coder/galaxy-continuity.git`
   - Release Target: Tag `v1.0.0`

---

## 2. Network Transport & HTTP/WebSocket Protocol Specification

The primary communication channel between macOS and Galaxy operates over a single unified port: **default port `8765`** (TCP).

### 2.1 HTTP Endpoints

| Endpoint | Method | Content-Type | Purpose | Headers / Parameters | Behavior & Status Codes |
|---|---|---|---|---|---|
| `/` or `/companion` | `GET` | `text/html; charset=utf-8` | Serves the One UI Web Companion PWA | None | Returns 200 OK with full HTML5/CSS/JS client. Connection header: `close`. |
| `/api/upload` | `POST` | `application/octet-stream` (or multipart) | Quick Drop file upload to Mac | `Content-Length: <bytes>` (Required)<br>`X-Filename: <filename>` (Optional, percent-encoded supported) | Saves uploaded binary data to `~/Downloads/GalaxyContinuity/<filename>`. Resolves collisions by appending `(1)`, `(2)`, etc. Returns 200 OK `{"status":"ok"}`. |
| `/api/download/:fileId` | `GET` | `application/octet-stream` | File download from Mac to Galaxy | URL path parameter `:fileId` | If fileId registered in `sharedFiles`, returns 200 OK with `Content-Disposition: attachment; filename="<name>"` and file binary. If not found, returns 404 Not Found. |
| `/ws` (or any path with WS headers) | `GET` | N/A (Switching Protocols) | Bidirectional real-time event & control channel | `Upgrade: websocket`<br>`Connection: Upgrade`<br>`Sec-WebSocket-Key: <base64>`<br>`Sec-WebSocket-Version: 13` | Computes SHA-1 hash of `key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`, base64 encodes it, and returns `HTTP/1.1 101 Switching Protocols` with `Sec-WebSocket-Accept`. Upgrades connection to RFC 6455 WebSocket. |
| *Any other path* | Any | N/A | Fallback | Any | Returns `HTTP/1.1 404 Not Found`. |

### 2.2 WebSocket Framing Specification (RFC 6455)

The Mac server implementation (`ServerManager.swift`) contains a full low-level RFC 6455 frame parser:
- **Opcodes Supported**:
  - `0x1`: UTF-8 Text Frame (JSON serialized `ContinuityMessage`).
  - `0x2`: Binary Frame (H.264 video chunks, raw camera frames, binary buffers).
  - `0x8`: Connection Close.
  - `0x9`: Ping frame (Server responds with Pong `0xA` with identical payload).
  - `0xA`: Pong frame.
- **Payload Length Encoding**:
  - `0 - 125`: 7-bit standard length in byte 1.
  - `126`: 16-bit unsigned integer length in next 2 bytes (Big Endian).
  - `127`: 64-bit unsigned integer length in next 8 bytes (Big Endian).
- **Masking**:
  - Client-to-server frames are typically masked (`mask bit = 1`, 4-byte mask key XOR'd with payload). Server inspects `isMasked`: if masked, XOR unmasking is applied; if unmasked, payload is read directly without error.
  - Server-to-client frames are unmasked (`mask bit = 0`) per RFC 6455 specification.

---

## 3. Protocol Message Schemas (JSON over WebSocket)

### 3.1 Handshake & Status Negotiation

**From Galaxy to Mac (on connection open):**
```json
{
  "type": "handshake",
  "device": "Samsung Galaxy S24 Ultra",
  "platform": "android",
  "version": "1.0.0",
  "battery": {
    "level": 88,
    "isCharging": true
  }
}
```

**From Mac to Galaxy (acknowledgment):**
```json
{
  "type": "handshake_ack",
  "device": "MacBook Air — Савва",
  "platform": "macOS",
  "version": "1.0.0",
  "timestamp": 1794012054240.727
}
```

### 3.2 Universal Clipboard Specification

Supports bidirectional transfer for **plain text** and **image payloads**:

**Plain Text Payload:**
```json
{
  "type": "clipboard",
  "content": "https://example.com/article",
  "contentType": "text/plain",
  "timestamp": 1730940000000,
  "source": "mac"
}
```

**Image Payload (PNG / JPEG):**
```json
{
  "type": "clipboard",
  "content": "<base64_encoded_image_bytes>",
  "contentType": "image/png",
  "timestamp": 1730940000000,
  "source": "phone"
}
```
*Loop Prevention Rule*: Senders tag `source: "mac"` or `source: "phone"`. Receiving nodes compare incoming content with `lastSeenContent`; identical updates are suppressed to prevent infinite bounce-back loops.

### 3.3 Quick Drop File Transfer

**Mac-to-Phone File Advertisement:**
```json
{
  "type": "file_available",
  "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
  "filename": "presentation.pdf",
  "fileSize": 10485760,
  "mimeType": "application/pdf",
  "sender": "MacBook Pro"
}
```
*Retrieval*: Recipient performs HTTP `GET http://<mac-ip>:8765/api/download/c56a4180-2a8d-4f81-9bfa-89e4c69812df`.

**Phone-to-Mac File Transfer:**
Direct HTTP `POST http://<mac-ip>:8765/api/upload` with header `X-Filename: <URL-encoded filename>` and raw file stream in request body.

### 3.4 Screen Mirroring Specification

**Control Messages (WebSocket JSON):**
1. *Start Mirroring Session*:
   ```json
   {
     "type": "screen_start",
     "width": 1080,
     "height": 2400,
     "fps": 30,
     "bitrate": 4000000
   }
   ```
2. *Stop Mirroring Session*:
   ```json
   {
     "type": "screen_stop"
   }
   ```
3. *Remote Touch / Mouse Input (Mac -> Galaxy)*:
   ```json
   {
     "type": "input_event",
     "action": "down",
     "x": 0.523,
     "y": 0.741,
     "button": 0
   }
   ```
   - `action`: `"down"` | `"move"` | `"up"` | `"scroll"`
   - `x`, `y`: Normalized screen coordinates (float 0.0 to 1.0)
4. *Key / Navigation Control (Mac -> Galaxy)*:
   ```json
   {
     "type": "input_key",
     "key": "BACK"
   }
   ```
   - Supported keys: `"BACK"`, `"HOME"`, `"RECENTS"`, `"VOLUME_UP"`, `"VOLUME_DOWN"`, `"ENTER"`.

**Video Stream Transport:**
- Transported as WebSocket binary frames (`opcode 0x2`) or stream packet frames with a 4-byte header:
  - Byte 0: Stream Type (`0x01` = Screen Mirroring)
  - Byte 1: Frame Type (`0x01` = IDR Keyframe, `0x02` = Non-IDR P-Frame)
  - Bytes 2-3: Reserved / Sequence counter
  - Bytes 4+: H.264 NAL Units (Annex B format) or JPEG buffer.

### 3.5 Continuity Camera Specification

**Control Messages (WebSocket JSON):**
1. *Start Camera Stream*:
   ```json
   {
     "type": "camera_start",
     "facing": "back",
     "resolution": "1080p",
     "fps": 30
   }
   ```
2. *Stop Camera Stream*:
   ```json
   {
     "type": "camera_stop"
   }
   ```
3. *Switch Lens*:
   ```json
   {
     "type": "camera_switch_lens",
     "facing": "front"
   }
   ```

**Stream Transport & System Registration:**
- Video stream transported as WebSocket binary frames with Stream Type `0x02` (Camera) or MJPEG HTTP stream `GET /api/camera/stream`.
- On macOS: Video stream decoded and supplied to the Mac system preview or CoreMediaIO (CMIOExtension) DAL virtual webcam driver.

### 3.6 Phone Notification Synchronization with Quick Reply

**Forward Notification (Galaxy -> Mac):**
```json
{
  "type": "phone_notification",
  "id": "notif-uuid-10492",
  "packageName": "org.telegram.messenger",
  "app": "Telegram",
  "title": "Alex",
  "text": "Are you free for lunch?",
  "timestamp": 1730940050000,
  "canReply": true
}
```

**Quick Reply Action (Mac -> Galaxy):**
```json
{
  "type": "notification_reply",
  "id": "notif-uuid-10492",
  "packageName": "org.telegram.messenger",
  "replyText": "Yes, let's meet at 12:30!"
}
```
*On Android*: Handled by `NotificationForwarderService` using `RemoteInput.addResultsToIntent` and executing the notification's `PendingIntent`.

### 3.7 Remote Ping ("Find My Galaxy" / "Ping Mac")
```json
{
  "type": "ping_device",
  "source": "mac",
  "message": "Finding your Galaxy..."
}
```
*Behavior on Phone*: Vibrates haptic motor (`[300, 150, 300, 150, 400]ms`) and plays audible notification ringtone.
*Behavior on Mac*: Plays macOS `"Ping"` / `"Glass"` sound and presents user notification.

### 3.8 Battery State Updates
```json
{
  "type": "battery_update",
  "level": 92,
  "charging": true
}
```

---

## 4. Peer Discovery Specifications

### 4.1 Bonjour / mDNS (Local Network)
- **Service Type**: `_galaxycontinuity._tcp.`
- **Default Port**: `8765`
- **Domain**: `local.`
- **Service Name Format**: `Galaxy Continuity (<Device Name>)`
- **TXT Records**:
  - `name`: Human-readable device name (e.g. `MacBook Pro`)
  - `platform`: `macOS` / `android`
  - `version`: `1.0.0`
- **macOS Registration**: `NetService(domain: "local.", type: "_galaxycontinuity._tcp.", name: ..., port: 8765)` with `NetServiceDelegate`.
- **Android Discovery**: `android.net.nsd.NsdManager` with `discoverServices("_galaxycontinuity._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)`.

### 4.2 Bluetooth Low Energy (BLE - Offline Discovery)
- **Primary Service UUID**: `19B10000-E8F2-537E-4F6C-D104768A1214`
- **Characteristics**:
  - `DEVICE_INFO` (`19B10001-...`): Read — Device Name, Platform, Wi-Fi Direct MAC / IP.
  - `PAIRING_COMMAND` (`19B10002-...`): Write — Connection request, Wi-Fi credentials or session token.
  - `STATUS` (`19B10003-...`): Notify — Connection handshake status.
- **Advertising Payload**:
  - Service UUID: `19B10000-...`
  - Manufacturer Data / Service Data: 4-byte Short Device ID, 2-byte Port (`8765`), 1-byte Flags (`0x01` Ready, `0x02` Wi-Fi Direct Available).
- **Roles**:
  - Mac: `CBPeripheralManager` for background beacon advertising + `CBCentralManager` for peer scanning.
  - Android: `BluetoothLeAdvertiser` + `BluetoothLeScanner` with `ScanFilter`.

### 4.3 Wi-Fi Direct (P2P - High-Bandwidth Offline Link)
- **Protocol**: Wi-Fi P2P (`WifiP2pManager`)
- **Group Owner (GO)**: Galaxy phone or Mac establishes autonomous GO.
- **IP Assignment**: Standard Wi-Fi Direct GO assigns IP `192.168.49.1`.
- **Socket Target**: Client connects directly to `ws://192.168.49.1:8765/ws`.
- **Bandwidth**: Enables 40+ Mbps direct link for screen mirroring and large file transfers without any external Wi-Fi router.

---

## 5. GitHub Release Pipeline & CI Specifications

### 5.1 Repository & Remote Configuration
- **Target Git Remote**: `git@github.com:savvakarayl-coder/galaxy-continuity.git`
- **Default Branch**: `main`
- **Release Tag**: `v1.0.0`
- **Authentication**:
  - SSH key authentication to `git@github.com` is verified and functional for user `savvakarayl-coder`.
  - GitHub CLI (`gh`) tool version: `2.103.3` (installed on macOS).

### 5.2 CI Release Workflow (`.github/workflows/build-apk.yml`)
The repository contains a fully automated GitHub Actions workflow configured with:
- **Triggers**:
  - `push` on all branches (`**`)
  - `pull_request` on all branches (`**`)
  - `workflow_dispatch` (manual trigger)
- **Runner Environment**: `ubuntu-latest`
- **Toolchain**:
  - JDK: `17` (Eclipse Temurin distribution via `actions/setup-java@v4`)
  - Gradle: `8.5` (via `gradle/actions/setup-gradle@v3`)
  - Android SDK: Preinstalled runner SDK with automatic license acceptance:
    `yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses || true`
- **Build Step**:
  - Working directory: `android`
  - Command: `gradle assembleDebug --stacktrace --no-daemon`
- **Artifact Generation**:
  - Artifact Name: `GalaxyContinuity-debug.apk`
  - File Path: `android/app/build/outputs/apk/debug/app-debug.apk`
- **Release Step (`softprops/action-gh-release@v2`)**:
  - Condition: `if: github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'`
  - Release Title: `"Galaxy Continuity v1.0.0"`
  - Tag Name: `"v1.0.0"`
  - Attached Assets: `android/app/build/outputs/apk/debug/app-debug.apk`
  - Credentials: `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`

### 5.3 Local & CLI Release Instructions
1. **Using GitHub CLI directly**:
   ```bash
   export GH_TOKEN="<personal-access-token>"
   gh release create v1.0.0 android/app/build/outputs/apk/debug/app-debug.apk \
     --title "Galaxy Continuity v1.0.0" \
     --notes "Initial production release of Galaxy Continuity (macOS + Samsung Galaxy)."
   ```
2. **Via Git Tag & Push**:
   ```bash
   git tag v1.0.0
   git push origin main
   git push origin v1.0.0
   ```
   Pushes trigger the GitHub Actions workflow, building the APK in an environment with complete Android SDK tooling and publishing the release automatically.

---

## 6. Test Harness & Protocol Simulation Capabilities (Headless)

Because development and CI may execute on machines without physical Android devices or without full Android SDKs:
1. **Mock WebSocket / Socket Client**:
   A pure Python standard-library harness (`socket`, `hashlib`, `urllib`, `json`) connects to `127.0.0.1:8765`, performs RFC 6455 handshakes, encodes/decodes frames across 7-bit, 16-bit, and 64-bit payload lengths, and validates message schemas.
2. **Swift Package Tests**:
   Adding a test target in `mac/Package.swift` (`mac/Tests/GalaxyContinuityTests`) enables native compilation and unit testing via `swift test` for:
   - JSON encoding / decoding of all `ContinuityMessage` schemas
   - `DeviceState` state mutations
   - Pasteboard image and text conversion
3. **Automated Verification Matrix**:
   - `test_http_companion`: Verifies GET `/` and GET `/companion` returns 200 with HTML assets.
   - `test_ws_handshake`: Verifies 101 Switching Protocols and `handshake_ack`.
   - `test_clipboard_bidirectional`: Verifies plain text and image base64 sync.
   - `test_file_upload_download`: Verifies POST `/api/upload` and GET `/api/download/:fileId`.
   - `test_notification_forward_and_reply`: Verifies incoming notification and reverse reply routing.
   - `test_ping_pong`: Verifies RFC 6455 opcode `0x9` -> `0xA` pong.

---

## 7. Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|---|---|---|---|---|---|---|
| 1 | Handshake | WebSocket Handshake | RFC 6455 upgrade on port 8765 | HTTP GET `/ws` with `Upgrade: websocket`, `Sec-WebSocket-Key` | HTTP 101 Switching Protocols with `Sec-WebSocket-Accept` | Non-WS requests get 404 or file handling | `ServerManager.swift:243` |
| 2 | Handshake | Handshake Greeting Ack | Immediate server identification upon WS open | Incoming WS connection | JSON `handshake_ack` with Mac name, platform, version | Closed connection drops client | `ServerManager.swift:360` |
| 3 | Handshake | Client Device Registration | Registers client name, platform, battery | JSON `{type: "handshake", device, platform, version, battery}` | DeviceState updated, macOS notification shown | Nil values default gracefully | `ServerManager.swift:447` |
| 4 | Universal Clipboard | Plain Text Sync (Galaxy -> Mac) | Syncs clipboard text to macOS pasteboard | JSON `{type: "clipboard", content, contentType: "text/plain", source: "phone"}` | Injected into NSPasteboard (.string), banner notification | Duplicate/empty content ignored (loop prevention) | `ServerManager.swift:461`, `ClipboardSyncService.swift:62` |
| 5 | Universal Clipboard | Plain Text Sync (Mac -> Galaxy) | Monitors NSPasteboard and broadcasts copy | Local copy event on macOS | JSON `{type: "clipboard", content, contentType: "text/plain", source: "mac"}` | Ignored if internal update flag active | `ClipboardSyncService.swift:33` |
| 6 | Universal Clipboard | Image Clipboard Transfer | Syncs image payload between devices | JSON `{type: "clipboard", content: "<base64>", contentType: "image/png"}` | Decoded and written to NSPasteboard (.png/.tiff) or phone clipboard | Invalid base64 logged, dropped without crash | `ORIGINAL_REQUEST.md:14`, `ContinuityMessage.swift:18` |
| 7 | Quick Drop | Phone -> Mac File Upload | HTTP upload saving to `~/Downloads/GalaxyContinuity` | HTTP POST `/api/upload`, Header `X-Filename`, binary body | HTTP 200 `{"status":"ok"}`, file written to disk | Duplicate filename auto-renamed `(1)`, `(2)` | `ServerManager.swift:248` |
| 8 | Quick Drop | Unicode Filename Upload | Percent-decoded filename support | `X-Filename: %D1%82%D0%B5%D1%81%D1%82.txt` | Decodes to native UTF-8 string on disk | Falls back to raw string if decoding fails | `ServerManager.swift:258` |
| 9 | Quick Drop | Missing Filename Fallback | Fallback filename when header omitted | HTTP POST `/api/upload` without `X-Filename` | Saves as `Received_File_<timestamp>.bin` | None, always succeeds | `ServerManager.swift:257` |
| 10 | Quick Drop | Mac -> Phone File Broadcast | Broadcasts file availability to phone | Mac user drags file to QuickDropView | JSON `{type: "file_available", fileId, filename, fileSize, mimeType}` | Nil file URL drops operation | `ServerManager.swift:544` |
| 11 | Quick Drop | Mac -> Phone File Download | Phone downloads file shared by Mac | HTTP GET `/api/download/:fileId` | HTTP 200 with `Content-Disposition` and file bytes | Returns 404 Not Found if fileId missing/expired | `ServerManager.swift:280` |
| 12 | Screen Mirroring | Mirroring Session Control | Starts and stops screen mirroring | JSON `{type: "screen_start", width, height, fps}` / `{type: "screen_stop"}` | Galaxy initiates MediaProjection / screen capture | Permission denial stops session | `ORIGINAL_REQUEST.md:16`, `DISPATCH.md:12` |
| 13 | Screen Mirroring | Video Stream Framing | Low-latency screen video streaming | WebSocket binary frames (`opcode 0x2`) carrying H.264/JPEG | macOS window renders live phone display | Packet loss handled via next IDR frame | `ORIGINAL_REQUEST.md:16`, `ServerManager.swift:425` |
| 14 | Screen Mirroring | Remote Touch Input Control | Transmits clicks/taps to Galaxy screen | JSON `{type: "input_event", action: "down"|"move"|"up", x, y}` | Galaxy injects touch event via Accessibility / Input API | Invalid coordinate clamped to [0.0, 1.0] | `ORIGINAL_REQUEST.md:16` |
| 15 | Screen Mirroring | Remote Key Navigation | Transmits hardware keys (Back, Home, Recents) | JSON `{type: "input_key", key: "BACK"|"HOME"|"RECENTS"}` | Phone performs navigation action | Unknown key code ignored | `ORIGINAL_REQUEST.md:16` |
| 16 | Continuity Camera | Camera Stream Control | Starts/stops phone camera feed | JSON `{type: "camera_start", facing: "back"|"front", resolution, fps}` | Galaxy initiates Camera2 / CameraX stream | Camera in use returns error | `ORIGINAL_REQUEST.md:17` |
| 17 | Continuity Camera | Video Feed to macOS Webcam | Streams camera feed recognized as system webcam | Binary frames over WebSocket / MJPEG | macOS preview / CoreMediaIO DAL virtual camera | Dropped connection closes camera | `ORIGINAL_REQUEST.md:17` |
| 18 | Notifications | Forwarding Android Notifications | Forwards phone notifications to Mac | JSON `{type: "phone_notification", id, app, title, text, timestamp, canReply}` | Delivered via UNUserNotificationCenter on Mac | Ongoing/self notifications filtered | `NotificationForwarderService.kt:12`, `ServerManager.swift:484` |
| 19 | Notifications | Interactive Quick Reply | Routes quick reply action back to Android | JSON `{type: "notification_reply", id, packageName, replyText}` | Galaxy executes NotificationCompat direct reply PendingIntent | Expired notification key logged | `ORIGINAL_REQUEST.md:18` |
| 20 | Device State | Battery Status Updates | Reports real-time battery level & charge state | JSON `{type: "battery_update", level, isCharging}` | DeviceState updated, badge reflected in Mac menu bar | Clamped 0-100% | `ServerManager.swift:468` |
| 21 | Remote Ping | Find My Phone | Vibrates and sounds Galaxy from Mac | JSON `{type: "ping_device", source: "mac", message}` | Phone plays chime and vibrates | Silent mode override / audio failure caught | `ServerManager.swift:475`, `MainActivity.kt:251` |
| 22 | Remote Ping | Ping Mac | Chimes Mac from Galaxy | JSON `{type: "ping_device", source: "phone", message}` | Mac plays "Ping" sound and shows banner | Muted sound plays visual banner | `ServerManager.swift:475` |
| 23 | Web Companion | Zero-Install PWA Client | Embedded One UI browser client | HTTP GET `/` or `/companion` | Full HTML5/JS/CSS companion app | Offline retry every 2s | `WebAssets.swift:4` |
| 24 | Web Companion | QR Code Pairing | Generates QR code containing local Mac URL | Mac user clicks "Pair Phone" | CIFilter `CIQRCodeGenerator` image rendering URL | Bad IP falls back to 127.0.0.1 | `DevicePairingView.swift:76` |
| 25 | Discovery | Bonjour / mDNS Advertising | Advertises Mac service on local network | Port `8765`, TXT records (name, platform, version) | `_galaxycontinuity._tcp.` broadcast on `local.` | Port conflict logged | `BonjourService.swift:12` |
| 26 | Discovery | Android NSD Discovery | Discovers Mac Bonjour service on Android | `NsdManager.discoverServices` | Resolves host IP, port, and connects WS | Resolve failure triggers retry | `NsdDiscovery.kt:17` |
| 27 | Discovery | Bluetooth Low Energy (BLE) | Out-of-band peer advertising & discovery | BLE Service `19B10000-...`, manufacturer data | Mac/Galaxy detects peer offline | BLE disabled shows warning | `ORIGINAL_REQUEST.md:19` |
| 28 | Discovery | Wi-Fi Direct (P2P) | Direct peer Wi-Fi link without router | `WifiP2pManager` negotiation | Direct link on `192.168.49.1:8765` | Group formation failure falls back to BLE/mDNS | `ORIGINAL_REQUEST.md:19` |
| 29 | Release Pipeline | Gradle APK Compilation | Builds debug/release Android APK | `./gradlew assembleDebug` / `assembleRelease` | `app-debug.apk` in build outputs directory | Missing Java/SDK exits non-zero | `.github/workflows/build-apk.yml:37` |
| 30 | Release Pipeline | GitHub Actions Release Creation | Automates v1.0.0 release creation & APK upload | Git push to `refs/heads/main` or tag `v1.0.0` | GitHub Release `v1.0.0` created with attached APK | Runner error logged in Actions console | `.github/workflows/build-apk.yml:50` |
| 31 | Release Pipeline | GitHub CLI (`gh`) Release | Publishes release from terminal | `gh release create v1.0.0 <apk> --title "..."` | GitHub Release created on `savvakarayl-coder/galaxy-continuity` | Unauthenticated prompts for `gh auth login` / `GH_TOKEN` | `DISPATCH.md:18` |
| 32 | Test Simulation | Automated Headless Protocol Tests | Executes full socket & HTTP suite without device | Python test harness or Swift XCTest | Test report verifying all endpoints & frames | Assertion failure exits non-zero | `test_server.py:1`, `ORIGINAL_REQUEST.md:25` |

---

## 8. Edge Cases

| # | Feature | Input | Observed Behavior |
|---|---|---|---|
| 1 | HTTP Server | `GET /nonexistent` | Returns `HTTP/1.1 404 Not Found` with `Content-Length: 0`. Client connection closed cleanly. |
| 2 | HTTP Upload | `PUT /api/upload` (unsupported HTTP method) | Falls through method check and returns `HTTP/1.1 404 Not Found`. Client removed cleanly. |
| 3 | HTTP Upload | `POST /api/upload` with missing `X-Filename` header | Succeeds with 200 OK; saves file under default pattern `Received_File_<timestamp>.bin` in `~/Downloads/GalaxyContinuity/`. |
| 4 | HTTP Upload | `POST /api/upload` with percent-encoded Unicode filename (`%D1%82%D0%B5%D1%81%D1%82_%D1%84%D0%B0%D0%B9%D0%BB.txt`) | Decodes URL encoding and successfully writes UTF-8 filename `тест_файл.txt` to disk. |
| 5 | HTTP Upload | `POST /api/upload` with duplicate filename | Detects existing file on disk and appends incremental counter `filename (1).ext`, `filename (2).ext` without overwriting. |
| 6 | HTTP Upload | Large file upload (5 MB binary payload) | Streams full 5,242,880 bytes to disk; triggers `NotificationService` and updates `DeviceState.transferredFiles`. |
| 7 | HTTP Download | `GET /api/download/nonexistent-uuid` | Shared file lookup returns nil; responds with `HTTP/1.1 404 Not Found` with `Content-Length: 0`. |
| 8 | WebSocket Framing | Frame payload size 126 to 65,535 bytes (16-bit extended length) | Server correctly parses 2-byte big-endian length (e.g. 130-byte handshake_ack, 500-byte clipboard message). |
| 9 | WebSocket Framing | Frame payload size > 65,535 bytes (64-bit extended length) | Server correctly parses 8-byte big-endian length (verified with 70,000-byte base64 image frame). |
| 10 | WebSocket Framing | Unmasked client frame (`mask bit = 0`) | Server checks `isMasked`; does not apply XOR unmasking if mask bit is false, successfully decoding the frame. |
| 11 | WebSocket Protocol | Ping frame (`opcode 0x9`) with payload `"heartbeat"` | Server immediately returns Pong frame (`opcode 0xA`) carrying identical `"heartbeat"` payload. |
| 12 | WebSocket Message | Malformed non-JSON payload (`"THIS IS NOT JSON {{{[[["`) | Server catches `JSONDecoder` error with `try?`, ignores invalid message, does not crash, and connection remains active. |
| 13 | WebSocket Buffer | Buffer accumulation with fragmented frames | Server keeps unconsumed bytes in `client.readBuffer` until full header/frame length arrives. |
| 14 | Notification Service | Notifications sent when macOS app unnotified/unauthorized | Mac prints `[NotificationService] Authorization error: UNErrorDomain Code=1`; app continues operating normally without crash. |
| 15 | Clipboard Sync | Repeated identical clipboard updates (Echo prevention) | Compares incoming text against `lastSeenContent`; identical updates are dropped immediately to prevent infinite echo loops. |
