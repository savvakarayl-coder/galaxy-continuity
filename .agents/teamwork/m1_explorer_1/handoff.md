# Handoff Report: macOS Package Refactoring & Test Target Layout

**Agent**: M1 Explorer 1 (`teamwork_explorer`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_explorer_1`  
**Milestone**: M1 (Architecture & Test Harness Enablement)  
**Date**: 2026-11-07  

---

## 1. Observation

1. **Current `mac/Package.swift`**:
   - `mac/Package.swift:4-23`:
     ```swift
     let package = Package(
         name: "GalaxyContinuity",
         platforms: [
             .macOS(.v13)
         ],
         products: [
             .executable(
                 name: "GalaxyContinuity",
                 targets: ["GalaxyContinuity"]
             )
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
   - Defines a single executable target `GalaxyContinuity` encompassing all 12 source files.

2. **Current `swift test` failure**:
   - Command: `cd mac && swift test`
   - Verbatim output:
     ```
     [0/1] Planning build
     Building for debugging...
     [0/3] Write swift-version--1AB21518FC5DEDBE.txt
     Build complete! (0.14s)
     error: no tests found; create a target in the 'Tests' directory
     ```
   - Exit code: 1.

3. **Current Source Distribution**:
   - Running `swift package describe` shows 12 source files in `Sources/GalaxyContinuity`:
     - Entry & AppKit Lifecycle: `App.swift:3-12` (`@main enum MainApp`), `AppDelegate.swift:5-60` (`AppDelegate: NSObject, NSApplicationDelegate`).
     - Models: `Models/ContinuityMessage.swift:3-81` (`BatteryInfo`, `ContinuityMessage`), `Models/DeviceState.swift:4-81` (`FileTransferItem`, `DeviceState: ObservableObject`).
     - Services: `Services/BonjourService.swift:3-43` (`BonjourService: NSObject, NetServiceDelegate`), `Services/ClipboardSyncService.swift:5-99` (`ClipboardSyncService`), `Services/NotificationService.swift:5-56` (`NotificationService: NSObject, UNUserNotificationCenterDelegate`), `Services/ServerManager.swift:6-610` (`ConnectedClient`, `ServerManager`).
     - UI: `UI/DevicePairingView.swift:5-93`, `UI/MenuBarView.swift:4-166`, `UI/QuickDropView.swift:5-118`.
     - Web Companion: `WebCompanion/WebAssets.swift:3-705` (`WebAssets.html`).

4. **WebSocket & Protocol Implementation in `ServerManager.swift`**:
   - Handshake: `ServerManager.swift:346-376` (`performWebSocketHandshake` calculates SHA-1 + base64 of key + GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).
   - Frame Decoding: `ServerManager.swift:378-423` (`processWebSocketData` parses opcode, mask bit, 7-bit, 16-bit, and 64-bit payload lengths, unmasking payload).
   - Frame Encoding: `ServerManager.swift:516-535` (`sendFrame` encodes 7-bit length <= 125, 16-bit length <= 65535, 64-bit length > 65535).
   - Coupling: All framing methods are marked `private` and coupled directly to `ConnectedClient` socket file descriptors.

5. **Application Bundling & Menu Bar Configuration**:
   - `mac/Info.plist:25-26`:
     ```xml
     <key>LSUIElement</key>
     <true/>
     ```
   - `mac/scripts/build_app.sh:9-25`:
     ```bash
     swift build -c release
     cp "$PROJECT_DIR/.build/release/GalaxyContinuity" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
     cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
     ```
   - Builds `.build/release/GalaxyContinuity` and wraps it into `.app` with `Info.plist`.

---

## 2. Logic Chain

1. **Target Splitting Need**:
   - Observation 2 demonstrates that `swift test` cannot execute because no test target exists in `Package.swift`.
   - In SPM, a `.testTarget` cannot depend on an `.executableTarget` directly for symbol linking without declaring a separate library target or using `@testable import` on a library.
   - Therefore, core protocol, state, and networking services must be packaged into a library target (`GalaxyContinuityKit`).

2. **Component Separation**:
   - From Observation 3, the codebase clearly bifurcates into:
     - Core headless services and protocol models (`ContinuityMessage`, `DeviceState`, `BonjourService`, `ClipboardSyncService`, `NotificationService`, `ServerManager`, `WebAssets`).
     - Menu bar presentation and UI views (`App.swift`, `AppDelegate.swift`, `MenuBarView.swift`, `DevicePairingView.swift`, `QuickDropView.swift`).
   - Moving core services to `Sources/GalaxyContinuityKit/` allows them to be shared cleanly between the executable app and the test target.

3. **Protocol Testability**:
   - Observation 4 shows that RFC 6455 framing and handshake computation are `private` within `ServerManager.swift`.
   - By factoring these algorithms into `WebSocketFramer` within `GalaxyContinuityKit/Network/`, the test suite `GalaxyContinuityTests` can thoroughly verify 7-bit, 16-bit, 64-bit framing, masking/unmasking, and SHA-1 accept hashes without requiring live network connections.
   - Concurrently, `ServerManager` can be tested via loopback sockets (`127.0.0.1:18765`) to verify live end-to-end socket handshakes and HTTP uploads.

4. **Preservation of `LSUIElement`**:
   - Observation 5 shows that `build_app.sh` depends on copying `.build/release/GalaxyContinuity` into the `.app` bundle.
   - Retaining `GalaxyContinuity` as the executable product name ensures that `build_app.sh` continues to work with zero modifications.
   - When launched from `/Applications/Galaxy Continuity.app`, LaunchServices reads `LSUIElement: true` from `Info.plist` and hides the Dock icon.
   - Adding `NSApplication.shared.setActivationPolicy(.accessory)` in `AppDelegate.swift` guarantees menu-bar-only behavior even when running raw binaries via `swift run`.

5. **Headless Execution Compatibility**:
   - Darwin sockets, `NSPasteboard`, `UNUserNotificationCenter`, and Foundation/Combine do not require an active display server or Aqua GUI session.
   - `GalaxyContinuityTests` does not import or link SwiftUI views or AppKit popovers, ensuring `swift test` runs cleanly in any headless CI runner or terminal.

---

## 3. Caveats

1. **Port Isolation**: `ServerManager` defaults to port 8765. Unit and integration tests must invoke `ServerManager.shared.start(port: 18765)` to prevent port binding conflicts with any live instance of Galaxy Continuity.
2. **Notification Permissions in CI**: In headless CI environments without a registered bundle ID, `UNUserNotificationCenter.requestAuthorization` may complete with an error or denied status. `NotificationService` handles this gracefully and does not throw fatal exceptions.
3. **Strict Concurrency in Future Swift 6 Tools Versions**: The manifest currently specifies `swift-tools-version: 5.9`. If upgraded to `6.0` in the future, explicit `Sendable` annotations on data payloads may be required.

---

## 4. Conclusion

The refactoring path is clear, zero-risk, and backward-compatible:
1. Split `mac/Package.swift` into `GalaxyContinuityKit` (library), `GalaxyContinuity` (executable), and `GalaxyContinuityTests` (test target).
2. Move core services and models into `mac/Sources/GalaxyContinuityKit/`, extract `WebSocketFramer`, and maintain UI in `mac/Sources/GalaxyContinuity/`.
3. Add `GalaxyContinuityTests` implementing `HandshakeTests`, `WebSocketFramingTests` (7/16/64-bit), `HttpEndpointTests`, `MessageSerializationTests`, and `SocketIntegrationTests`.
4. The proposed structure enables `swift build` and `swift test` to execute headlessly and cleanly with zero dependencies on GUI interaction.

---

## 5. Verification Method

1. **Inspect Package Structure**:
   ```bash
   cd mac && swift package describe
   ```
   *Expected*: Shows products `GalaxyContinuityKit` (library) and `GalaxyContinuity` (executable), with targets `GalaxyContinuityKit`, `GalaxyContinuity`, and `GalaxyContinuityTests`.

2. **Verify Headless Build**:
   ```bash
   cd mac && swift build
   ```
   *Expected*: Compiles `GalaxyContinuityKit` and `GalaxyContinuity` with exit code 0.

3. **Verify Headless Tests**:
   ```bash
   cd mac && swift test
   ```
   *Expected*: Compiles `GalaxyContinuityTests` and executes test cases across framing, handshake, serialization, endpoints, and socket integration with all tests passing.

4. **Verify Application Bundle & Codesigning**:
   ```bash
   cd mac && ./scripts/build_app.sh
   ```
   *Expected*: Produces `build/Galaxy Continuity.app`, copies `Info.plist` with `LSUIElement: true`, codesigns ad-hoc, and verifies signature with `codesign -vvv`.
