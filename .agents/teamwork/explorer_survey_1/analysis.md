# macOS Application Codebase Survey & Continuity Analysis

**Author**: Explorer Survey 1 (`teamwork_explorer`)  
**Target Codebase**: `mac/` in `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`  
**Date**: 2026-11-07  
**Scope**: Architecture, Build & Test Infrastructure, Continuity Capabilities (Implemented vs. Gaps), and Device-Free Verification Strategy.

---

## 1. Executive Summary

The macOS application for **Galaxy Continuity** is a native Swift (Swift 6.3.3 / Swift 5.9 tool-version) menu bar utility (`LSUIElement: true`) targeting macOS 13.0+. It provides a foundation for bridging macOS and Samsung Galaxy devices using a custom POSIX socket server with RFC 6455 WebSocket framing, Bonjour/mDNS local network discovery, and an embedded One UI-themed Web Companion served via HTTP on port `8765`.

### Current Readiness Summary
| Feature / Subsystem | Current Status | Parity with Apple Continuity | Missing Gaps |
|---|---|---|---|
| **Universal Clipboard** | ⚠️ Partial (Plain text only) | 50% | Missing image clipboard transfer (`image/png`, TIFF), base64 payload handling, image hash loop prevention |
| **Quick Drop** | ⚠️ Partial (Working basic file share) | 70% | Memory buffering on large uploads (needs stream sink); Android endpoint alignment; transfer progress in UI |
| **Screen Mirroring** | ❌ Missing (0%) | 0% | No video stream receiver/decoder, no mirroring window, no remote mouse/touch input event forwarding |
| **Continuity Camera** | ❌ Missing (0%) | 0% | No CoreMediaIO (`CMIOExtension`) virtual webcam, no video stream ingestion, no camera control UI |
| **Notification Sync** | ⚠️ Partial (Mac banner display only) | 40% | No interactive quick reply (`UNTextInputNotificationAction`), no reply message routing back to phone |
| **Peer Discovery** | ⚠️ Partial (Bonjour mDNS advertising only) | 35% | No Bonjour browser on Mac; no CoreBluetooth / BLE discovery; no Wi-Fi Direct connection negotiation |
| **Test Infrastructure** | ❌ Missing (0 unit/integration tests) | N/A | No SPM test target; `swift test` fails; only single manual python script `test_server.py` |

---

## 2. macOS App Project Structure & Architecture

### 2.1 File Organization
The macOS project is laid out cleanly under `mac/`:
```
mac/
├── Package.swift                             # SPM manifest (tools version 5.9, macOS 13+)
├── Info.plist                                # LSUIElement, Bonjour services, network descriptions
├── Resources/
│   └── AppIcon.icns                          # Native macOS application icon
├── Sources/GalaxyContinuity/
│   ├── App.swift                             # @main entry point running NSApplication with AppDelegate
│   ├── AppDelegate.swift                     # NSStatusItem setup, popover management, service bootstrap
│   ├── Models/
│   │   ├── ContinuityMessage.swift           # Codable WebSocket JSON message structure
│   │   └── DeviceState.swift                 # @MainActor ObservableObject singleton for UI state
│   ├── Services/
│   │   ├── BonjourService.swift              # NetService mDNS advertiser for _galaxycontinuity._tcp.
│   │   ├── ClipboardSyncService.swift        # Timer polling NSPasteboard changeCount (text only)
│   │   ├── NotificationService.swift         # UNUserNotificationCenter delegate and banner dispatcher
│   │   └── ServerManager.swift               # POSIX socket server, HTTP 1.1 parser, RFC 6455 WebSocket
│   ├── UI/
│   │   ├── DevicePairingView.swift           # QR code generator view for web pairing URL
│   │   ├── MenuBarView.swift                 # Primary popover SwiftUI dashboard
│   │   └── QuickDropView.swift               # Drag-and-drop file target and transfer list
│   └── WebCompanion/
│       └── WebAssets.swift                   # Embedded HTML5/CSS/JS Single-Page Web Companion
└── scripts/
    ├── build_app.sh                          # Compiles release binary, bundles .app, ad-hoc codesigns
    ├── generate_icon.swift                   # Programmatic icon generator (.iconset -> .icns)
    └── test_server.py                        # Minimal HTTP GET check against 127.0.0.1:8765
```

### 2.2 Architectural Layers
1. **Application Lifecycle Layer (`App.swift`, `AppDelegate.swift`)**:
   - `App.swift` initializes `NSApplication.shared` with an instance of `AppDelegate`.
   - `AppDelegate` runs as a Menu Bar Agent (`LSUIElement = true` in `Info.plist`), keeping the app out of the macOS Dock.
   - Creates `NSStatusItem` with SF Symbol `arrow.triangle.2.circlepath`.
   - Binds an `NSPopover` hosting `MenuBarView()`.
   - Starts three core services during `applicationDidFinishLaunching`:
     ```swift
     ServerManager.shared.start(port: 8765)
     BonjourService.shared.startAdvertising(port: 8765)
     ClipboardSyncService.shared.startMonitoring()
     ```
2. **State & Reactive Data Layer (`DeviceState.swift`)**:
   - Central `@MainActor ObservableObject` singleton (`DeviceState.shared`).
   - Published properties: `isConnected`, `connectedDeviceName`, `batteryLevel`, `isCharging`, `clipboardAutoSync`, `lastSharedClipboard`, `transferredFiles`, `isServerRunning`, `serverPort`, `localIPAddress`.
3. **Transport & Server Layer (`ServerManager.swift`)**:
   - Low-level POSIX BSD sockets (`socket`, `bind`, `listen`, `accept`, `read`, `write`) bound to `0.0.0.0:8765`.
   - Asynchronous I/O managed via GCD `DispatchSourceRead` on private queue `com.galaxycontinuity.server`.
   - Dual-protocol parser:
     - Handles HTTP 1.1 requests (`GET /` or `/companion`, `POST /api/upload`, `GET /api/download/:fileId`).
     - Detects `Upgrade: websocket` and completes RFC 6455 SHA1/Sec-WebSocket-Accept handshake.
     - Performs WebSocket framing: opcode 0x1 (Text), 0x8 (Close), 0x9 (Ping), 0xA (Pong), unmasking client frames.
4. **Presentation & UI Layer (`UI/`)**:
   - SwiftUI views embedded in `NSHostingController`.
   - `MenuBarView`: device status, battery level, clipboard auto-sync toggle, push button, Quick Drop dropzone, recent transfer list, pairing sheet button, ping button.
   - `QuickDropView`: handles `.onDrop(of: [UTType.fileURL.identifier])`.
   - `DevicePairingView`: generates CIQRCodeGenerator CIImage of `http://<ip>:<port>` for zero-config phone browser pairing.

---

## 3. Detailed Feature Analysis: Existing vs. Missing

### 3.1 Universal Clipboard
- **Requirement (R1 & Acceptance Criteria)**: Bidirectional synchronization transferring both plain text and image payloads between macOS and Galaxy, with loop suppression.
- **Existing Implementation**:
  - `ClipboardSyncService.swift` runs a 0.5s `Timer` on main runloop checking `NSPasteboard.general.changeCount`.
  - When count changes, checks `NSPasteboard.general.string(forType: .string)`.
  - Sends JSON `type: "clipboard"`, `contentType: "text/plain"`, `content: currentText`.
  - Incoming text triggers `NSPasteboard.general.clearContents()` and `setString(text, forType: .string)`.
  - Prevents echo loops using `lastSeenContent: String` and `isUpdatingInternally: Bool`.
- **Gaps & Defects**:
  1. **Image Clipboard Missing**: No detection or reading of `NSPasteboard.general.data(forType: .png)` or `.tiff`.
  2. **No Image Ingestion**: Incoming clipboard handler does not inspect `contentType` or decode base64 image data to write `setData(imgData, forType: .png)`.
  3. **Loop Suppression for Binary Data**: `lastSeenContent` is a `String`. Image transfers need a SHA256 content digest to avoid echo loops when an image is injected into the local pasteboard.
  4. **UI Preview**: `MenuBarView` only shows text preview (`state.lastSharedClipboard`); does not display thumbnail preview for synced images.

### 3.2 Quick Drop (Bidirectional File Transfer)
- **Requirement (R1 & Acceptance Criteria)**: Bidirectional file sending and receiving between macOS and Galaxy.
- **Existing Implementation**:
  - **Mac -> Phone**:
    - User drops files onto `QuickDropView`.
    - `ServerManager.shareFileToGalaxy(fileURL:)` assigns a UUID `fileId`, registers file URL in `sharedFiles[fileId]`.
    - Broadcasts WebSocket message `type: "file_available"` with `fileId`, `filename`, `fileSize`, `mimeType`.
    - Serves file over HTTP `GET /api/download/:fileId` with `Content-Disposition: attachment; filename="..."`.
  - **Phone -> Mac**:
    - Phone sends HTTP `POST /api/upload` with headers `X-Filename` (URL-encoded) and `Content-Length`.
    - `ServerManager.processHTTPData` extracts raw body and calls `saveUploadedFile`.
    - Saves into `~/Downloads/GalaxyContinuity/` with auto-increment naming (`file (1).ext`) if file exists.
    - Notifies user via `NotificationService` and records in `DeviceState.shared.transferredFiles`.
- **Gaps & Defects**:
  1. **Memory Buffering Bottleneck**: `ServerManager.readFromClient` appends all incoming TCP chunks into `client.readBuffer: Data`. For multi-gigabyte video files, holding the entire file in RAM before writing to disk risks out-of-memory crashes. Needs a streaming file sink that writes chunks directly to disk once the HTTP headers are parsed.
  2. **Android Alignment**: Android's `ContinuityService.onFileAvailable` currently has a placeholder comment (`// Trigger download via DownloadManager or HTTP client`), needing reciprocal automated download execution.

### 3.3 Screen Mirroring
- **Requirement (R1 & Acceptance Criteria)**: Display Galaxy screen output on macOS and process remote input actions (touch, click, drag, scroll).
- **Existing Implementation**:
  - ❌ **Completely missing on macOS.** (0% implementation).
- **Gaps & Missing Architecture**:
  1. **Stream Receiver**: Needs a video frame receiver over WebSocket binary frames or HTTP/MJPEG/H.264 stream.
  2. **Decoder & Render Pipeline**: macOS needs a display pipeline. For low-latency high-performance rendering:
     - `AVSampleBufferDisplayLayer` for H.264 NAL units (hardware accelerated via VideoToolbox).
     - Or an `NSImageView` / `Canvas` / `MetalKit` renderer for MJPEG / JPEG / raw frame buffers.
  3. **Mirroring Window & Controller**: Needs a macOS window (`ScreenMirroringWindowController` / `ScreenMirroringView`) maintaining the phone aspect ratio (e.g., 9:19.5 or 9:20 for Galaxy devices).
  4. **Remote Input Capture & Translation**:
     - Mouse down, mouse dragged, mouse up, scroll wheel, and keyboard events must be captured in the Mac window.
     - Coordinates must be normalized (0.0 to 1.0) and serialized as `remote_input` events:
       ```json
       {
         "type": "remote_input",
         "action": "down" | "move" | "up" | "scroll" | "key",
         "x": 0.425,
         "y": 0.710,
         "button": 0,
         "scrollDeltaX": 0.0,
         "scrollDeltaY": -1.5,
         "keyCode": 66
       }
       ```
     - Android handles input injection via `AccessibilityService.dispatchGesture` or virtual input injection.

### 3.4 Continuity Camera
- **Requirement (R1 & Acceptance Criteria)**: Streaming Galaxy phone camera feed recognized on macOS as a system webcam input.
- **Existing Implementation**:
  - ❌ **Completely missing on macOS.** (0% implementation).
- **Gaps & Missing Architecture**:
  1. **Virtual System Webcam Driver / CoreMediaIO Extension**:
     - macOS 12.3+ natively supports `CoreMediaIO.CMIOExtensionProvider`.
     - A CMIO extension or provider registers a virtual `CMIOExtensionDevice` (e.g. "Galaxy Continuity Camera") and `CMIOExtensionStream` of type `.video`.
     - When frame data arrives from the Galaxy camera, the provider pushes `CMSampleBuffer` frames into the stream.
     - Once registered, every macOS application (FaceTime, Zoom, Google Meet, QuickTime, Photo Booth, Chrome) recognizes the Galaxy phone as a hardware webcam!
  2. **Camera Streaming Protocol**:
     - Commands: `camera_start` (with requested resolution 1080p/720p, lens: front/back/ultra-wide), `camera_stop`, `camera_switch_lens`, `camera_torch_toggle`.
     - Data: High-speed video frame payloads (`type: "camera_frame"` or binary WebSocket frames / MJPEG stream).
  3. **Mac Continuity Camera Window & Controls**:
     - A dedicated preview window showing live camera feed with controls: Lens selector (Front / Rear Wide / Ultra-Wide), Flashlight toggle, Orientation lock, Pause video.

### 3.5 Notification Synchronization & Quick Reply
- **Requirement (R1 & Acceptance Criteria)**: Android notifications forwarded to macOS with interactive quick reply capability routing back to Android.
- **Existing Implementation**:
  - `ServerManager` receives `type: "phone_notification"` (`app`, `title`, `text`).
  - `NotificationService.showNotification` posts banner via `UNUserNotificationCenter`.
- **Gaps & Defects**:
  1. **No Quick Reply Action**: `UNTextInputNotificationAction` is never instantiated or attached to notifications.
  2. **No Category Registration**: `UNNotificationCategory` with identifier `CONTINUITY_NOTIFICATION` is not registered in `setup()`.
  3. **No Response Delegate Handler**: `userNotificationCenter(_:didReceive:withCompletionHandler:)` is omitted. When the user interacts with or types in a notification banner, the action is discarded.
  4. **Protocol Model Lacks Identifier & Reply Type**:
     - Incoming notification message needs `notificationId` / `key` and `canReply: Bool`.
     - Needs outgoing `notification_reply` message:
       ```json
       {
         "type": "notification_reply",
         "notificationId": "10023",
         "replyText": "On my way!"
       }
       ```
     - Galaxy app receives this and invokes the stored `RemoteInput` pending intent.

### 3.6 Peer Discovery (Bonjour, BLE, Wi-Fi Direct)
- **Requirement (R1 & Acceptance Criteria)**: Discovery operating over Bonjour/mDNS on local network as well as offline BLE and Wi-Fi Direct.
- **Existing Implementation**:
  - `BonjourService.swift` publishes `_galaxycontinuity._tcp.` on local network with TXT record (`name`, `platform: "macOS"`, `version: "1.0.0"`).
- **Gaps & Defects**:
  1. **No Bonjour Browsing on Mac**: Mac only publishes; it does not browse (`NetServiceBrowser`) for Galaxy devices if the phone is advertising.
  2. **No BLE (Bluetooth Low Energy) Integration**: Zero CoreBluetooth code.
     - When Mac and phone are not on the same Wi-Fi network (e.g. outdoors, traveling, Wi-Fi isolation enabled), devices cannot discover each other.
     - Needs `CBPeripheralManager` to advertise a custom Continuity GATT Service UUID and `CBCentralManager` to scan for Galaxy BLE advertisements.
  3. **Wi-Fi Direct / Hotspot Fallback**: Needs negotiation logic where discovery over BLE conveys P2P Wi-Fi credentials or IP addresses to establish a direct connection without a local router.

---

## 4. Build, Packaging & Dependencies

### 4.1 Build System & Toolchain
- **Swift Compiler**: Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101, arm64).
- **Package Manager**: Swift Package Manager (`Package.swift`).
- **Dependencies**: 0 external packages. Pure native Apple system frameworks:
  - `AppKit`, `SwiftUI`, `Foundation`, `UserNotifications`, `CryptoKit`, `CoreImage`, `Combine`, `UniformTypeIdentifiers`, `Darwin`.
  - Available system frameworks ready for expansion: `CoreMediaIO`, `CoreBluetooth`, `VideoToolbox`, `AVFoundation`.

### 4.2 Build Targets & Manifest Deficiencies
In `mac/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GalaxyContinuity",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GalaxyContinuity", targets: ["GalaxyContinuity"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GalaxyContinuity",
            dependencies: [],
            path: "Sources/GalaxyContinuity"
        )
    ]
)
```
**Issues identified**:
- Single executable target: All code (models, networking, business logic, UI) is in `Sources/GalaxyContinuity`.
- Swift Package Manager does not allow testing an `executableTarget` from a standard `testTarget`.
- Running `swift test` fails immediately: `error: no tests found; create a target in the 'Tests' directory`.

### 4.3 Packaging Scripts & Distribution
- `scripts/build_app.sh`:
  - Executes `swift build -c release`.
  - Constructs `Galaxy Continuity.app` bundle in `build/`.
  - Copies binary to `Contents/MacOS/Galaxy Continuity`.
  - Copies `Info.plist`, `AppIcon.icns`, writes `PkgInfo`.
  - Runs ad-hoc codesign: `codesign --force --deep --sign - "$APP_BUNDLE"`.
  - Installs bundle into `/Applications/Galaxy Continuity.app`.
- Successfully verified by execution and manual inspection.

---

## 5. Test Infrastructure & Physical Device-Free Verification Strategy

### 5.1 Current Test Deficiencies
- Currently **0 automated tests exist** in `mac/`.
- `mac/scripts/test_server.py` is an ad-hoc python script that queries `http://127.0.0.1:8765/` and fails if the app isn't already running in the background.

### 5.2 Recommended SPM Architecture Refactoring for Automated Testing
To enable robust automated unit and integration tests via `swift test`, the project target structure should be factored into:
1. **`GalaxyContinuityKit` (Library Target)**:
   - Contains: `Models/`, `Services/` (Networking, ServerManager, Clipboard, Notifications, Discovery, Protocols).
   - Fully decoupled from `@main` application lifecycle, allowing instant compilation and testability.
2. **`GalaxyContinuity` (Executable Target)**:
   - Contains: `App.swift`, `AppDelegate.swift`, `UI/`, `WebCompanion/`.
   - Depends on `GalaxyContinuityKit`.
3. **`GalaxyContinuityTests` (Test Target)**:
   - Depends on `GalaxyContinuityKit`.
   - Executes standard XCTest / Swift Testing suites in headless CI without requiring GUI display or interactive windows.

### 5.3 Device-Free Test Execution Strategy
All Continuity features can be verified deterministically without requiring a physical Samsung Galaxy phone by leveraging loopback networking (`127.0.0.1`), simulated socket clients, and synthetic pasteboard/media buffers:

```
┌─────────────────────────────────────────────────────────────┐
│                 macOS Host (Local Loopback)                 │
│                                                             │
│  ┌────────────────────────┐      ┌───────────────────────┐  │
│  │   Galaxy Continuity    │      │  Mock Galaxy Client   │  │
│  │     (macOS Server)     │      │ (Swift / Py / Script) │  │
│  │                        │      │                       │  │
│  │  Port 8765             │◄────►│ ws://127.0.0.1:8765   │  │
│  │  - ServerManager       │      │ http://127.0.0.1:8765 │  │
│  │  - ClipboardSync       │      │                       │  │
│  │  - NotificationService │      │ Mock Events:          │  │
│  │  - CMIO / CameraStream │      │ - Handshake           │  │
│  │  - ScreenMirroring     │      │ - Clipboard (Text/Img)│  │
│  │  - Quick Drop Storage  │      │ - Notification & Reply│  │
│  └────────────────────────┘      │ - File Upload / Fetch │  │
│                                  │ - Mock Camera Frame   │  │
│                                  │ - Screen Mirror Frame │  │
│                                  └───────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

#### Specific Test Suites:
1. **Protocol & Message Serialization (`ContinuityMessageTests`)**:
   - Verify encoding and decoding for all message types: `handshake`, `handshake_ack`, `clipboard` (text & image base64), `file_available`, `phone_notification`, `notification_reply`, `ping_device`, `battery_update`, `screen_stream_start/stop`, `remote_input`, `camera_start/frame`.
2. **WebSocket RFC 6455 Framing (`WebSocketFramingTests`)**:
   - Test short (<126), medium (126-65535), and large (>65535) payload framing.
   - Test client masking and server unmasking.
   - Test Ping (0x9) -> Pong (0xA) roundtrip and Close (0x8) handling.
3. **Universal Clipboard Integration (`ClipboardSyncTests`)**:
   - Programmatically write synthetic text and PNG image data to `NSPasteboard.general`.
   - Verify `ClipboardSyncService` detects change and broadcasts proper JSON with `contentType: "image/png"`.
   - Inject incoming synthetic phone clipboard payload and verify pasteboard data matches byte-for-byte.
   - Verify echo suppression prevents infinite re-broadcasting.
4. **Quick Drop Protocol & File I/O (`FileTransferTests`)**:
   - Upload synthetic file (e.g. 10MB test binary) via HTTP `POST /api/upload` with headers.
   - Verify file is saved in `~/Downloads/GalaxyContinuity/` with identical SHA256 checksum.
   - Register mock file with `shareFileToGalaxy`, download via HTTP `GET /api/download/:fileId`, verify response headers and content match.
5. **Interactive Notification Quick Reply (`NotificationReplyTests`)**:
   - Mock delivery of `phone_notification` with `notificationId`.
   - Simulate `UNTextInputNotificationResponse` with reply string "Meeting in 5 min".
   - Verify outgoing `notification_reply` message is broadcasted to client with matching ID.
6. **Screen Mirroring & Remote Input (`ScreenMirroringTests`)**:
   - Feed synthetic video frame packet into server.
   - Verify server decodes or dispatches frame to display view.
   - Simulate mouse click / drag on mirroring view and verify generated `remote_input` message has correct normalized coordinates.
7. **Continuity Camera Feed (`ContinuityCameraTests`)**:
   - Push synthetic MJPEG / JPEG camera frame buffer.
   - Verify frame ingestion, stream status, and CMIOExtension format description generation.
8. **End-to-End Mock Galaxy Integration (`MockGalaxyIntegrationTests`)**:
   - Automated integration script / test runner executing complete sequence over `127.0.0.1:8765`:
     - Handshake -> Ack
     - Text clipboard sync
     - Image clipboard sync
     - File upload and download
     - Notification forwarded -> Reply returned
     - Device ping

---

## 6. Implementation Action Plan & Recommendations

### Recommended Step-by-Step Blueprint:
1. **Refactor SPM Targets**:
   - Split `mac/Package.swift` into `GalaxyContinuityKit` (core library), `GalaxyContinuity` (app executable), and `GalaxyContinuityTests` (test suite).
   - Ensure `swift test` runs cleanly and is integrated into CI.
2. **Implement Universal Clipboard Image Support**:
   - Update `ContinuityMessage`: support base64 encoded image data or image data URIs (`data:image/png;base64,...`).
   - Update `ClipboardSyncService`: poll `NSPasteboard.general.data(forType: .png)` and `.tiff`; convert TIFF to PNG; compute SHA256 to prevent echo; inject incoming images to pasteboard.
   - Update UI in `MenuBarView` to display thumbnail if last clipboard item is an image.
3. **Implement Notification Quick Reply**:
   - Define `UNTextInputNotificationAction(identifier: "REPLY_ACTION", ...)`.
   - Register category `CONTINUITY_NOTIFICATION` in `NotificationService`.
   - Implement `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
   - Route reply back over WebSocket to Galaxy device via `notification_reply` message.
4. **Implement Screen Mirroring Module**:
   - Add messages: `screen_stream_start`, `screen_stream_stop`, `screen_stream_frame`, `remote_input`.
   - Create `ScreenMirroringView` and window controller in macOS app with aspect-fit rendering.
   - Capture mouse/drag/click/scroll events, normalize coordinates, send to Galaxy.
5. **Implement Continuity Camera Module**:
   - Implement CoreMediaIO extension provider or CMIO virtual stream provider.
   - Create camera preview window with resolution and lens switching controls.
6. **Implement BLE Discovery Service**:
   - Add `BLEDiscoveryService` utilizing `CoreBluetooth.CBPeripheralManager` and `CBCentralManager` with designated Continuity Service UUID.
7. **Automated Verification**:
   - Build automated test suite covering all unit and protocol integration cases.
   - Execute verification locally on macOS without physical devices.
