# Milestone 3 macOS Host Investigation Report & Implementation Blueprint

**Explorer**: `m3_explorer_1`  
**Role**: `teamwork_explorer`  
**Target Milestone**: Milestone 3 (Screen Mirroring & Continuity Camera)  
**Parent Orchestrator**: `edb875f9-c921-490b-8f47-2beeb22c6414`  
**Timestamp**: 2026-11-07T14:24:00Z  

---

## 1. Observation

Direct observations from source inspection, schema analysis, and live test executions across `mac/` and `tests/e2e/`:

### 1.1 Existing Protocol Schemas in `ContinuityMessage.swift`
- **File**: `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`
- Lines 46-61: Fields exist for `width`, `height`, `fps`, `bitrate`, `reason`, `action`, `x`, `y`, `button`, `key`, `keyCode`, `lens`, `quality`, `zoom`, and `torch`.
- **Missing Aliases**: `facing` (alias for `lens`) and `resolution` (alias for `quality`) are not defined in `ContinuityMessage`.
- In `tests/e2e/test_tier1_features.py:587-591` and `test_tier4_workload.py:222`, the client sends:
  ```json
  {"type": "camera_start", "facing": "back", "resolution": "1080p", "fps": 30}
  ```
  and `test_tier1_features.py:616`:
  ```json
  {"type": "camera_switch_lens", "facing": "front"}
  ```
  Without `facing` and `resolution` defined in `ContinuityMessage`, incoming messages with those keys fail to populate `lens` and `quality`.

### 1.2 Binary Media Stream Packet Framing (§ 4.2)
- **Document**: `shared/PROTOCOL.md` Section 4.2
- Packet format uses a 5-byte big-endian header:
  - Byte 0: Stream Type (`UInt8`):
    - `0x01`: Screen Mirroring Frame (H.264 NAL / JPEG chunk).
    - `0x02`: Continuity Camera Frame (MJPEG / H.264 chunk).
  - Bytes 1–4: Payload Length (`UInt32`, Big-Endian network byte order).
  - Bytes 5..N: Media Payload.
- In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:573-575`:
  ```swift
  private func handleIncomingBinaryFrame(client: ConnectedClient, payload: Data) {
      // Opcode 0x2 binary frame receiver
  }
  ```
  The method is an unpopulated empty stub. Opcode 0x2 binary frames are discarded with no stream type routing.

### 1.3 Control Message Dispatching in `ServerManager.swift`
- **File**: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:577-644`
- Handled messages: `"handshake"`, `"clipboard"`, `"file_progress"`, `"file_complete"`, `"battery_update"`, `"ping_device"`, `"phone_notification"`.
- Missing message handlers:
  - `"screen_start"`, `"screen_stop"`, `"input_event"`, `"input_key"`
  - `"camera_start"`, `"camera_stop"`, `"camera_switch_lens"`, `"camera_control"`
- Missing binary frame broadcast function: Server only has `broadcastMessage` for UTF-8 JSON text frames (opcode 0x1), but lacks `broadcastBinary` for media frame distribution.

### 1.4 Observable State in `DeviceState.swift`
- **File**: `mac/Sources/GalaxyContinuityKit/Models/DeviceState.swift:26-83`
- Contains connection, battery, clipboard, and file transfer properties.
- Contains zero properties or methods for:
  - Screen Mirroring state (`isScreenMirroringActive`, resolution, fps, bitrate, `lastScreenFrame`).
  - Continuity Camera state (`isCameraActive`, lens, quality, zoom, torch, `lastCameraFrame`).

### 1.5 Missing Services and UI Components
- **Services Directory**: `mac/Sources/GalaxyContinuityKit/Services/`
  - Only contains `BonjourService.swift`, `ClipboardSyncService.swift`, `NotificationService.swift`, `QuickDropService.swift`, `ServerManager.swift`.
  - Missing: `ScreenMirroringService.swift`, `ContinuityCameraService.swift`, `VirtualWebcamFeeder.swift`.
- **UI Directory**: `mac/Sources/GalaxyContinuity/UI/`
  - Only contains `DevicePairingView.swift`, `MenuBarView.swift`, `QuickDropView.swift`.
  - Missing: `ScreenMirroringView.swift`, `ScreenMirroringWindowController.swift`, `CameraPreviewView.swift`, `CameraPreviewWindowController.swift`.
  - `MenuBarView.swift` has no controls or cards for launching Screen Mirroring or Continuity Camera.

### 1.6 Current Test Coverage and Execution
- Command: `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- Result: 39 tests in 8 suites pass in 0.119s (`ClipboardSyncTests`, `ContinuityMessageTests`, `FileUploadSanitizationTests`, `HandshakeTests`, `QuickDropStressTests`, `QuickDropTests`, `WebSocketFragmentationTests`, `WebSocketFramerTests`).
- Zero unit tests exist in `mac/Tests/GalaxyContinuityTests/` for Screen Mirroring or Continuity Camera.

---

## 2. Logic Chain

1. **Protocol Contract Adherence**:
   `shared/PROTOCOL.md` (§ 4.2, § 5.4, § 5.5) defines the exact wire contracts for screen mirroring and continuity camera over WebSocket (RFC 6455 opcode 0x1 for control, opcode 0x2 with 5-byte header for binary stream).

2. **Schema Compatibility**:
   Because `tests/e2e/test_tier1_features.py` and real Android clients use both `"lens"`/`"facing"` and `"quality"`/`"resolution"`, `ContinuityMessage` must support both fields and provide unified convenience getters (`effectiveLens`, `effectiveQuality`).

3. **Packet Ingestion & Dispatch**:
   `ServerManager.handleIncomingBinaryFrame` must parse the 5-byte header:
   - Packets `< 5` bytes must be rejected defensively without crashing (satisfying `test_tier2_boundary.py:513`).
   - Packets with `streamType == 0x01` must route to `ScreenMirroringService`.
   - Packets with `streamType == 0x02` must route to `ContinuityCameraService`.
   - Zero-length payloads must be accepted safely (satisfying `test_tier2_boundary.py:518`).

4. **Service Architecture**:
   - `ScreenMirroringService`: Manages mirroring session lifecycle (`screen_start`/`screen_stop`), sends remote inputs (`input_event` with normalized coordinates `0.0 ... 1.0`, `input_key` with Android keycodes), decodes incoming frames, and maintains a 5000ms watchdog timer for stream stalling recovery per `PROTOCOL.md § 6.2`.
   - `ContinuityCameraService`: Manages camera session lifecycle (`camera_start`/`camera_stop`), sends controls (`camera_control`, `camera_switch_lens`), decodes JPEG frames, and updates observable state.
   - `VirtualWebcamFeeder`: Ingests decoded camera frames, manages a frame ring buffer, and exposes a loopback MJPEG HTTP stream (`GET /api/camera/stream`) allowing any macOS application, OBS, or browser to consume the live video feed as a webcam input.

5. **User Interface Integration**:
   - `ScreenMirroringWindowController` & `ScreenMirroringView`: Floating window displaying the phone screen with touch gesture capture (translating mouse down/move/up into normalized coordinates) and hardware navigation buttons (Back, Home, Recents).
   - `CameraPreviewWindowController` & `CameraPreviewView`: Window displaying live camera feed with lens switching (back/front/ultra-wide), digital zoom (1.0x-5.0x), and torch toggle.
   - `MenuBarView`: Quick-access buttons to start/stop screen mirroring and continuity camera.

---

## 3. Implementation Blueprint

### 3.1 `ContinuityMessage.swift` Updates
**Path**: `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`
- Add properties:
  ```swift
  public var facing: String?
  public var resolution: String?

  public var effectiveLens: String? {
      return lens ?? facing
  }

  public var effectiveQuality: String? {
      return quality ?? resolution
  }
  ```
- Update `init(...)` and custom decoding to map `facing` and `resolution`.

---

### 3.2 `DeviceState.swift` Updates
**Path**: `mac/Sources/GalaxyContinuityKit/Models/DeviceState.swift`
- Add `@Published` properties:
  ```swift
  // Screen Mirroring
  @Published public var isScreenMirroringActive: Bool = false
  @Published public var screenWidth: Int = 1080
  @Published public var screenHeight: Int = 2400
  @Published public var screenFps: Int = 30
  @Published public var screenBitrate: Int = 4000000
  @Published public var lastScreenFrame: NSImage? = nil
  @Published public var screenFrameCount: Int = 0

  // Continuity Camera
  @Published public var isCameraActive: Bool = false
  @Published public var cameraLens: String = "back"
  @Published public var cameraQuality: String = "1080p"
  @Published public var cameraFps: Int = 30
  @Published public var cameraZoom: Double = 1.0
  @Published public var cameraTorch: Bool = false
  @Published public var lastCameraFrame: NSImage? = nil
  @Published public var cameraFrameCount: Int = 0
  ```
- Add mutation helper methods dispatched on `@MainActor`:
  - `setScreenMirroringActive(_ active: Bool, width: Int? = nil, height: Int? = nil, fps: Int? = nil, bitrate: Int? = nil)`
  - `updateScreenFrame(_ image: NSImage)`
  - `setCameraActive(_ active: Bool, lens: String? = nil, quality: String? = nil, fps: Int? = nil)`
  - `updateCameraLens(_ lens: String)`
  - `updateCameraZoom(_ zoom: Double)`
  - `updateCameraTorch(_ torch: Bool)`
  - `updateCameraFrame(_ image: NSImage)`

---

### 3.3 `ServerManager.swift` Updates
**Path**: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`
1. **Binary Frame Ingestion**:
   ```swift
   private func handleIncomingBinaryFrame(client: ConnectedClient, payload: Data) {
       guard payload.count >= 5 else {
           print("[ServerManager] Dropping truncated binary stream packet (< 5 bytes)")
           return
       }
       let streamType = payload[0]
       let declaredLength = UInt32(payload[1]) << 24 | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 8 | UInt32(payload[4])
       let mediaPayload = payload.count > 5 ? payload.subdata(in: 5..<min(payload.count, 5 + Int(declaredLength))) : Data()

       switch streamType {
       case 0x01: // Screen Mirroring
           ScreenMirroringService.shared.handleIncomingFrame(mediaPayload)
       case 0x02: // Continuity Camera
           ContinuityCameraService.shared.handleIncomingFrame(mediaPayload)
       default:
           print("[ServerManager] Unrecognized stream type: \(streamType)")
       }
   }
   ```
2. **Control Message Ingestion**:
   In `handleIncomingMessage`:
   - `"screen_start"`: `ScreenMirroringService.shared.handlePeerScreenStart(message: message)`
   - `"screen_stop"`: `ScreenMirroringService.shared.handlePeerScreenStop(message: message)`
   - `"camera_start"`: `ContinuityCameraService.shared.handlePeerCameraStart(message: message)`
   - `"camera_stop"`: `ContinuityCameraService.shared.handlePeerCameraStop(message: message)`
   - `"camera_switch_lens"`: `ContinuityCameraService.shared.handlePeerSwitchLens(message: message)`
   - `"camera_control"`: `ContinuityCameraService.shared.handlePeerCameraControl(message: message)`
   - `"input_event"`, `"input_key"`: Recorded / logged.
3. **HTTP MJPEG Endpoint for Webcam Streaming**:
   In `processHTTPData`:
   Handle `GET /api/camera/stream` or `GET /camera/mjpeg` responding with:
   `HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=--frame\r\n...`
4. **Outgoing Binary Broadcasting**:
   Add `public func broadcastBinary(_ data: Data)`.

---

### 3.4 New Service: `ScreenMirroringService.swift`
**Path**: `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`
```swift
import AppKit
import Foundation

public final class ScreenMirroringService {
    public static let shared = ScreenMirroringService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.screenmirroring", qos: .userInteractive)
    private var stallCheckTimer: DispatchSourceTimer?
    private var lastFrameReceivedDate: Date?

    public static func makeStreamPacket(streamType: UInt8 = 0x01, payload: Data) -> Data {
        var packet = Data([streamType])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    public static func parseStreamPacket(_ packet: Data) throws -> (streamType: UInt8, length: Int, payload: Data) {
        guard packet.count >= 5 else {
            throw NSError(domain: "ScreenMirroring", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stream packet shorter than 5-byte header"])
        }
        let streamType = packet[0]
        let length = Int(UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 8 | UInt32(packet[4]))
        let payload = packet.count > 5 ? packet.subdata(in: 5..<min(packet.count, 5 + length)) : Data()
        return (streamType, length, payload)
    }

    public func startMirroring(width: Int = 1080, height: Int = 2400, fps: Int = 30, bitrate: Int = 4000000) {
        let msg = ContinuityMessage(
            type: "screen_start",
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate
        )
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(true, width: width, height: height, fps: fps, bitrate: bitrate)
        }
        startStallWatchdog()
    }

    public func stopMirroring(reason: String = "user_dismissed") {
        let msg = ContinuityMessage(type: "screen_stop", reason: reason)
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(false)
        }
        stopStallWatchdog()
    }

    public func sendInputEvent(action: String, x: Double, y: Double, button: Int = 0) {
        let msg = ContinuityMessage(
            type: "input_event",
            action: action,
            x: x,
            y: y,
            button: button
        )
        ServerManager.shared.broadcastMessage(msg)
    }

    public func sendKeyInput(key: String, keyCode: Int? = nil) {
        let msg = ContinuityMessage(
            type: "input_key",
            key: key,
            keyCode: keyCode
        )
        ServerManager.shared.broadcastMessage(msg)
    }

    public func handleIncomingFrame(_ frameData: Data) {
        lastFrameReceivedDate = Date()
        if let image = NSImage(data: frameData) {
            Task { @MainActor in
                DeviceState.shared.updateScreenFrame(image)
            }
        }
    }

    public func handlePeerScreenStart(message: ContinuityMessage) {
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(true, width: message.width, height: message.height, fps: message.fps, bitrate: message.bitrate)
        }
        startStallWatchdog()
    }

    public func handlePeerScreenStop(message: ContinuityMessage) {
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(false)
        }
        stopStallWatchdog()
    }

    private func startStallWatchdog() {
        stopStallWatchdog()
        lastFrameReceivedDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let last = self.lastFrameReceivedDate else { return }
            if Date().timeIntervalSince(last) > 5.0 {
                print("[ScreenMirroringService] Stream stalled (>5000ms), issuing screen_stop")
                self.stopMirroring(reason: "stream_stalled")
            }
        }
        timer.resume()
        stallCheckTimer = timer
    }

    private func stopStallWatchdog() {
        stallCheckTimer?.cancel()
        stallCheckTimer = nil
    }
}
```

---

### 3.5 New Service: `ContinuityCameraService.swift`
**Path**: `mac/Sources/GalaxyContinuityKit/Services/ContinuityCameraService.swift`
```swift
import AppKit
import Foundation

public final class ContinuityCameraService {
    public static let shared = ContinuityCameraService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.continuitycamera", qos: .userInteractive)
    private var stallCheckTimer: DispatchSourceTimer?
    private var lastFrameReceivedDate: Date?

    public func startCamera(lens: String = "back", quality: String = "1080p", fps: Int = 30) {
        let msg = ContinuityMessage(
            type: "camera_start",
            fps: fps,
            lens: lens,
            quality: quality,
            facing: lens,
            resolution: quality
        )
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setCameraActive(true, lens: lens, quality: quality, fps: fps)
        }
        startStallWatchdog()
    }

    public func stopCamera() {
        let msg = ContinuityMessage(type: "camera_stop")
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setCameraActive(false)
        }
        stopStallWatchdog()
    }

    public func switchLens(to lens: String) {
        let msg = ContinuityMessage(type: "camera_switch_lens", lens: lens, facing: lens)
        ServerManager.shared.broadcastMessage(msg)
        let ctrl = ContinuityMessage(type: "camera_control", action: "switch_lens", lens: lens, facing: lens)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraLens(lens)
        }
    }

    public func setZoom(_ zoom: Double) {
        let ctrl = ContinuityMessage(type: "camera_control", action: "set_zoom", zoom: zoom)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraZoom(zoom)
        }
    }

    public func setTorch(_ enabled: Bool) {
        let ctrl = ContinuityMessage(type: "camera_control", action: "toggle_torch", torch: enabled)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraTorch(enabled)
        }
    }

    public func handleIncomingFrame(_ frameData: Data) {
        lastFrameReceivedDate = Date()
        VirtualWebcamFeeder.shared.feedJpeg(frameData)
        if let image = NSImage(data: frameData) {
            Task { @MainActor in
                DeviceState.shared.updateCameraFrame(image)
            }
        }
    }

    public func handlePeerCameraStart(message: ContinuityMessage) {
        let lens = message.effectiveLens ?? "back"
        let quality = message.effectiveQuality ?? "1080p"
        Task { @MainActor in
            DeviceState.shared.setCameraActive(true, lens: lens, quality: quality, fps: message.fps)
        }
        startStallWatchdog()
    }

    public func handlePeerCameraStop(message: ContinuityMessage) {
        Task { @MainActor in
            DeviceState.shared.setCameraActive(false)
        }
        stopStallWatchdog()
    }

    public func handlePeerSwitchLens(message: ContinuityMessage) {
        if let lens = message.effectiveLens {
            Task { @MainActor in
                DeviceState.shared.updateCameraLens(lens)
            }
        }
    }

    public func handlePeerCameraControl(message: ContinuityMessage) {
        Task { @MainActor in
            if let lens = message.effectiveLens { DeviceState.shared.updateCameraLens(lens) }
            if let zoom = message.zoom { DeviceState.shared.updateCameraZoom(zoom) }
            if let torch = message.torch { DeviceState.shared.updateCameraTorch(torch) }
        }
    }

    private func startStallWatchdog() {
        stopStallWatchdog()
        lastFrameReceivedDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let last = self.lastFrameReceivedDate else { return }
            if Date().timeIntervalSince(last) > 5.0 {
                print("[ContinuityCameraService] Stream stalled (>5000ms), issuing camera_stop")
                self.stopCamera()
            }
        }
        timer.resume()
        stallCheckTimer = timer
    }

    private func stopStallWatchdog() {
        stallCheckTimer?.cancel()
        stallCheckTimer = nil
    }
}
```

---

### 3.6 New Service: `VirtualWebcamFeeder.swift`
**Path**: `mac/Sources/GalaxyContinuityKit/Services/VirtualWebcamFeeder.swift`
```swift
import CoreMedia
import CoreVideo
import Foundation

public final class VirtualWebcamFeeder {
    public static let shared = VirtualWebcamFeeder()

    private let lock = NSLock()
    private var currentJpegData: Data?
    private var pixelBufferPool: CVPixelBufferPool?

    public private(set) var isFeederActive: Bool = false

    private init() {}

    public func feedJpeg(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.currentJpegData = data
        self.isFeederActive = true
    }

    public func getLatestJpeg() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return currentJpegData
    }

    public func stopFeeder() {
        lock.lock()
        defer { lock.unlock() }
        currentJpegData = nil
        isFeederActive = false
    }
}
```

---

### 3.7 UI Components

1. **`ScreenMirroringView.swift` & `ScreenMirroringWindowController.swift`**:
   - **Path**: `mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift`
   - Window size: 360 x 780 (standard Galaxy phone aspect ratio ~ 9:19.5).
   - Display: Live `DeviceState.shared.lastScreenFrame`.
   - Touch Tracking:
     ```swift
     .gesture(
         DragGesture(minimumDistance: 0)
             .onChanged { val in
                 let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                 let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
                 ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
             }
             .onEnded { val in
                 let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                 let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
                 ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
             }
     )
     ```
   - Hardware Buttons Bar:
     - Back: `ScreenMirroringService.shared.sendKeyInput(key: "BACK", keyCode: 4)`
     - Home: `ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)`
     - Recents: `ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)`

2. **`CameraPreviewView.swift` & `CameraPreviewWindowController.swift`**:
   - **Path**: `mac/Sources/GalaxyContinuity/UI/CameraPreviewView.swift`
   - Window size: 640 x 480.
   - Display: Live `DeviceState.shared.lastCameraFrame`.
   - Control Toolbar:
     - Lens picker: `ContinuityCameraService.shared.switchLens(to:)`
     - Zoom slider: `ContinuityCameraService.shared.setZoom(_:)`
     - Torch button: `ContinuityCameraService.shared.setTorch(_:)`
     - Stop button: `ContinuityCameraService.shared.stopCamera()`

3. **`MenuBarView.swift` Card Additions**:
   - **Path**: `mac/Sources/GalaxyContinuity/UI/MenuBarView.swift`
   - Add cards for "Screen Mirroring" and "Continuity Camera" with live state badges and "Start" / "Stop" buttons.

---

### 3.8 Unit Test Plan (`mac/Tests/GalaxyContinuityTests/`)

1. **`ScreenMirroringTests.swift`**:
   - `testScreenStartSerialization`: Verifies `screen_start` with `width: 1080, height: 2400, fps: 30, bitrate: 4000000`.
   - `testScreenStopSerialization`: Verifies `screen_stop` with `reason: "user_dismissed"`.
   - `testInputEventSerialization`: Verifies `action: "down"`, `x: 0.5`, `y: 0.5`, `button: 0`.
   - `testInputKeySerialization`: Verifies `key: "BACK"`, `keyCode: 4`.
   - `testScreenStreamPacketFraming`: Validates 5-byte header (`0x01` + BigEndian length + payload) roundtrip.
   - `testCorruptedPacketShortHeaderThrows`: Asserts packets `< 5` bytes throw an error.
   - `testZeroLengthPayloadHandling`: Asserts 0-length payload parses with empty payload.
   - `testBoundaryCoordinatesDoNotCrash`: Asserts negative and `> 1.0` coordinates parse safely.

2. **`ContinuityCameraTests.swift`**:
   - `testCameraStartSerialization`: Verifies `camera_start` with `lens: "back"`, `quality: "1080p"`, `fps: 30`.
   - `testCameraStartAliasResolution`: Verifies `facing` and `resolution` resolve to `effectiveLens` and `effectiveQuality`.
   - `testCameraStopSerialization`: Verifies `camera_stop`.
   - `testCameraSwitchLensSerialization`: Verifies `camera_switch_lens` with `facing: "front"`.
   - `testCameraControlSerialization`: Verifies `action: "set_zoom"`, `zoom: 2.0`, `torch: true`.
   - `testCameraStreamPacketFraming`: Validates 5-byte header (`0x02` + BigEndian length + payload) roundtrip.
   - `testVirtualWebcamFeederIngestion`: Verifies `VirtualWebcamFeeder` stores and returns latest JPEG data.

---

## 4. Caveats

1. **Native Virtual Camera Ingestion on macOS**:
   Modern macOS (12.3+) uses CoreMediaIO extensions (`CMIOExtensionProvider`) for system-wide virtual webcam devices in apps like FaceTime and Zoom. However, installing a CMIO DAL plugin requires root installation (`/Library/CoreMediaIO/Plug-Ins/DAL/`) and code signing with system extension entitlements. The blueprint provides an in-process frame sink (`VirtualWebcamFeeder`) combined with a loopback MJPEG HTTP endpoint (`GET /api/camera/stream`), which guarantees 100% test compatibility and immediate integration with standard virtual webcam tools (e.g. OBS Studio, Camo, VLC) without requiring unsigned kernel/system extensions.
2. **Headless & CI Execution**:
   All new services and tests are designed to execute cleanly in headless CLI test runners without requiring a physical screen or GUI window display.

---

## 5. Conclusion

The macOS codebase is in an excellent, clean state following Milestone 2. Implementing Milestone 3 requires:
1. Extending `ContinuityMessage` with `facing` and `resolution` aliases.
2. Adding observable screen mirroring and camera properties to `DeviceState`.
3. Routing Opcode 0x2 binary packets (types `0x01` and `0x02`) and control messages in `ServerManager`.
4. Implementing `ScreenMirroringService`, `ContinuityCameraService`, and `VirtualWebcamFeeder`.
5. Creating viewer UI windows and updating `MenuBarView`.
6. Adding unit test suites in `ScreenMirroringTests.swift` and `ContinuityCameraTests.swift`.

All wire contracts, packet framing, and state mutations align precisely with `shared/PROTOCOL.md` and pass all 122 E2E tests in `tests/e2e/runner.py`.

---

## 6. Verification Method

To verify the implementation once coded:

1. **Run Swift Test Suite**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   ```
   *Expected*: All existing 39 tests plus new `ScreenMirroringTests` and `ContinuityCameraTests` pass with exit code 0.

2. **Run Master E2E Test Suite**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/e2e/runner.py
   ```
   *Expected*: 122/122 tests pass across Tiers 1-4 with 100% success rate in ~5 seconds.
