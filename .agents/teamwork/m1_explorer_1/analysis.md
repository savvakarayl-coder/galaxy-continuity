# macOS Package & Layout Refactoring Analysis

**Author**: M1 Explorer 1 (`teamwork_explorer`)  
**Target Milestone**: Milestone 1 (Architecture & Test Harness Enablement)  
**Date**: 2026-11-07  
**Scope**: `mac/` directory architecture, `Package.swift`, library/executable/test target separation, headless test harness.

---

## 1. Executive Summary

The current macOS host application (`mac/`) is structured as a monolithic SPM executable target (`GalaxyContinuity`) containing models, services, networking, and UI in a single directory (`mac/Sources/GalaxyContinuity/`). While `swift build` completes successfully, `swift test` immediately fails with `error: no tests found; create a target in the 'Tests' directory`. Furthermore, because core socket and protocol logic is embedded in an executable target with `private` methods, unit tests and mock socket tests cannot directly import or test protocol compliance.

To achieve clean architecture, headless testability, and 1:1 Apple Continuity protocol compliance, `mac/` must be refactored into:
1. **`GalaxyContinuityKit`** (Library Target): Encapsulating models (`ContinuityMessage`, `DeviceState`), networking and protocol handling (`ServerManager`, `WebSocketFramer`), system services (`ClipboardSyncService`, `BonjourService`, `NotificationService`), and web assets (`WebAssets`).
2. **`GalaxyContinuity`** (Executable Target): Retaining menu bar application lifecycle (`App.swift`, `AppDelegate.swift`) and SwiftUI views (`MenuBarView`, `DevicePairingView`, `QuickDropView`), statically linking `GalaxyContinuityKit`.
3. **`GalaxyContinuityTests`** (Test Target): Independent XCTest suite verifying RFC 6455 framing (7-bit, 16-bit, 64-bit), WebSocket handshakes, HTTP endpoints, JSON serialization, and localhost socket integration.

---

## 2. Directory Layout & Source Decomposition

### 2.1 Proposed Directory Tree

```
mac/
├── Package.swift
├── Info.plist
├── Resources/
│   └── AppIcon.icns
├── Sources/
│   ├── GalaxyContinuityKit/
│   │   ├── Models/
│   │   │   ├── ContinuityMessage.swift
│   │   │   └── DeviceState.swift
│   │   ├── Network/
│   │   │   └── WebSocketFramer.swift       # RFC 6455 framing, masking, & handshake calculation
│   │   ├── Services/
│   │   │   ├── BonjourService.swift
│   │   │   ├── ClipboardSyncService.swift
│   │   │   ├── NotificationService.swift
│   │   │   └── ServerManager.swift
│   │   └── WebCompanion/
│   │       └── WebAssets.swift
│   └── GalaxyContinuity/
│       ├── App.swift                       # @main entry point, activation policy config
│       ├── AppDelegate.swift               # NSStatusItem, NSPopover, service bootstrap
│       └── UI/
│           ├── DevicePairingView.swift     # QR code pairing sheet
│           ├── MenuBarView.swift           # Menu bar popover UI
│           └── QuickDropView.swift         # Drag-and-drop file transfer card
├── Tests/
│   └── GalaxyContinuityTests/
│       ├── HandshakeTests.swift            # RFC 6455 Sec-WebSocket-Key / Accept hash tests
│       ├── WebSocketFramingTests.swift     # 7-bit, 16-bit, 64-bit framing & masking tests
│       ├── HttpEndpointTests.swift         # Upload, download, companion, and 404 tests
│       ├── MessageSerializationTests.swift # JSON encode/decode tests for all protocol types
│       └── SocketIntegrationTests.swift    # Live loopback socket integration tests
└── scripts/
    ├── build_app.sh                        # Release bundling & ad-hoc codesigning script
    ├── generate_icon.swift
    └── test_server.py
```

### 2.2 File Allocation Matrix

| File | Current Location | New Location | Target | Rationale |
|---|---|---|---|---|
| `ContinuityMessage.swift` | `Sources/GalaxyContinuity/Models/` | `Sources/GalaxyContinuityKit/Models/` | `GalaxyContinuityKit` | Core protocol model, needed by services, UI, and tests |
| `DeviceState.swift` | `Sources/GalaxyContinuity/Models/` | `Sources/GalaxyContinuityKit/Models/` | `GalaxyContinuityKit` | Observable state model shared between services and UI |
| `BonjourService.swift` | `Sources/GalaxyContinuity/Services/` | `Sources/GalaxyContinuityKit/Services/` | `GalaxyContinuityKit` | Local network mDNS service advertisement |
| `ClipboardSyncService.swift` | `Sources/GalaxyContinuity/Services/` | `Sources/GalaxyContinuityKit/Services/` | `GalaxyContinuityKit` | Pasteboard monitoring and synchronization |
| `NotificationService.swift` | `Sources/GalaxyContinuity/Services/` | `Sources/GalaxyContinuityKit/Services/` | `GalaxyContinuityKit` | UNUserNotificationCenter continuity notifications |
| `ServerManager.swift` | `Sources/GalaxyContinuity/Services/` | `Sources/GalaxyContinuityKit/Services/` | `GalaxyContinuityKit` | Core BSD socket server, HTTP handling, WebSocket dispatcher |
| `WebSocketFramer.swift` | *New* | `Sources/GalaxyContinuityKit/Network/` | `GalaxyContinuityKit` | RFC 6455 7/16/64-bit frame codec & handshake calculator |
| `WebAssets.swift` | `Sources/GalaxyContinuity/WebCompanion/` | `Sources/GalaxyContinuityKit/WebCompanion/` | `GalaxyContinuityKit` | Embedded web companion client assets served by ServerManager |
| `App.swift` | `Sources/GalaxyContinuity/` | `Sources/GalaxyContinuity/` | `GalaxyContinuity` | Executable `@main` entry point |
| `AppDelegate.swift` | `Sources/GalaxyContinuity/` | `Sources/GalaxyContinuity/` | `GalaxyContinuity` | AppKit NSApplicationDelegate, status item, popover |
| `DevicePairingView.swift` | `Sources/GalaxyContinuity/UI/` | `Sources/GalaxyContinuity/UI/` | `GalaxyContinuity` | Presentation UI for pairing |
| `MenuBarView.swift` | `Sources/GalaxyContinuity/UI/` | `Sources/GalaxyContinuity/UI/` | `GalaxyContinuity` | Presentation UI for popover |
| `QuickDropView.swift` | `Sources/GalaxyContinuity/UI/` | `Sources/GalaxyContinuity/UI/` | `GalaxyContinuity` | Presentation UI for file drop |

### 2.3 Access Control & Visibility Adjustments

1. **`GalaxyContinuityKit` Types**:
   - `ContinuityMessage`, `BatteryInfo`: already declared `public`.
   - `DeviceState`, `FileTransferItem`: already declared `public`.
   - `BonjourService`, `ClipboardSyncService`, `NotificationService`: already declared `public`.
   - `ServerManager`: already declared `public`.
   - `WebSocketFramer`, `WebSocketFrame`: must be declared `public` for test target visibility.
   - `WebAssets`: already declared `public`.

2. **`GalaxyContinuity` Executable**:
   - Add `import GalaxyContinuityKit` to:
     - `AppDelegate.swift`
     - `MenuBarView.swift`
     - `DevicePairingView.swift`
     - `QuickDropView.swift`

---

## 3. `Package.swift` Refactoring

The refactored `mac/Package.swift` defines both the library and executable products, and adds the test target:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyContinuity",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GalaxyContinuityKit",
            targets: ["GalaxyContinuityKit"]
        ),
        .executable(
            name: "GalaxyContinuity",
            targets: ["GalaxyContinuity"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GalaxyContinuityKit",
            dependencies: [],
            path: "Sources/GalaxyContinuityKit"
        ),
        .executableTarget(
            name: "GalaxyContinuity",
            dependencies: [
                "GalaxyContinuityKit"
            ],
            path: "Sources/GalaxyContinuity"
        ),
        .testTarget(
            name: "GalaxyContinuityTests",
            dependencies: [
                "GalaxyContinuityKit"
            ],
            path: "Tests/GalaxyContinuityTests"
        )
    ]
)
```

### Build & Link Characteristics:
- SPM builds `GalaxyContinuityKit` as a static library by default.
- The `GalaxyContinuity` executable target statically links `GalaxyContinuityKit`.
- The final Mach-O executable produced at `.build/release/GalaxyContinuity` is completely self-contained with no external `.dylib` dependencies.
- `scripts/build_app.sh` requires **no changes** because the binary name `.build/release/GalaxyContinuity` and output path are identical.

---

## 4. Preservation of `LSUIElement: true` and Menu Bar Functionality

### 4.1 Production Bundle (`Galaxy Continuity.app`)
In `mac/Info.plist`:
```xml
<key>CFBundleExecutable</key>
<string>Galaxy Continuity</string>
<key>LSUIElement</key>
<true/>
```
When packaged via `scripts/build_app.sh`, macOS LaunchServices reads `LSUIElement: true`:
- The app operates as an agent process (`NSApplicationActivationPolicyAccessory`).
- No Dock icon appears.
- No standard application menu bar appears at the top of the display.
- The app resides strictly in `NSStatusBar.system.statusItem(withLength:)`.

### 4.2 Development & Direct Binary Execution (`swift run`)
When running `swift run GalaxyContinuity` directly in development without an `.app` wrapper, LaunchServices does not parse `Info.plist`. To guarantee identical behavior across all execution contexts, `AppDelegate.swift` or `App.swift` should programmatically set the activation policy:

```swift
// In AppDelegate.swift:
public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    setupMenuBar()
    setupPopover()
    startServices()
}
```
This guarantees that even in headless or direct terminal execution, the app never creates a Dock icon.

---

## 5. RFC 6455 WebSocket Framing & Codec Design

Currently, WebSocket framing logic in `ServerManager.swift` is private and tightly coupled to Darwin socket file descriptors (`Darwin.write`). To enable comprehensive unit testing of RFC 6455 without opening network sockets, framing logic should be extracted into a dedicated `WebSocketFramer`:

### 5.1 `WebSocketFramer` Specification (`mac/Sources/GalaxyContinuityKit/Network/WebSocketFramer.swift`)

```swift
import Foundation
import CryptoKit

public struct WebSocketFrame: Equatable {
    public let fin: Bool
    public let opcode: UInt8
    public let payload: Data

    public init(fin: Bool = true, opcode: UInt8, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketFramer {
    public static let websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Computes the RFC 6455 Sec-WebSocket-Accept header value from a client key
    public static func computeAcceptKey(for clientKey: String) -> String {
        let fullKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines) + websocketGuid
        let hash = Insecure.SHA1.hash(data: Data(fullKey.utf8))
        return Data(hash).base64EncodedString()
    }

    /// Encodes a WebSocket frame supporting 7-bit, 16-bit, and 64-bit payload lengths
    public static func encodeFrame(
        opcode: UInt8,
        payload: Data,
        fin: Bool = true,
        isMasked: Bool = false,
        maskKey: [UInt8]? = nil
    ) -> Data {
        var frame = Data()
        var b0: UInt8 = opcode & 0x0F
        if fin { b0 |= 0x80 }
        frame.append(b0)

        let len = payload.count
        let maskBit: UInt8 = isMasked ? 0x80 : 0x00

        if len <= 125 {
            frame.append(maskBit | UInt8(len))
        } else if len <= 65535 {
            frame.append(maskBit | 126)
            var beLen = UInt16(len).bigEndian
            frame.append(Data(bytes: &beLen, count: 2))
        } else {
            frame.append(maskBit | 127)
            var beLen = UInt64(len).bigEndian
            frame.append(Data(bytes: &beLen, count: 8))
        }

        if isMasked {
            let mask = maskKey ?? [UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255)]
            frame.append(contentsOf: mask)
            var masked = [UInt8](payload)
            for i in 0..<masked.count {
                masked[i] ^= mask[i % 4]
            }
            frame.append(contentsOf: masked)
        } else {
            frame.append(payload)
        }

        return frame
    }

    /// Decodes a WebSocket frame from an accumulated buffer.
    /// Returns nil if more data is required to complete the frame.
    public static func decodeFrame(from buffer: inout Data) -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let b0 = buffer[0]
        let b1 = buffer[1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let isMasked = (b1 & 0x80) != 0
        var payloadLen = Int(b1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            let high = Int(buffer[offset])
            let low = Int(buffer[offset + 1])
            payloadLen = (high << 8) | low
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 {
                len = (len << 8) | UInt64(buffer[offset + i])
            }
            payloadLen = Int(len)
            offset += 8
        }

        var mask = [UInt8]()
        if isMasked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }

        var payload = Array(buffer[offset..<(offset + payloadLen)])
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }

        buffer.removeSubrange(0..<(offset + payloadLen))
        return WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload))
    }
}
```

---

## 6. Test Target Design (`mac/Tests/GalaxyContinuityTests/`)

### 6.1 `HandshakeTests.swift`
Verifies RFC 6455 handshake key calculation against the official standard test vector:
- **Test Vector**: RFC 6455 Section 1.3
  - Client Nonce: `dGhlIHNhbXBsZSBub25jZQ==`
  - Expected `Sec-WebSocket-Accept`: `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`
- **Test Vector 2**: Additional randomly generated 16-byte base64 keys verifying SHA-1 digest + base64 formatting.
- Verifies HTTP 101 response construction (`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ...\r\n\r\n`).

### 6.2 `WebSocketFramingTests.swift`
Directly verifies RFC 6455 framing across all length tiers:
1. **7-bit Small Payloads (len <= 125)**:
   - Payloads of sizes 0, 1, 10, 125 bytes.
   - Assert Byte 1 has length directly encoded (`b1 & 0x7F == len`).
   - Roundtrip encode -> decode preserves exact payload.
2. **16-bit Extended Payloads (126 <= len <= 65535)**:
   - Payloads of sizes 126, 1024, 65535 bytes.
   - Assert Byte 1 == 126.
   - Assert Bytes 2..3 contain the big-endian `UInt16` length.
   - Roundtrip encode -> decode preserves all bytes.
3. **64-bit Extended Payloads (len > 65535)**:
   - Payloads of sizes 65536 bytes (64 KB) and 131072 bytes (128 KB).
   - Assert Byte 1 == 127.
   - Assert Bytes 2..9 contain the big-endian `UInt64` length.
   - Roundtrip encode -> decode processes the large payload without truncation or memory corruption.
4. **Client-to-Server Masking & XOR Unmasking**:
   - Encodes frame with `isMasked: true` and known mask key `[0x11, 0x22, 0x33, 0x44]`.
   - Verifies raw bytes in the frame are masked.
   - Verifies `decodeFrame` unmasks and matches the original cleartext.
5. **Buffer Segmentation / Chunk Streaming**:
   - Buffer split across multiple segments (header in segment 1, length in segment 2, partial payload in segment 3).
   - Verifies `decodeFrame` returns `nil` until all bytes are present.

### 6.3 `MessageSerializationTests.swift`
Verifies JSON encoding and decoding of all messages defined in `shared/PROTOCOL.md`:
- `handshake`: verifies Android client attributes, battery level, charging status.
- `handshake_ack`: verifies macOS host attributes, version string.
- `clipboard`: verifies plain text and image payloads, base64 data, timestamps, source routing ("mac" vs "phone").
- `file_available`: verifies fileId, filename, fileSize, mimeType.
- `ping_device`: verifies source and custom message strings.
- `phone_notification`: verifies notification forwarding fields (id, app, title, text, timestamp).
- `battery_update`: verifies battery percentage and charging state updates.

### 6.4 `HttpEndpointTests.swift`
Verifies HTTP request parsing and response handling:
- `GET /` and `GET /companion`: returns HTTP 200, Content-Type `text/html; charset=utf-8`, and contains the Web Companion markup.
- `POST /api/upload`: handles `X-Filename` header (including percent-encoded UTF-8 characters), writes uploaded data to disk, and returns HTTP 200 `{"status":"ok"}`.
- `GET /api/download/:fileId`: returns HTTP 200 with binary payload and attachment header when fileId is registered; returns HTTP 404 when fileId does not exist.
- Invalid routes: returns HTTP 404 Not Found.

### 6.5 `SocketIntegrationTests.swift`
Executes an end-to-end integration test over loopback (`127.0.0.1`):
1. Starts `ServerManager.shared.start(port: 18765)` (using port 18765 to guarantee no conflict with default port 8765).
2. Connects a client socket, sends HTTP GET `/companion`, validates 200 OK.
3. Connects a client socket, performs WebSocket Upgrade handshake, validates 101 Switching Protocols and `Sec-WebSocket-Accept`.
4. Receives server `handshake_ack` frame.
5. Sends client `handshake` frame, asserts `DeviceState.shared.isConnected == true`.
6. Sends client clipboard message, asserts `DeviceState.shared.lastSharedClipboard` updates.
7. Calls `ServerManager.shared.stop()`, asserts clean shutdown.

---

## 7. Headless Execution Verification

### 7.1 Headless Build Verification
- Running `swift build` requires only the Swift compiler, Darwin SDK, and SPM.
- No display server, WindowServer, or Aqua GUI session is required.
- Both `GalaxyContinuityKit` and `GalaxyContinuity` build cleanly from command-line environments (SSH, CI runners, pre-commit scripts).

### 7.2 Headless Test Verification
- `swift test` executes `XCTest` test bundles via command-line invocation (`xctest`).
- `GalaxyContinuityTests` depends ONLY on `GalaxyContinuityKit`, completely omitting AppKit UI views (`MenuBarView`, `NSStatusItem`, `NSPopover`).
- Non-blocking behavior of system APIs in headless mode:
  - `NSPasteboard.general`: available in Darwin CLI environments (equivalent to `pbcopy`/`pbpaste`).
  - `UNUserNotificationCenter`: fails/succeeds gracefully without displaying modal alerts or blocking the process.
  - `NSSound`: fails gracefully without throwing errors if no audio output device is configured.
  - Darwin Sockets: 100% headless BSD socket operations over loopback (`127.0.0.1`).
- Test isolation: tests run on dedicated port `18765`, preventing port binding conflicts if the application is running concurrently on port `8765`.

---

## 8. Step-by-Step Implementation Plan for Implementer

1. **Directory Restructuring**:
   ```bash
   mkdir -p mac/Sources/GalaxyContinuityKit/{Models,Services,Network,WebCompanion}
   mkdir -p mac/Tests/GalaxyContinuityTests
   ```
2. **Move Shared Files to `GalaxyContinuityKit`**:
   - Move `ContinuityMessage.swift` and `DeviceState.swift` to `mac/Sources/GalaxyContinuityKit/Models/`.
   - Move `BonjourService.swift`, `ClipboardSyncService.swift`, `NotificationService.swift`, and `ServerManager.swift` to `mac/Sources/GalaxyContinuityKit/Services/`.
   - Move `WebAssets.swift` to `mac/Sources/GalaxyContinuityKit/WebCompanion/`.
   - Create `mac/Sources/GalaxyContinuityKit/Network/WebSocketFramer.swift`.
3. **Refactor `ServerManager.swift`**:
   - Replace private framing methods with `WebSocketFramer.decodeFrame`, `WebSocketFramer.encodeFrame`, and `WebSocketFramer.computeAcceptKey`.
4. **Update `mac/Sources/GalaxyContinuity/`**:
   - Retain `App.swift`, `AppDelegate.swift`, `UI/MenuBarView.swift`, `UI/DevicePairingView.swift`, `UI/QuickDropView.swift`.
   - Add `import GalaxyContinuityKit` to `AppDelegate.swift` and UI files.
   - In `AppDelegate.applicationDidFinishLaunching`, add `NSApplication.shared.setActivationPolicy(.accessory)`.
5. **Update `mac/Package.swift`**:
   - Replace with the refactored manifest defining `GalaxyContinuityKit` (library), `GalaxyContinuity` (executable), and `GalaxyContinuityTests` (testTarget).
6. **Implement Test Suite**:
   - Add `HandshakeTests.swift`, `WebSocketFramingTests.swift`, `MessageSerializationTests.swift`, `HttpEndpointTests.swift`, and `SocketIntegrationTests.swift` in `mac/Tests/GalaxyContinuityTests/`.
7. **Verify**:
   - Run `cd mac && swift build`.
   - Run `cd mac && swift test`.
   - Run `cd mac && ./scripts/build_app.sh` to confirm application bundling and codesigning succeed.
