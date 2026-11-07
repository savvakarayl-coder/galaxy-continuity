# Empirical Adversarial Challenge Report: WebSocket Framing & Protocol (M1)

**Agent**: `challenger_m1_1` (`teamwork_challenger`)  
**Parent Agent**: Orchestrator (`67ae80cb-3237-4127-adab-613c0f12f1aa`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m1_1`  
**Milestone**: M1 (Architecture & Test Harness Enablement)  
**Date**: 2026-11-07  
**Verdict**: **`REQUEST_CHANGES`**  

---

## 1. Challenge Summary

- **Overall Risk Assessment**: **HIGH**
- **Explicit Verdict**: **`REQUEST_CHANGES`**
- **Key Findings**:
  1. **Lack of WebSocket Fragmented Frame Reassembly & Continuation Frame (Opcode `0x0`) Handling**: Both the macOS production server (`ServerManager.swift`) and the mock E2E server (`harness.py`) lack a fragment accumulation buffer. Fragmented client messages (e.g., large clipboard data or video control split across TCP frames) fail reassembly and are dropped.
  2. **Automated E2E Test Suite Failure & Race Condition**: Running `python3 tests/e2e/runner.py` produced a test failure in Tier 3 (`test_03_pairwise_screen_mirroring_and_notification_interactive_reply`), contradicting the claim in `TEST_READY.md` of 100% test pass.
  3. **Headless Execution Crash in macOS Host (`NotificationService.swift`)**: Invoking the macOS server binary directly outside an `.app` bundle results in an uncaught `NSInternalInconsistencyException` (`bundleProxyForCurrentProcess is nil`) on client connection due to unconditional `UNUserNotificationCenter` access.
  4. **Low-Level Framing Robustness Confirmed**: `WebSocketFramer.swift` correctly implements RFC 6455 7-bit, 16-bit, and 64-bit frame lengths, masking/unmasking, cyclic mask patterns, and GUID accept key computation (295/295 tests passed).

---

## 2. Observation

### Observation 1: Swift Test Suite Execution
Running the Swift test suite:
```bash
cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```
Output:
```text
Building for debugging...
Build complete! (0.15s)
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite "WebSocket Framer Tests" started.
◇ Suite "Handshake Tests" started.
...
✔ Suite "Handshake Tests" passed after 0.001 seconds.
✔ Suite "WebSocket Framer Tests" passed after 0.001 seconds.
✔ Test run with 10 tests in 2 suites passed after 0.001 seconds.
```
Exit code: `0`.

### Observation 2: E2E Runner Failure in Tier 3
Running the full Python E2E suite:
```bash
python3 tests/e2e/runner.py
```
Output:
```text
▶ Running [Tier 3: Pairwise & Cross-Feature Interaction Integration Tests]...
..F.........
======================================================================
FAIL: test_03_pairwise_screen_mirroring_and_notification_interactive_reply (tests.e2e.test_tier3_pairwise.TestTier3Pairwise)
Active screen mirroring stream while notification arrives and receives interactive quick reply.
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/e2e/test_tier3_pairwise.py", line 162, in test_03_pairwise_screen_mirroring_and_notification_interactive_reply
    self.assertTrue(len(self.server.received_binary_frames) > 0)
AssertionError: False is not true
----------------------------------------------------------------------
Ran 12 tests in 0.696s
FAILED (failures=1)
...
==============================================================================
 GALAXY CONTINUITY — E2E TEST EXECUTION SUMMARY
==============================================================================
Tier     Description                                Count   Pass   Fail   Time    
------------------------------------------------------------------------------
1        Tier 1: Category-Partition Equivalenc...   52      52     0      1.55s    ✅
2        Tier 2: Boundary Value Analysis & Neg...   52      52     0      1.88s    ✅
3        Tier 3: Pairwise & Cross-Feature Inte...   12      11     1      0.70s    ❌
4        Tier 4: End-to-End Real-World User Wo...   6       6      0      1.08s    ✅
------------------------------------------------------------------------------
TOTAL    All Tiers Combined                         122     121    1      5.21s   
==============================================================================
❌ 1 TEST(S) FAILED. Inspect logs above for details.
```
Exit code: `1`.

### Observation 3: Incomplete RFC 6455 Fragment Handling in Server Code
Inspection of `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:376-398`:
```swift
private func processWebSocketData(_ client: ConnectedClient) {
    while let frame = WebSocketFramer.decodeFrame(from: &client.readBuffer) {
        handleWebSocketFrame(client: client, opcode: frame.opcode, payload: frame.payload)
    }
}

private func handleWebSocketFrame(client: ConnectedClient, opcode: UInt8, payload: Data) {
    switch opcode {
    case 0x1: // Text frame
        if let string = String(data: payload, encoding: .utf8),
           let jsonData = string.data(using: .utf8),
           let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData) {
            handleIncomingMessage(client: client, message: message)
        }
    case 0x8: // Close
        removeClient(client)
    case 0x9: // Ping -> Pong
        sendFrame(client: client, opcode: 0xA, payload: payload)
    default:
        break
    }
}
```
- `handleWebSocketFrame` ignores `frame.fin`.
- Continuation frames (`opcode 0x0`) fall into `default: break` and are silently dropped.
- Partial text frames (`fin == false`) immediately attempt `JSONDecoder().decode` and fail.
- Similarly, in `tests/e2e/harness.py:80-126`, `decode_ws_frame` discards the `fin` bit and `MockContinuityServer` does not handle `opcode == 0x0`.

### Observation 4: Empirical Reproduction of Fragmentation Failure
Created and executed `tests/test_adversarial_protocol.py` (live TCP socket test suite):
```bash
python3 tests/test_adversarial_protocol.py
```
Output:
```text
======================================================================
FAIL: test_fragmented_frame_reconstruction (__main__.TestAdversarialWebSocketFraming)
RFC 6455 § 5.4: Fragmented frames (opcode 0x1 fin=0, continuation opcode 0x0 fin=1).
----------------------------------------------------------------------
AssertionError: None != 'FragmentedReconstructionSuccess' : Server MUST reassemble fragmented WebSocket frames (opcode 0x1 + continuation 0x0)

======================================================================
FAIL: test_interleaved_control_frame_during_fragmentation (__main__.TestAdversarialWebSocketFraming)
RFC 6455 § 5.4: Ping/Pong control frames interleaved during fragmented message.
----------------------------------------------------------------------
AssertionError: None != 'InterleavedPingPongTest' : Server MUST reassemble message even when control frame is interleaved
----------------------------------------------------------------------
Ran 8 tests in 1.155s
FAILED (failures=2)
```

### Observation 5: Headless Server Crash on Handshake Notification
Launching the raw compiled executable `mac/.build/arm64-apple-macosx/debug/GalaxyContinuity` and initiating a WebSocket handshake produced a fatal SIGABRT:
```text
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL file:///Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac/.build/arm64-apple-macosx/debug/'
*** First throw call stack:
(
    0   CoreFoundation                      __exceptionPreprocess + 176
    1   libobjc.A.dylib                     objc_exception_throw + 88
    2   Foundation                          -[NSCalendarDate initWithCoder:] + 0
    3   UserNotifications                   __53+[UNUserNotificationCenter currentNotificationCenter]_block_invoke.cold.2 + 104
    4   UserNotifications                   __53+[UNUserNotificationCenter currentNotificationCenter]_block_invoke + 472
    ...
    8   GalaxyContinuity                    $s19GalaxyContinuityKit19NotificationServiceC5setup33_473487A7EBED7B3C32BF3A9419E8DE05LLyyF + 52
    9   GalaxyContinuity                    $s19GalaxyContinuityKit19NotificationServiceCACyc33_473487A7EBED7B3C32BF3A9419E8DE05Llfc + 96
    ...
    16  GalaxyContinuity                    ServerManager.handleIncomingMessage(...)
)
libc++abi: terminating due to uncaught exception of type NSException
💣 Program crashed: Signal 6: Aborted
```

### Observation 6: Exhaustive Framer Algorithm Verification
Created and executed `tests/adversarial_ws_framer.swift` linking `GalaxyContinuityKit.build/WebSocketFramer.swift.o`:
```bash
swiftc -I mac/.build/arm64-apple-macosx/debug/Modules mac/.build/arm64-apple-macosx/debug/GalaxyContinuityKit.build/WebSocketFramer.swift.o tests/adversarial_ws_framer.swift -o tests/adversarial_ws_framer_bin && ./tests/adversarial_ws_framer_bin
```
Output:
```text
=================================================================
RUNNING ADVERSARIAL WEBSOCKET FRAMER TESTS (SWIFT)
=================================================================
--- 1. Boundary Length Verification ---
--- 2. Masking & Cyclic Patterns ---
--- 3. Truncated Buffers & Streaming Decoding ---
--- 4. Sec-WebSocket-Accept Tests ---
--- 5. Fragmented Frame Flag Handling ---
=================================================================
SWIFT FRAMER TEST RESULTS: 295 Passed, 0 Failed
=================================================================
```

---

## 3. Logic Chain

1. **Test Suite Claim vs Reality**:
   - `TEST_READY.md` lines 4-6 declared: "Status: TEST READY (100% PASS), Total Tests: 122, Passed: 122, Failed: 0".
   - Direct execution in Observation 2 demonstrated exit code `1` with 1 failure in Tier 3 (`test_03_pairwise_screen_mirroring_and_notification_interactive_reply`).
   - Tracing `test_tier3_pairwise.py:137-162` revealed that the assertion `len(self.server.received_binary_frames) > 0` directly after `client.expect_message("notification_reply")` suffers from a race condition: the client sending binary frame and the server receiving thread are decoupled; when client receives the reply broadcast, the server thread has not necessarily executed `sock.recv()` for the preceding binary packet.
   - An automated test suite with intermittent failures cannot be approved for CI readiness.

2. **Protocol Standard Violation (RFC 6455 § 5.4)**:
   - RFC 6455 Section 5.4 mandates support for fragmented messages across continuation frames (opcode `0x0`) and interleaved control frames (ping/pong, opcode `0x9`/`0xA`).
   - Observations 3 and 4 prove that neither `ServerManager.swift` nor `MockContinuityServer` reassembles fragmented messages.
   - Any client network stack that fragments large frames (such as base64 images or large file announcements) will have its messages silently dropped by the macOS server.

3. **Daemon/CLI Reliability Failure**:
   - Observation 5 demonstrated that connecting to a standalone server instance crashes the process due to `UNUserNotificationCenter.current()`.
   - While `scripts/build_app.sh` bundles the binary into an `.app` bundle where a bundle proxy exists, running headless unit tests, integration tests, or developer CLI binaries immediately terminates with SIGABRT upon client handshake.

4. **Verdict Deduction**:
   - Because automated tests fail and the WebSocket protocol implementation does not satisfy RFC 6455 fragmentation reassembly, the verdict must be `REQUEST_CHANGES`.

---

## 4. Challenges

### [Critical] Challenge 1: Absence of WebSocket Frame Reassembly Buffering
- **Assumption challenged**: The WebSocket layer can handle fragmented payloads and streaming data from clients.
- **Attack scenario**: A client fragments a message into two frames (`fin=false, opcode=0x1`, followed by `fin=true, opcode=0x0`), or a network buffer delivers a fragmented control frame.
- **Blast radius**: Silent message loss for any payload exceeding TCP buffer chunking, desynchronizing device pairing and clipboard exchange.
- **Mitigation**:
  1. In `ServerManager.swift`, add a per-client `messageBuffer: Data` and `currentOpcode: UInt8?`.
  2. When a frame with `fin == false` arrives, store its opcode and accumulate payload in `messageBuffer`.
  3. When a continuation frame (`opcode == 0x0`) arrives, append payload. When `fin == true`, dispatch accumulated payload.
  4. Allow control frames (`opcode >= 0x8`) to process immediately without disturbing `messageBuffer`.
  5. Apply equivalent fix to `MockContinuityServer` in `tests/e2e/harness.py`.

### [High] Challenge 2: Test Harness Race Condition in E2E Pairwise Tier 3
- **Assumption challenged**: `python3 tests/e2e/runner.py` is hermetic and 100% passing.
- **Attack scenario**: High system load or thread scheduling variance delays the server thread's `sock.recv()` for a binary stream packet while `client.expect_message()` returns quickly.
- **Blast radius**: Flaky CI builds, false alarms in release pipelines.
- **Mitigation**: In `test_tier3_pairwise.py:160-163`, poll with a brief timeout (e.g. `deadline = time.time() + 1.0`) while checking `len(self.server.received_binary_frames) > 0`, rather than asserting instantaneously.

### [Medium] Challenge 3: Unconditional `UNUserNotificationCenter` Crashing Headless Binaries
- **Assumption challenged**: The macOS server can run in test environments, CLI harnesses, and headless CI.
- **Attack scenario**: Running `GalaxyContinuity` executable directly via `swift run` or command-line and connecting a device.
- **Blast radius**: Immediate process crash (`NSInternalInconsistencyException`) on `handshake`.
- **Mitigation**: In `NotificationService.swift`, check `Bundle.main.bundleIdentifier != nil` before initializing `UNUserNotificationCenter.current()`. If `nil`, fallback to terminal logging or suppress user notifications.

---

## 5. Stress Test Results

| Test ID / Target | Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|:---:|
| **SW-01** (`WebSocketFramer`) | Boundary lengths: 125, 126, 65535, 65536 bytes | Correct 7-bit, 16-bit, 64-bit length encoding | Correct length headers & roundtrip decoding | **PASS** |
| **SW-02** (`WebSocketFramer`) | Random & cyclic mask keys (0x00, 0xFF, alternating) | Exact recovery of masked payload bytes | 100% bitwise parity on unmasking | **PASS** |
| **SW-03** (`WebSocketFramer`) | Truncated frame buffer slices (0..<N bytes) | Returns `nil` without mutating buffer until complete | Correct incremental feeding behavior | **PASS** |
| **SW-04** (`WebSocketFramer`) | RFC 6455 Sec-WebSocket-Accept test vectors & whitespace | Exact base64 SHA-1 computation | `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` matches RFC | **PASS** |
| **NET-01** (Live Socket) | Boundary payload lengths (125, 126, 65535, 65536) | Message received & parsed by server | Message parsed cleanly | **PASS** |
| **NET-02** (Live Socket) | Cyclic & random masking keys over TCP | Payload unmasked accurately | Unmasked payload matches | **PASS** |
| **NET-03** (Live Socket) | Unmasked client frame tolerance (PROTOCOL.md § 6.2) | Server reads unmasked payload gracefully | Server accepts frame without error | **PASS** |
| **NET-04** (Live Socket) | Malformed opcodes (0x3, 0x7, 0xB, 0xF) & RSV bits | Discarded gracefully without crash | Discarded; server stays responsive | **PASS** |
| **NET-05** (Live Socket) | Fragmented frame reassembly (`opcode 0x1 fin=0` + `0x0 fin=1`) | Server reassembles chunks into full message | Payload dropped; `opcode 0x0` ignored | **FAIL** |
| **NET-06** (Live Socket) | Interleaved Ping during fragmented frame transmission | Pong replied; reassembly preserved | Pong sent, but message lost | **FAIL** |
| **E2E-01** (Test Runner) | `python3 tests/e2e/runner.py` full suite execution | All 122 tests pass cleanly | 121 passed, 1 failed (`test_03_pairwise`) | **FAIL** |
| **CLI-01** (Native App) | Direct headless binary execution + client connection | Server processes handshake gracefully | `NSInternalInconsistencyException` crash | **FAIL** |

---

## 6. Caveats

1. **Android JVM Unit Tests on Host**: As noted by `worker_m1`, the local host environment lacks a system Java runtime (`Unable to locate a Java Runtime`). Android tests in `android/app/src/test/` could not be executed locally on this macOS host; verification relies on the synthetic Python harness and headless CI workflows.
2. **App Bundle Execution**: Running the macOS app via its full bundle (`mac/build/Galaxy Continuity.app/Contents/MacOS/Galaxy Continuity`) does not encounter the `UserNotifications` crash, as the bundle proxy is present. The crash only affects standalone/headless invocations.

---

## 7. Conclusion

**Verdict: `REQUEST_CHANGES`**

While low-level WebSocket framing algorithms in `WebSocketFramer.swift` are mathematically and structurally sound, changes are required before Milestone M1 can be certified:
1. **Fix WebSocket Fragment Reassembly**: Add message reassembly and continuation frame handling (opcode `0x0`) in `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift` and `tests/e2e/harness.py`.
2. **Fix Flaky E2E Test**: Update `test_03_pairwise_screen_mirroring_and_notification_interactive_reply` in `tests/e2e/test_tier3_pairwise.py` to eliminate the asynchronous race condition when verifying received binary frames.
3. **Guard `NotificationService` for Headless/Test Execution**: Wrap `UNUserNotificationCenter` in a check for bundle presence so standalone binary execution and testing do not crash with SIGABRT.

---

## 8. Verification Method

To independently reproduce and verify all findings:

1. **Reproduce E2E Test Runner Failure**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/e2e/runner.py
   # Observe failure in Tier 3 test_03_pairwise_screen_mirroring_and_notification_interactive_reply
   ```

2. **Reproduce WebSocket Fragmentation & Interleaving Failures**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/test_adversarial_protocol.py
   # Observe 2 failures: test_fragmented_frame_reconstruction and test_interleaved_control_frame_during_fragmentation
   ```

3. **Verify Swift Low-Level Framer Tests**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   swiftc -I mac/.build/arm64-apple-macosx/debug/Modules mac/.build/arm64-apple-macosx/debug/GalaxyContinuityKit.build/WebSocketFramer.swift.o tests/adversarial_ws_framer.swift -o tests/adversarial_ws_framer_bin && ./tests/adversarial_ws_framer_bin && rm -f tests/adversarial_ws_framer_bin
   # Observe 295 Passed, 0 Failed
   ```

4. **Reproduce Headless Binary Crash**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac/.build/arm64-apple-macosx/debug/GalaxyContinuity &
   PID=$!
   sleep 1
   python3 tests/test_native_mac_adversarial.py
   kill $PID
   # Observe crash log with NSInternalInconsistencyException
   ```
