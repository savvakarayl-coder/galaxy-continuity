# Dispatch: Worker M1 Iteration 2 (Implementation of Challenger & Explorer Fixes)

You are `worker_m1_it2` (`teamwork_worker`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1_it2`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it2_explorer_1/handoff.md` (Blueprint for fragmentation reassembly & headless notification guard)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it2_explorer_2/handoff.md` (Blueprint for ContinuityMessage schema types & file upload sanitization)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it2_explorer_3/handoff.md` (Blueprint for test harness 5-byte media header & test race condition fix)

## Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Write Ownership Boundaries
- `mac/Sources/**`, `mac/Tests/**`
- `tests/e2e/harness.py`, `tests/e2e/test_tier3_pairwise.py` (and test call sites if needed)
- `.agents/teamwork/worker_m1_it2/**`

## Assigned Implementation Tasks

### 1. WebSocket Fragmentation Reassembly in `ServerManager.swift`
Follow `m1_it2_explorer_1/handoff.md § 3.1`:
- In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`:
  - Add `public var fragmentBuffer = Data()` and `public var fragmentOpcode: UInt8? = nil` to `ConnectedClient`.
  - In `processWebSocketData`: pass `frame.fin`, `frame.opcode`, and `frame.payload` to `handleWebSocketFrame`.
  - In `handleWebSocketFrame`:
    - Handle control frames (opcodes `0x8`, `0x9`, `0xA`) immediately without disrupting fragment buffering.
    - If `frame.fin == false`: buffer `payload` in `client.fragmentBuffer` and record `client.fragmentOpcode` if not already set. Prevent memory denial-of-service by guarding `client.fragmentBuffer.count <= 64 * 1024 * 1024`.
    - If `frame.fin == true`: if `client.fragmentOpcode != nil`, append payload, dispatch assembled message using `client.fragmentOpcode!`, and reset buffer/opcode. If not fragmented, dispatch directly.
    - Support continuation frames (`opcode == 0x0`).

### 2. Headless Bundle Guard in `NotificationService.swift`
Follow `m1_it2_explorer_1/handoff.md § 3.2`:
- In `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift`:
  - Guard against `NSInternalInconsistencyException` when running outside an `.app` bundle:
    Check `Bundle.main.bundleIdentifier != nil`. If nil, set `isAvailable = false`, skip `UNUserNotificationCenter.current()`, and print a log message instead of crashing.
  - In `postNotification`: if not available, print to console/log gracefully.

### 3. Schema Type Harmonization in `ContinuityMessage.swift`
Follow `m1_it2_explorer_2/handoff.md § 3.1`:
- In `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`:
  - Change `public var button: String?` to `public var button: Int?`.
  - Change `public var percentage: Int?` to `public var percentage: Double?`.
  - Update `ContinuityMessage.init` parameters and assignments.
  - Ensure all call sites in `mac/Sources/` compile cleanly.

### 4. File Upload Path Traversal Sanitization in `ServerManager.swift`
Follow `m1_it2_explorer_2/handoff.md § 3.2`:
- In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`:
  - Add `sanitizeUploadFilename(_ raw: String) -> String` to sanitize `rawFilename`: extract terminal component, strip `..`, `/`, `\`, disallow empty and dot prefixes (`.` or `..`), and verify `targetUrl.deletingLastPathComponent().standardized.path == destDir.standardized.path`.

### 5. Add New Swift Unit Tests
Follow `m1_it2_explorer_1` and `m1_it2_explorer_2`:
- Add `mac/Tests/GalaxyContinuityTests/ContinuityMessageTests.swift` (testing numeric button decoding, Double percentage decoding, JSON serialization).
- Add `mac/Tests/GalaxyContinuityTests/FileUploadSanitizationTests.swift` (testing path traversal rejection, dot-prefix cleaning).
- Add `mac/Tests/GalaxyContinuityTests/WebSocketFragmentationTests.swift` (testing fragmented frame buffering and continuation).

### 6. E2E Harness Media Header Alignment & Race Fix
Follow `m1_it2_explorer_3/handoff.md § 4.1 & 4.2`:
- In `tests/e2e/harness.py`:
  - Update `make_stream_packet` and `parse_stream_packet` to support the 5-byte header `[StreamType: 1 byte][PayloadLength: 4 bytes BE uint32][Payload]` per `shared/PROTOCOL.md § 4.2`.
  - Add WebSocket continuation frame (`opcode 0x0`) and FIN bit handling in `MockContinuityServer` and `decode_ws_frame`.
- In `tests/e2e/test_tier3_pairwise.py`:
  - In `test_03_pairwise_screen_mirroring_and_notification_interactive_reply`, replace the immediate assertion `self.assertTrue(len(self.server.received_binary_frames) > 0)` with a polling loop (up to 1.0s timeout) to eliminate the asynchronous socket race condition.

### 7. Verification
- Run `cd mac && swift build`
- Run `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- Run `python3 tests/e2e/runner.py` (verify 122/122 tests pass across all 4 tiers)
- Run `python3 tests/test_adversarial_protocol.py` (verify all tests pass)
- Document all changes and verification outputs in `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1_it2/handoff.md` and notify parent via `send_message`.
