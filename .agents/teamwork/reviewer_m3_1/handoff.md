# Milestone 3 Review & Adversarial Critic Report
## macOS Screen Mirroring & Continuity Camera Implementation Review

- **Reviewer**: `reviewer_m3_1`
- **Roles**: reviewer, critic
- **Target Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/reviewer_m3_1`
- **Reviewed Worker**: `worker_m3`
- **Parent Conversation ID**: `edb875f9-c921-490b-8f47-2beeb22c6414`
- **Timestamp**: 2026-11-07T14:45:00Z

---

## Review Summary

**Verdict**: **REQUEST_CHANGES**

**Integrity Audit**: **PASS** (No integrity violations detected: no hardcoded test outputs, no fake test assertions, no fabricated logs, and zero cheating).

**Key Rationale**:
While the codebase demonstrates high engineering quality, clean architecture, and 100% passing test execution across SwiftPM and E2E suites, an adversarial review uncovered two functional blockers that will break real-world operation between the macOS host and Galaxy client:
1. **Critical Input Gesture Fault**: `ScreenMirroringView.swift` never dispatches `"down"` input events from its `DragGesture`, causing Android's `ContinuityAccessibilityService` to default `downX, downY` to `(0, 0)`, converting every viewer tap into an accidental swipe across the phone screen from the top-left corner.
2. **Major Video Decoding Mismatch**: Android's `ScreenMirroringService.kt` captures and transmits raw H.264 NAL units (`video/avc`), but macOS `ScreenMirroringService.swift` attempts to decode incoming frames using `NSImage(data:)`, which strictly fails on H.264 NAL bitstreams (`NSImage` returns `nil`), leaving the macOS mirroring viewer blank.
3. **Major Snapshot vs Multipart MJPEG Endpoint**: `GET /api/camera/stream` serves a single image with `Content-Type: image/jpeg` and `Connection: close`, which drops continuous stream consumers like OBS or web browser players.

---

## Findings

### 1. [Critical] Missing `"down"` Action in `ScreenMirroringView.swift` Breaks Android Touch Injection

- **Where**:
  - `mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift:32-46`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt:58-75`
- **What**:
  In `ScreenMirroringView.swift`, the SwiftUI gesture is implemented as:
  ```swift
  .gesture(
      DragGesture(minimumDistance: 0)
          .onChanged { val in
              ...
              ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
          }
          .onEnded { val in
              ...
              ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
          }
  )
  ```
  Action `"down"` is never sent. On Android in `ContinuityAccessibilityService.kt`:
  ```kotlin
  when (action.lowercase()) {
      "down" -> {
          downX = pixelX
          downY = pixelY
          downTime = System.currentTimeMillis()
      }
      "move" -> {}
      "up" -> {
          val duration = (System.currentTimeMillis() - downTime).coerceIn(20L, 400L)
          val path = Path().apply {
              moveTo(downX, downY)
              lineTo(pixelX, pixelY)
          }
          val stroke = GestureDescription.StrokeDescription(path, 0, duration)
          ...
      }
  }
  ```
- **Why**:
  Because `"down"` is never received, `downX` and `downY` remain `0.0f` (or retaining the end position of an ancient stroke). When the user clicks or taps anywhere on the macOS viewer window (e.g. at `x=0.5, y=0.5`), Android executes a gesture path starting at `(0, 0)` and ending at `(540, 1200)`. This converts every simple tap into a full diagonal drag across the screen.
- **Suggestion**:
  - In `ScreenMirroringView.swift`, track gesture state:
    ```swift
    @State private var isDragging: Bool = false
    ...
    .gesture(
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                guard geo.size.width > 0 && geo.size.height > 0 else { return }
                let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
                if !isDragging {
                    isDragging = true
                    ScreenMirroringService.shared.sendInputEvent(action: "down", x: normX, y: normY, button: 0)
                } else {
                    ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
                }
            }
            .onEnded { val in
                isDragging = false
                guard geo.size.width > 0 && geo.size.height > 0 else { return }
                let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
                ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
            }
    )
    ```
  - Defensively on Android (`ContinuityAccessibilityService.kt`), if `downTime == 0L` when `"up"` arrives, initialize `downX = pixelX`, `downY = pixelY` to execute a point tap rather than a drag from `(0, 0)`.

---

### 2. [Major] Screen Mirroring Decoder Format Incompatibility (H.264 NAL vs `NSImage`)

- **Where**:
  - `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift:85-89`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ScreenMirroringService.kt:136-177`
- **What**:
  Android captures and encodes screen video using `MediaCodec.MIMETYPE_VIDEO_AVC` (H.264 Annex B NAL units) and transmits it as binary stream packet `0x01`.
  On macOS, `ScreenMirroringService.swift` handles incoming `0x01` frames via:
  ```swift
  public func handleIncomingFrame(_ frameData: Data) {
      queue.async { [weak self] in
          guard let self = self else { return }
          self.lastFrameReceivedDate = Date()
          if let image = NSImage(data: frameData) {
              Task { @MainActor in
                  DeviceState.shared.updateScreenFrame(image)
              }
          }
      }
  }
  ```
  `NSImage(data:)` relies on ImageIO/CoreGraphics and only decodes still image container formats (JPEG, PNG, TIFF, HEIC, WebP). When passed an H.264 NAL unit, `NSImage(data: frameData)` evaluates to `nil` (`Decoded image: false`).
- **Why**:
  In a real session with Android, `DeviceState.shared.lastScreenFrame` will never be populated, and `ScreenMirroringView` will remain permanently stuck displaying `"Waiting for video stream..."`.
- **Suggestion**:
  - For true H.264 playback, integrate `VideoToolbox` (`VTDecompressionSessionCreate` and `VTDecompressionSessionDecodeFrame`) to decode Annex B NAL units to `CVPixelBuffer` / `CGImage`.
  - Alternatively, if hardware decoding is deferred to a future milestone, support an MJPEG fallback encoding mode on Android (`ImageReader.newInstance(width, height, ImageFormat.JPEG, ...)`), or document the exact H.264 decompression requirements in `PROJECT.md` / `PROJECT_BACKLOG.md`.

---

### 3. [Major] `GET /api/camera/stream` Returns Single Snapshot with `Connection: close` Instead of Multipart MJPEG Stream

- **Where**:
  - `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:335-346`
- **What**:
  The HTTP endpoint handling camera streaming does:
  ```swift
  if method == "GET" && (path == "/api/camera/stream" || path == "/camera/mjpeg") {
      client.readBuffer.removeAll()
      if let jpeg = VirtualWebcamFeeder.shared.getLatestJpeg() {
          let response = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nConnection: close\r\n\r\n"
          sendRaw(client: client, data: Data(response.utf8) + jpeg)
      } else {
          let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          sendRaw(client: client, data: Data(response.utf8))
      }
      removeClient(client)
      return
  }
  ```
- **Why**:
  A valid MJPEG video feed requires `Content-Type: multipart/x-mixed-replace; boundary=frame` over a persistent HTTP connection. Sending `Content-Type: image/jpeg` with `Connection: close` and terminating the TCP connection serves a single static image snapshot. Any external virtual webcam consumer (e.g. OBS, browser `<img>`, or VLC) expecting a video stream will terminate after one frame.
- **Suggestion**:
  Either:
  1. Rename or document this endpoint as `/api/camera/snapshot` (with `/api/camera/stream` supporting streaming or polling), or
  2. Implement continuous multipart streaming by holding connected clients and broadcasting `--frame\r\nContent-Type: image/jpeg\r\n\r\n` chunks as `VirtualWebcamFeeder.feedJpeg` is invoked.

---

### 4. [Minor] Redundant Dual-Message Broadcast on Lens Switch

- **Where**:
  - `mac/Sources/GalaxyContinuityKit/Services/ContinuityCameraService.swift:39-47`
- **What**:
  `switchLens` broadcasts two distinct messages back-to-back:
  ```swift
  let msg = ContinuityMessage(type: "camera_switch_lens", lens: lens, facing: lens)
  ServerManager.shared.broadcastMessage(msg)
  let ctrl = ContinuityMessage(type: "camera_control", action: "switch_lens", lens: lens, facing: lens)
  ServerManager.shared.broadcastMessage(ctrl)
  ```
- **Why**:
  Android's `WebSocketClient.kt` listens to both `camera_switch_lens` and `camera_control`. When both messages arrive in quick succession, Android calls `startCamera(targetLens, ...)` twice, unnecessarily thrashing the Android `CameraDevice` and `CameraCaptureSession` hardware lifecycle.
- **Suggestion**:
  Broadcast only one canonical message: either `camera_control` (with `action: "switch_lens"`) or `camera_switch_lens`.

---

### 5. [Minor] Watchdog Timer Lacks Initial Grace Period for Android System Permissions Consent

- **Where**:
  - `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift:121-135`
- **What**:
  The 5000ms stalling watchdog is started immediately upon calling `startMirroring()`.
- **Why**:
  On Android, starting screen projection prompts the user with an interactive system dialog ("Galaxy Continuity will start capturing everything that's displayed on your screen"). If the user takes longer than 5 seconds to read and tap "Start now", macOS fires `stopMirroring(reason: "stream_stalled")` and terminates the session prematurely.
- **Suggestion**:
  Start the watchdog timer only after the first frame (`lastFrameReceivedDate != nil`) is received from the device, or introduce an initial 15-second grace period for the handshake/consent phase.

---

## Verified Claims

- **5-byte Binary Packet Framing (§ 4.2)**: Verified via `ScreenMirroringTests.swift`, `ContinuityCameraTests.swift`, and live server socket fuzzing → **PASS**
- **Watchdog Stalling Recovery (5000ms)**: Verified via live socket test `test_m3_adversarial.py` triggering `screen_stop` with `reason: "stream_stalled"` → **PASS**
- **ContinuityMessage Schema Harmonization (`facing`, `resolution`)**: Verified decoding and computed properties `effectiveLens`, `effectiveQuality` → **PASS**
- **VirtualWebcamFeeder Buffer Concurrency**: Verified thread-safe JPEG ingestion and retrieval under `NSLock` → **PASS**
- **Live HTTP Endpoint `/api/camera/stream`**: Verified 503 response when empty, 200 with raw JPEG when populated → **PASS**
- **E2E & Unit Test Suites**: Verified 54 Swift tests, 8 adversarial WS tests, 122 E2E tests, 5 live server tests → **PASS**

## Coverage Gaps

- **H.264 Video Decoding Pipeline on macOS**: Risk Level: **HIGH** — Recommendation: **Implement VideoToolbox decompressor or add JPEG fallback**
- **Touch Gesture Down Event Dispatch**: Risk Level: **HIGH** — Recommendation: **Add touch down tracking in ScreenMirroringView**
- **Live Android MediaProjection on Physical Device**: Risk Level: **MEDIUM** — Recommendation: **Verify with real Android device once APK is packaged**

## Unverified Items

- **Physical System-wide CMIO Extension**: Cannot verify on headless macOS runner without root-installed DAL plugin in `/Library/CoreMediaIO/Plug-Ins/DAL/`.

---

## 1. Observation

Direct observations from independent test execution, source inspection, and live server testing:

### 1.1 Verbatim Command Outputs

#### 1. macOS Swift Package Build (`swift build`)
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift build
```
```
[0/1] Planning build
Building for debugging...
[0/4] Write swift-version--1AB21518FC5DEDBE.txt
[2/16] Compiling GalaxyContinuityKit ContinuityMessage.swift
[3/16] Compiling GalaxyContinuityKit DeviceState.swift
[4/16] Emitting module GalaxyContinuityKit
[5/16] Compiling GalaxyContinuityKit ScreenMirroringService.swift
[6/16] Compiling GalaxyContinuityKit ServerManager.swift
[7/16] Compiling GalaxyContinuityKit WebSocketFramer.swift
[8/16] Compiling GalaxyContinuityKit BonjourService.swift
[9/16] Compiling GalaxyContinuityKit ClipboardSyncService.swift
[10/16] Compiling GalaxyContinuityKit ContinuityCameraService.swift
[11/16] Compiling GalaxyContinuityKit VirtualWebcamFeeder.swift
[12/16] Compiling GalaxyContinuityKit NotificationService.swift
[13/16] Compiling GalaxyContinuityKit QuickDropService.swift
[14/17] Compiling GalaxyContinuityKit WebAssets.swift
[15/25] Compiling GalaxyContinuity CameraPreviewView.swift
[16/25] Compiling GalaxyContinuity AppDelegate.swift
[17/25] Compiling GalaxyContinuity App.swift
[18/25] Emitting module GalaxyContinuity
[19/25] Compiling GalaxyContinuity MenuBarView.swift
[20/25] Compiling GalaxyContinuity QuickDropView.swift
[21/25] Compiling GalaxyContinuity ScreenMirroringView.swift
[22/25] Compiling GalaxyContinuity DevicePairingView.swift
[22/24] Linking GalaxyContinuity
[23/24] Applying GalaxyContinuity
Build complete! (2.32s)
```
Exit code: `0`.

#### 2. macOS Swift Test Suite
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
```
✔ Suite "WebSocket Framer Tests" passed after 0.003 seconds.
✔ Suite "Screen Mirroring Parity Tests" passed after 0.003 seconds.
✔ Suite "Continuity Camera Parity Tests" passed after 0.003 seconds.
✔ Suite "Handshake Tests" passed after 0.003 seconds.
✔ Suite "File Upload Path Traversal Sanitization Tests" passed after 0.003 seconds.
✔ Suite "ContinuityMessage Schema Harmonization Tests" passed after 0.003 seconds.
✔ Suite "WebSocket Fragmentation Reassembly Tests" passed after 0.003 seconds.
✔ Suite "Quick Drop File Transfer Parity Tests" passed after 0.004 seconds.
✔ Suite "Quick Drop Adversarial Stress Tests" passed after 0.005 seconds.
✔ Suite "Universal Clipboard Parity Tests" passed after 0.009 seconds.
✔ Test run with 54 tests in 10 suites passed after 0.009 seconds.
```
Exit code: `0`.

#### 3. Adversarial WebSocket Protocol Test Suite
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity && python3 tests/test_adversarial_protocol.py
```
```
test_boundary_lengths_over_socket (__main__.TestAdversarialWebSocketFraming) ... ok
test_fragmented_frame_reconstruction (__main__.TestAdversarialWebSocketFraming) ... ok
test_interleaved_control_frame_during_fragmentation (__main__.TestAdversarialWebSocketFraming) ... ok
test_malformed_non_utf8_in_text_frame (__main__.TestAdversarialWebSocketFraming) ... ok
test_malformed_rsv_bits_set (__main__.TestAdversarialWebSocketFraming) ... ok
test_malformed_unassigned_opcode (__main__.TestAdversarialWebSocketFraming) ... ok
test_masking_with_random_and_cyclic_keys (__main__.TestAdversarialWebSocketFraming) ... ok
test_unmasked_client_frame_tolerance (__main__.TestAdversarialWebSocketFraming) ... ok

----------------------------------------------------------------------
Ran 8 tests in 1.155s

OK
```
Exit code: `0`.

#### 4. Master E2E Test Suite (Tiers 1–4)
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity && python3 tests/e2e/runner.py
```
```
==============================================================================
 GALAXY CONTINUITY — E2E TEST EXECUTION SUMMARY
==============================================================================
Tier     Description                                Count   Pass   Fail   Time    
------------------------------------------------------------------------------
1        Tier 1: Category-Partition Equivalenc...   52      52     0      1.46s    ✅
2        Tier 2: Boundary Value Analysis & Neg...   52      52     0      1.89s    ✅
3        Tier 3: Pairwise & Cross-Feature Inte...   12      12     0      0.71s    ✅
4        Tier 4: End-to-End Real-World User Wo...   6       6      0      1.07s    ✅
------------------------------------------------------------------------------
TOTAL    All Tiers Combined                         122     122    0      5.13s   
==============================================================================
🎉 ALL TESTS PASSED! Continuous integration ready.
```
Exit code: `0`.

#### 5. Live Server Adversarial Test Suite (`test_m3_adversarial.py`)
```bash
python3 /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/reviewer_m3_1/test_m3_adversarial.py
```
```
============================================================
Milestone 3 Live Server Adversarial Test Suite
============================================================
Running: Screen Lifecycle ... PASS
Running: Camera Lifecycle ... PASS
Running: Camera Stream & Endpoint ... PASS
Running: Screen Frame Delivery ... PASS
Running: Malformed Binary Packets ... PASS
Running: Remote Input Boundaries ... PASS
Running: Watchdog Stall (5000ms) ... PASS
============================================================
Summary: 7/7 passed
```
Exit code: `0`.

#### 6. Swift H.264 NAL Decompression Check on `NSImage(data:)`
```bash
swift -e 'import AppKit; let nal = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]); let img = NSImage(data: nal); print("Decoded image:", img != nil)'
```
```
Decoded image: false
```
Exit code: `0`.

---

## 2. Logic Chain

1. **Protocol Compliance & Framing Alignment**:
   - `shared/PROTOCOL.md § 4.2` specifies the 5-byte header: `[StreamType: 1B][Length: 4B BE][Payload]`.
   - `ScreenMirroringService.makeStreamPacket` and `parseStreamPacket` correctly format and unpack this layout.
   - Live socket fuzzing confirms that truncated frames (< 5 bytes) and oversized declared lengths are discarded gracefully without crashing `ServerManager`.
2. **Gesture Protocol Disconnect**:
   - In `ScreenMirroringView.swift`, `DragGesture` invokes only `.onChanged` (sending `"move"`) and `.onEnded` (sending `"up"`).
   - In `ContinuityAccessibilityService.kt`, gestures are constructed by moving from `(downX, downY)` recorded during a `"down"` action.
   - Because `"down"` is never sent by `ScreenMirroringView`, `downX` and `downY` are never set for user taps, causing Android to construct a stroke from `(0, 0)` on every click.
3. **Codec Asymmetry**:
   - Android's `ScreenMirroringService.kt` initializes a hardware H.264 video encoder via `MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)`.
   - macOS's `ScreenMirroringService.swift` expects `NSImage(data: frameData)` to decode incoming frames.
   - Direct execution in Swift confirms `NSImage(data:)` returns `nil` for H.264 NAL units.
   - Thus, while mock test packets pass serialization roundtrips, real video frames from Android cannot be rendered on macOS without `VideoToolbox` decompression or a JPEG fallback.
4. **Endpoint Semantics**:
   - `GET /api/camera/stream` is documented in `handoff.md` and `PROJECT.md` as an MJPEG stream for OBS/virtual camera use.
   - In `ServerManager.swift`, the handler returns a single JPEG with `Content-Type: image/jpeg` and `Connection: close`, making it a snapshot endpoint rather than a streaming feed.

---

## 3. Caveats

- **No physical Galaxy hardware connected**: Testing was conducted using live mock socket clients, adversarial fuzzers, and the active macOS menu bar server process (`PID 11775`).
- **macOS CMIO DAL Plugin scope**: As noted in the worker handoff, full FaceTime virtual camera integration requires a root-signed CMIO DAL plugin in `/Library/CoreMediaIO/Plug-Ins/DAL/`, which is intentionally out of scope for an unprivileged app bundle.

---

## 4. Conclusion

The Milestone 3 implementation by `worker_m3` establishes the necessary architectural foundation: control message schemas, 5-byte binary packet multiplexing, watchdog recovery, and menu bar UI controllers. No integrity violations or dishonest shortcuts were detected.

However, because the touch gesture integration drops the `"down"` event and the screen viewer assumes `NSImage` can decode H.264 NAL frames, the feature cannot function correctly in live cross-platform usage.

Verdict: **REQUEST_CHANGES** to address Finding 1 (Critical) and Finding 2 (Major).

---

## 5. Verification Method

To independently reproduce all observations and verify the findings:

1. **Verify Test Suites Pass Cleanly**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift build
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   python3 /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/test_adversarial_protocol.py
   python3 /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/e2e/runner.py
   ```

2. **Verify M3 Live Server Adversarial Suite**:
   ```bash
   python3 /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/reviewer_m3_1/test_m3_adversarial.py
   ```

3. **Verify H.264 Incompatibility with `NSImage`**:
   ```bash
   swift -e 'import AppKit; let nal = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]); let img = NSImage(data: nal); print("Decoded image:", img != nil)'
   ```
   *Expected output*: `Decoded image: false`.

4. **Inspect Missing `"down"` Action in `ScreenMirroringView.swift`**:
   ```bash
   grep -n "sendInputEvent" /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift
   ```
   *Expected output*: Only `action: "move"` and `action: "up"` exist; `"down"` is never called.
