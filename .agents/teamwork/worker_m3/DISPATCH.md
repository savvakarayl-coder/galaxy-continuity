# Task Assignment: Milestone 3 Worker (Screen Mirroring & Continuity Camera Implementation)

## Identity
- Role: teamwork_worker
- Assigned Working Directory: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3
- Project Root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
- Original Request File: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
- Scope Document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
- Protocol Specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md
- macOS Explorer Blueprint: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_explorer_1/handoff.md
- Android Explorer Blueprint: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_explorer_2/handoff.md
- Spec Miner Report: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_spec_miner_3/handoff.md

## Objective
Implement full Screen Mirroring and Continuity Camera feature parity across macOS and Android per the authoritative Explorer blueprints:

### 1. macOS Implementation (`mac/`)
1. In `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`:
   - Add schema properties & aliases: `facing` (alias for `lens`), `resolution` (alias for `quality`).
2. In `mac/Sources/GalaxyContinuityKit/Models/DeviceState.swift`:
   - Add `@Published` properties for screen mirroring (`isScreenMirroringActive`, resolution, fps, bitrate, `lastScreenFrame`) and camera (`isCameraActive`, lens, quality, zoom, torch, `lastCameraFrame`).
3. In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`:
   - Implement `handleIncomingBinaryFrame`: parse 5-byte header (`[StreamType 1B][Length 4B BE][Payload]`), reject packets < 5 bytes safely, accept 0-byte payload safely, route `0x01` to `ScreenMirroringService` and `0x02` to `ContinuityCameraService`.
   - Implement control message handlers: `screen_start`, `screen_stop`, `input_event`, `input_key`, `camera_start`, `camera_stop`, `camera_switch_lens`, `camera_control`.
   - Add `broadcastBinary(data:)` to transmit binary media frames.
   - Implement `GET /api/camera/stream` MJPEG HTTP endpoint.
4. Implement Services in `mac/Sources/GalaxyContinuityKit/Services/`:
   - `ScreenMirroringService.swift`: Manage mirroring lifecycle, frame reception, input dispatching with coordinate normalization (`0.0..1.0`), and 5000ms stalling watchdog.
   - `ContinuityCameraService.swift`: Manage camera lifecycle, lens switching, zoom/torch control, and frame reception.
   - `VirtualWebcamFeeder.swift`: Ring buffer of frames and MJPEG stream feed.
5. Implement UI in `mac/Sources/GalaxyContinuity/UI/`:
   - `ScreenMirroringView.swift` & `ScreenMirroringWindowController.swift`: Viewer window displaying screen stream, capturing mouse gestures, and navigation buttons.
   - `CameraPreviewView.swift` & `CameraPreviewWindowController.swift`: Live camera preview with lens selector, zoom slider, torch toggle.
   - Update `MenuBarView.swift`: Add controls to launch screen mirroring and continuity camera.
6. Add Unit Tests in `mac/Tests/GalaxyContinuityTests/`:
   - `ScreenMirroringTests.swift`: packet framing, serialization, coordinate clamping, key mapping.
   - `ContinuityCameraTests.swift`: packet framing, lens switching, camera control.

### 2. Android Implementation (`android/`)
1. In `android/app/src/main/AndroidManifest.xml`:
   - Add permissions: `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `FOREGROUND_SERVICE_CAMERA`, `CAMERA`, `<uses-feature android:name="android.hardware.camera" android:required="false" />`.
   - Declare services: `ScreenMirroringService`, `ContinuityCameraService`, `ContinuityAccessibilityService`.
2. Create `android/app/src/main/res/xml/accessibility_service_config.xml`.
3. In `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`:
   - Extend `ContinuityListener` with screen & camera callbacks.
   - Dispatch incoming `screen_start`, `screen_stop`, `input_event`, `input_key`, `camera_start`, `camera_stop`, `camera_control`, `camera_switch_lens`.
   - Add `sendBinaryFrame(streamType: Byte, payload: ByteArray)` with 5-byte header.
4. Implement Android Services:
   - `ScreenMirroringService.kt`: MediaProjection capture, video frame packetization (type `0x01`), WebSocket sending.
   - `ContinuityCameraService.kt`: Camera2 capture, lens switching, zoom/torch, JPEG frame packetization (type `0x02`), WebSocket sending.
   - `ContinuityAccessibilityService.kt`: Touch gesture injection via `dispatchGesture` and key navigation (`GLOBAL_ACTION_BACK`, `GLOBAL_ACTION_HOME`, `GLOBAL_ACTION_RECENTS`).
5. Add Android Unit Tests in `android/app/src/test/java/com/galaxycontinuity/app/`:
   - `ScreenMirroringUnitTest.kt` and `ContinuityCameraUnitTest.kt`: directly test production methods (packet construction/parsing, coordinate clamping, keycode translation) with zero facade methods.

## Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Verification Commands to Execute
1. `cd mac && swift build`
2. `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
3. `python3 tests/test_adversarial_protocol.py`
4. `python3 tests/test_adversarial_quickdrop.py`
5. `python3 tests/e2e/runner.py`

## Completion Requirements
Write a complete, self-contained `handoff.md` in your assigned directory following the Handoff Protocol (Observation, Logic Chain, Caveats, Conclusion, Verification Method). Include verbatim command execution outputs.
Send completion message to orchestrator upon delivery.


## 2026-11-07T14:24:29Z
[Message] timestamp=2026-11-07T14:24:29Z sender=edb875f9-c921-490b-8f47-2beeb22c6414 priority=MESSAGE_PRIORITY_HIGH content=You are worker_m3.
Your working directory is: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3
Project root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
Original request file: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
Dispatch instructions: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3/DISPATCH.md
Scope document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
Protocol specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md
macOS Explorer Blueprint: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_explorer_1/handoff.md
Android Explorer Blueprint: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_explorer_2/handoff.md
Spec Miner Report: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_spec_miner_3/handoff.md
