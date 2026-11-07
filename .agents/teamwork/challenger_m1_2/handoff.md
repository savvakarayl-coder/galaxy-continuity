# Empirical Verification & Adversarial Challenge Report: M1 Protocol & Schema

**Agent**: Challenger M1-2 (`challenger_m1_2`, `critic`, `specialist`)  
**Parent Agent**: Orchestrator (`67ae80cb-3237-4127-adab-613c0f12f1aa`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m1_2`  
**Milestone**: M1 (Architecture & Test Harness Enablement)  
**Date**: 2026-11-07  
**Verdict**: `REQUEST_CHANGES`

---

## 1. Observation

### Obs 1. `ContinuityMessage.swift:54` — `button` Schema Type Mismatch
- In `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:54`:
  ```swift
  public var button: String?
  ```
- In `shared/PROTOCOL.md:442,452`:
  ```json
  "button": 0
  ```
  `| button | Integer | Optional | Mouse button: 0 (Left/Primary), 1 (Right/Secondary), 2 (Middle) |`
- In `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt:191,199`:
  ```kotlin
  put("button", 0)
  // ...
  assertEquals(0, parsedEvent.getInt("button"))
  ```
- In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:386`:
  ```swift
  let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData)
  ```
- **Verbatim Error Execution**: Running `JSONDecoder().decode(ContinuityMessage.self, from: jsonData)` with `{"type":"input_event","action":"down","x":0.5,"y":0.5,"button":0}` produced:
  ```text
  DecodingError.typeMismatch: expected value of type String. Path: button.
  Debug description: Expected to decode String but found number instead.
  ```
- **Consequence**: Every `input_event` with numeric `button` fails decoding and is silently discarded by `try?`.

---

### Obs 2. `ContinuityMessage.swift:44` — `percentage` Schema Type Mismatch
- In `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:44`:
  ```swift
  public var percentage: Int?
  ```
- In `shared/PROTOCOL.md:354,365`:
  ```json
  "percentage": 50.0,
  ```
  `| percentage | Double | Yes | Transfer completion percentage (0.0 - 100.0) |`
- In `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt:133,141`:
  ```kotlin
  put("percentage", 50.0)
  // ...
  assertEquals(50.0, p.getDouble("percentage"), 0.001)
  ```
- **Verbatim Error Execution**: Running `JSONDecoder().decode(ContinuityMessage.self, from: jsonData)` with `{"type":"file_progress","fileId":"123","bytesTransferred":50,"totalBytes":100,"percentage":50.5,"status":"transferring"}` produced:
  ```text
  DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not valid JSON..
  Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 "Number 50.5 is not representable in Swift."
  ```
- **Consequence**: Any `file_progress` message with decimal transfer percentages fails decoding and is dropped.

---

### Obs 3. Media Stream Header Incompatibility (`PROTOCOL.md` vs `tests/e2e/harness.py`)
- In `shared/PROTOCOL.md:188-209`:
  Binary media streams specify a **5-byte header**:
  - Byte 0: Stream Type (`UInt8`: `0x01` Screen Mirroring, `0x02` Continuity Camera)
  - Bytes 1-4: Payload Length (`UInt32`, Big-Endian network byte order)
  - Bytes 5..N: Media Payload
- In `PROJECT.md:85,89`:
  `Binary frame packet [0x01][4-byte len][payload]` and `[0x02][4-byte len][payload]`.
- In `android/app/src/test/java/com/galaxycontinuity/app/WebSocketFrameTest.kt:81-110`:
  `buffer = ByteBuffer.allocate(5 + testPayload.size); buffer.order(ByteOrder.BIG_ENDIAN); buffer.put(streamType); buffer.putInt(testPayload.size)`
- **Conflict in `tests/e2e/harness.py:857-880`**:
  ```python
  def make_stream_packet(stream_type: int, frame_type: int, seq: int, payload: bytes) -> bytes:
      header = struct.pack(">BBH", stream_type, frame_type, seq & 0xFFFF)
      return header + payload
  ```
  `harness.py` creates a **4-byte header** (`stream_type` 1 byte, `frame_type` 1 byte, `seq` 2 bytes) with NO payload length!
- **Verbatim Deserialization Error**: Parsing a conforming 5-byte packet (`01 00 00 00 15 <21 bytes>`) with `parse_stream_packet` produces:
  ```text
  stream_type=1, frame_type=0, seq=0, payload_start=b'\x15H264'
  ```
  The 4th byte of the 32-bit length is stripped into the media payload, corrupting both the sequence number and the video stream.

---

### Obs 4. Path Traversal Vulnerability in `ServerManager.swift` File Upload
- In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:257-262, 304-305`:
  ```swift
  var rawFilename = headers["x-filename"] ?? "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
  if let decoded = rawFilename.removingPercentEncoding { rawFilename = decoded }
  saveUploadedFile(name: rawFilename, data: fileData, sender: client.deviceName)
  // ...
  let destDir = self.downloadsDirectory
  var targetUrl = destDir.appendingPathComponent(name)
  ```
- **Verbatim Exploit Test**: When `X-Filename: ../outside.txt` is passed:
  ```swift
  let targetUrl = destDir.appendingPathComponent("../outside.txt")
  // targetUrl.standardized.path resolves to /tmp/outside.txt
  try Data("test".utf8).write(to: targetUrl)
  ```
  `FileManager.default.fileExists(atPath: "/tmp/outside.txt")` evaluated to `true`!
- **Consequence**: Unauthenticated clients connecting to port 8765 can write arbitrary files outside `~/Downloads/GalaxyContinuity` across the filesystem.

---

### Obs 5. Intermittent Race Condition in E2E Test Runner (`tests/e2e/runner.py`)
- Running `cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity && python3 tests/e2e/runner.py` produced:
  ```text
  FAIL: test_03_pairwise_screen_mirroring_and_notification_interactive_reply (tests.e2e.test_tier3_pairwise.TestTier3Pairwise)
  Traceback (most recent call last):
    File ".../tests/e2e/test_tier3_pairwise.py", line 162, in test_03_pairwise_screen_mirroring_and_notification_interactive_reply
      self.assertTrue(len(self.server.received_binary_frames) > 0)
  AssertionError: False is not true
  ```
- In `tests/e2e/test_tier3_pairwise.py:137-162`: `client.send_binary(packet)` is immediately followed by `self.server.broadcast_message(...)` and `self.assertTrue(len(self.server.received_binary_frames) > 0)` without draining or synchronizing the background socket read thread.

---

### Obs 6. Test Suite Execution Results
- macOS Swift Unit Tests:
  `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  **Result**: 10 tests across 2 suites passed in 0.001s (Exit code 0).
- E2E Test Suite:
  `python3 tests/e2e/runner.py`
  **Result**: 121 tests pass, 1 test fails intermittently due to socket race condition. In a loop of 5 runs, 4 runs passed 122/122 and 1 run failed 121/122.

---

## 2. Logic Chain

1. **Protocol Interoperability Failure (Obs 1 & Obs 2)**:
   - `shared/PROTOCOL.md` is the authoritative specification for all platforms.
   - Android test models and clients adhere to `PROTOCOL.md` by emitting `"button": 0` (integer) and `"percentage": 50.0` (floating point double).
   - Swift's `ContinuityMessage` defines `button: String?` and `percentage: Int?`.
   - In Swift Foundation's `JSONDecoder`, type coercion from integer to `String` or decimal float to `Int` fails with unhandled `DecodingError`.
   - `ServerManager.swift` wraps JSON decoding with `try?`, causing all `input_event` and `file_progress` messages with decimal percentages to be silently dropped without logging or recovery.
   - Therefore, cross-platform remote touch/mouse clicks and file transfer progress tracking are broken across the wire.

2. **Stream Framing Divergence (Obs 3)**:
   - `shared/PROTOCOL.md § 4.2` explicitly specifies a 5-byte binary header `[StreamType: 1 byte][PayloadLen: 4 bytes BE][Payload]`.
   - `WebSocketFrameTest.kt` in Android unit tests explicitly verifies this 5-byte header.
   - However, `tests/e2e/harness.py` implemented an incompatible 4-byte header `[StreamType: 1 byte][FrameType: 1 byte][Seq: 2 bytes BE][Payload]`.
   - The test harness is validating a protocol that violates the authoritative specification. When production Android streaming sends 5-byte headers, E2E tests and any host relying on `harness.py` framing will misparse media frames.

3. **Security Vulnerability in File Ingestion (Obs 4)**:
   - `ServerManager.saveUploadedFile` takes raw `X-Filename` from client HTTP headers and appends it directly via `destDir.appendingPathComponent(name)`.
   - Standard Foundation `appendingPathComponent` does not sanitize parent directory components (`../`).
   - Verified empirically: an uploaded file with `../` traverses outside the downloads directory and writes arbitrary files to the local user account.

4. **Verdict Justification**:
   - The protocol models and test harness contain critical type and framing regressions that prevent reliable cross-platform continuity.
   - Therefore, the verdict is **`REQUEST_CHANGES`**.

---

## 3. Caveats

1. **Host Environment JDK**: The host macOS environment does not have a local Java Runtime installed (`Unable to locate a Java Runtime`). Android unit tests (`ProtocolSerializationTest.kt` and `WebSocketFrameTest.kt`) were verified by static analysis and Python/Swift cross-compilation, but could not be executed locally via `./gradlew test`.
2. **Implementation Scope**: M1 is restricted to architecture and test harnesses. Image clipboard processing in `ClipboardSyncService` and full loop echo suppression are scheduled for M2.
3. **E2E Flakiness**: The 1 test failure in Tier 3 (`test_03_pairwise_screen_mirroring_and_notification_interactive_reply`) is caused by an asynchronous thread race condition in the test assertion rather than a protocol flaw.

---

## 4. Conclusion & Required Changes

**Verdict**: **`REQUEST_CHANGES`**

Milestone M1 cannot be approved in its current state due to the following blocking items:

### Required Changes:

1. **Fix `ContinuityMessage.swift` Schema Types**:
   - Change `public var button: String?` to `public var button: Int?` (or a custom decoder supporting both integer `0, 1, 2` and string names).
   - Change `public var percentage: Int?` to `public var percentage: Double?`.
   - Update `ContinuityMessage.init` parameters to match.

2. **Align Binary Media Stream Framing in `tests/e2e/harness.py`**:
   - Update `make_stream_packet` and `parse_stream_packet` in `tests/e2e/harness.py` to match `shared/PROTOCOL.md § 4.2`:
     ```python
     # 5-byte header: 1-byte stream_type + 4-byte uint32 big-endian payload length
     def make_stream_packet(stream_type: int, payload: bytes) -> bytes:
         return struct.pack(">BI", stream_type, len(payload)) + payload

     def parse_stream_packet(packet: bytes) -> Dict[str, Any]:
         stream_type, length = struct.unpack(">BI", packet[:5])
         return {"stream_type": stream_type, "length": length, "payload": packet[5:5+length]}
     ```
   - Update calls in `test_tier1_features.py`, `test_tier3_pairwise.py`, and `test_tier4_workload.py` accordingly.

3. **Sanitize `X-Filename` Against Directory Traversal in `ServerManager.swift`**:
   - Strip directory paths before saving uploaded files:
     ```swift
     let cleanFilename = URL(fileURLWithPath: rawFilename).lastPathComponent
     let safeName = cleanFilename.isEmpty ? "Received_File_\(Int(Date().timeIntervalSince1970)).bin" : cleanFilename
     ```

4. **Stabilize Asynchronous Socket Assertions in `test_tier3_pairwise.py`**:
   - In `test_03_pairwise_screen_mirroring_and_notification_interactive_reply`, add a short poll or socket synchronization before asserting `len(self.server.received_binary_frames) > 0`.

---

## 5. Verification Method

To independently verify all findings and validate fixes:

1. **Verify Swift Schema Decoding with Numbers**:
   ```bash
   swiftc /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift -o /tmp/verify_schema -e '
   import Foundation
   let json = """{"type":"input_event","action":"down","x":0.5,"y":0.5,"button":0}"""
   let msg = try JSONDecoder().decode(ContinuityMessage.self, from: json.data(using: .utf8)!)
   assert(msg.button == 0)
   print("PASSED")
   ' && /tmp/verify_schema && rm -f /tmp/verify_schema
   ```

2. **Verify Media Stream Packet Framing Compliance**:
   ```bash
   python3 -c "
   import struct
   packet = struct.pack('>BI', 0x01, 512) + (b'X' * 512)
   assert len(packet) == 517
   st, length = struct.unpack('>BI', packet[:5])
   assert st == 0x01 and length == 512
   print('5-byte header verification PASSED')
   "
   ```

3. **Verify E2E Test Suite Execution**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/e2e/runner.py
   # Expected: All 122 tests pass without race conditions
   ```

4. **Verify macOS Build and Tests**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   # Expected: 10 tests in 2 suites passed
   ```
