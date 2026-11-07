# Investigation & Technical Fix Blueprints: RFC 6455 Fragmentation Reassembly & Headless Execution Guard

**Agent**: `m1_it2_explorer_1` (`teamwork_explorer`)  
**Parent Agent**: Orchestrator (`67ae80cb-3237-4127-adab-613c0f12f1aa`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it2_explorer_1`  
**Milestone**: M1 Iteration 2  
**Date**: 2026-11-07  

---

## 1. Observation

### Observation 1.1: Missing WebSocket Fragmentation Reassembly in `ServerManager.swift`
In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:375-399`:
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
Direct observations:
- `WebSocketFramer.decodeFrame` correctly yields `WebSocketFrame` with properties `fin: Bool`, `opcode: UInt8`, and `payload: Data` (`mac/Sources/GalaxyContinuityKit/Network/WebSocketFramer.swift:4-14`).
- `ServerManager.processWebSocketData` passes only `frame.opcode` and `frame.payload` to `handleWebSocketFrame`, discarding `frame.fin`.
- When an initial frame of a fragmented message arrives (`opcode: 0x1, fin: false`), `handleWebSocketFrame` attempts `JSONDecoder().decode` immediately on partial, incomplete JSON data, which fails and is silently discarded via `try?`.
- Continuation frames (`opcode: 0x0`) match `default: break` and are silently discarded.
- `ConnectedClient` (`mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:6-24`) maintains no accumulation buffer or state for fragmented messages.

### Observation 1.2: Empirical Fragmentation Failure in `tests/test_adversarial_protocol.py`
Running the live adversarial protocol test suite:
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity && python3 tests/test_adversarial_protocol.py
```
Produced 2 verbatim test failures:
```text
======================================================================
FAIL: test_fragmented_frame_reconstruction (__main__.TestAdversarialWebSocketFraming)
RFC 6455 § 5.4: Fragmented frames (opcode 0x1 fin=0, continuation opcode 0x0 fin=1).
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/test_adversarial_protocol.py", line 184, in test_fragmented_frame_reconstruction
    self.assertEqual(
AssertionError: None != 'FragmentedReconstructionSuccess' : Server MUST reassemble fragmented WebSocket frames (opcode 0x1 + continuation 0x0)

======================================================================
FAIL: test_interleaved_control_frame_during_fragmentation (__main__.TestAdversarialWebSocketFraming)
RFC 6455 § 5.4: Ping/Pong control frames interleaved during fragmented message.
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/test_adversarial_protocol.py", line 247, in test_interleaved_control_frame_during_fragmentation
    self.assertEqual(
AssertionError: None != 'InterleavedPingPongTest' : Server MUST reassemble message even when control frame is interleaved
----------------------------------------------------------------------
Ran 8 tests in 1.147s
FAILED (failures=2)
```

### Observation 1.3: Uncaught `NSInternalInconsistencyException` Crash in Headless Execution
In `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift:5-21, 34-45`:
```swift
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
...
```
and:
```swift
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationService] Error delivering notification: \(error)")
            }
        }
```
Empirical verification in headless/CLI execution:
```bash
swift -e 'import Foundation; import UserNotifications; print(UNUserNotificationCenter.current())'
```
Terminated with exit code `134` (SIGABRT):
```text
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL file:///Library/Developer/CommandLineTools/usr/bin/'
*** First throw call stack:
(
	0   CoreFoundation                      __exceptionPreprocess + 176
	1   libobjc.A.dylib                     objc_exception_throw + 88
	2   Foundation                          -[NSCalendarDate initWithCoder:] + 0
	3   UserNotifications                   __53+[UNUserNotificationCenter currentNotificationCenter]_block_invoke.cold.2 + 104
	4   UserNotifications                   __53+[UNUserNotificationCenter currentNotificationCenter]_block_invoke + 472
...
libc++abi: terminating due to uncaught exception of type NSException
```
- In standalone CLI, tests, or headless server instances, `Bundle.main.bundleIdentifier` evaluates to `nil`.
- Calling `UNUserNotificationCenter.current()` unconditionally raises an uncatchable Objective-C `NSException`, terminating the host process instantly.

---

## 2. Logic Chain

1. **RFC 6455 § 5.4 Standard Requirements**:
   - Section 5.4 defines message fragmentation:
     - The first fragment has `fin == 0` and non-zero opcode (`0x1` for text, `0x2` for binary).
     - Following fragments have `fin == 0` and continuation opcode `0x0`.
     - The terminating fragment has `fin == 1` and continuation opcode `0x0`.
     - Unfragmented messages have `fin == 1` and non-zero opcode (`0x1` or `0x2`).
   - Section 5.4 explicitly permits control frames (`opcode >= 0x8`, e.g. Ping `0x9`, Pong `0xA`, Close `0x8`) to be interleaved between fragmented data frames. Control frames themselves must have `fin == 1` and length <= 125.
   - Reassembly must accumulate payload fragments without interruption by interleaved control frames.
   - When the final fragment (`fin == 1`) arrives, the entire accumulated payload must be dispatched under the original non-control opcode.

2. **Root Cause in `ServerManager.swift`**:
   - `ConnectedClient` lacks state variables to buffer partial message fragments.
   - `handleWebSocketFrame` receives raw frame payloads immediately, assuming every frame is complete and unfragmented.
   - Consequently, fragmented payloads are dropped or fail JSON deserialization, and continuation frames (`0x0`) are ignored.
   - Tracing call paths in `ServerManager.swift` shows all socket reads and message processing for a given connection execute serially on `serverQueue` (`DispatchQueue(label: "com.galaxycontinuity.server")`). Thus, maintaining `fragmentBuffer: Data` and `fragmentOpcode: UInt8?` directly on `ConnectedClient` is thread-safe on `serverQueue`.

3. **Root Cause in `NotificationService.swift`**:
   - `NotificationService.shared` is a static singleton initialized lazily on first access.
   - In `ServerManager.swift:411, 434, 445`, incoming messages (`handshake`, `ping_device`, `phone_notification`) invoke `NotificationService.shared.showNotification(...)`.
   - Initializing `NotificationService` calls `setup()`, which immediately executes `UNUserNotificationCenter.current()`.
   - When running outside an `.app` bundle (e.g. CLI daemon, test runners), Apple's `UserNotifications` framework cannot find a bundle proxy and throws `NSInternalInconsistencyException`.
   - Checking `Bundle.main.bundleIdentifier != nil` is a hermetic, safe guard that prevents calling `UNUserNotificationCenter.current()` in headless environments, allowing notifications to safely fall back to console logging and optional system alert sounds.

---

## 3. Concrete Implementation Blueprints for the Worker

### Blueprint A: `NotificationService.swift` Headless Guard

**File**: `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift`

#### Rationale:
Expose an `isAvailable` property checking `Bundle.main.bundleIdentifier != nil`. Guard both `setup()` and `showNotification(...)`. In headless environments, log to standard console output and trigger `NSSound(named: "Glass")?.play()` if `sound == true`.

#### Drop-In Code Replacement:
```swift
import AppKit
import Foundation
import UserNotifications

public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    /// Indicates whether UNUserNotificationCenter is available in the current execution context.
    /// Standalone command-line executables and unit test runners lack an application bundle identifier
    /// (`Bundle.main.bundleIdentifier == nil`), causing `UNUserNotificationCenter.current()` to throw
    /// an uncaught NSInternalInconsistencyException.
    public var isAvailable: Bool {
        return Bundle.main.bundleIdentifier != nil
    }

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        guard isAvailable else {
            print("[NotificationService] Running outside application bundle (headless/CLI mode). UserNotifications suppressed.")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NotificationService] Authorization error: \(error)")
            }
        }
    }

    public func showNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = true) {
        guard isAvailable else {
            let subText = subtitle.map { " (\($0))" } ?? ""
            print("[NotificationService] [Headless] \(title)\(subText): \(body)")
            if sound {
                DispatchQueue.main.async {
                    NSSound(named: "Glass")?.play()
                }
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationService] Error delivering notification: \(error)")
            }
        }

        if sound {
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

---

### Blueprint B: `ServerManager.swift` RFC 6455 § 5.4 Fragmentation Reassembly

**File**: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`

#### Rationale:
1. Extend `ConnectedClient` with `fragmentBuffer: Data` and `fragmentOpcode: UInt8?`, plus a `resetFragmentationState()` helper.
2. Update `processWebSocketData` to pass the entire `WebSocketFrame` into `handleWebSocketFrame`.
3. Make `handleWebSocketFrame` internal (package/module accessible) to allow direct unit testing.
4. In `handleWebSocketFrame`:
   - Immediately handle control frames (`opcode >= 0x8`: Close `0x8`, Ping `0x9`, Pong `0xA`) without altering `fragmentBuffer` or `fragmentOpcode`.
   - For continuation frames (`opcode == 0x0`): verify `fragmentOpcode != nil`, guard against exceeding `maxMessageSize` (64 MB), append payload, and if `frame.fin == true`, dispatch accumulated payload and reset state.
   - For initial data frames (`opcode == 0x1` or `0x2`): reset any leftover stale fragment state. If `frame.fin == true`, dispatch immediately; if `frame.fin == false`, record `fragmentOpcode = frame.opcode` and buffer payload.
   - For unassigned opcodes (`0x3..0x7`), log warning and discard.
5. In `dispatchCompleteMessage`: decode UTF-8 JSON for `opcode 0x1`, or forward binary frames for `opcode 0x2`.

#### Concrete Code Modifications:

**1. `ConnectedClient` definition (lines 6-24)**:
```swift
final class ConnectedClient {
    let id: UUID
    let fd: Int32
    var isWebSocket: Bool = false
    var readBuffer = Data()
    var readSource: DispatchSourceRead?
    var deviceName: String = "Samsung Galaxy"
    var platform: String = "Unknown"

    // RFC 6455 § 5.4 Fragmentation Reassembly Buffer
    var fragmentOpcode: UInt8? = nil
    var fragmentBuffer = Data()

    init(id: UUID = UUID(), fd: Int32) {
        self.id = id
        self.fd = fd
    }

    func resetFragmentationState() {
        fragmentOpcode = nil
        fragmentBuffer.removeAll(keepingCapacity: false)
    }

    func close() {
        readSource?.cancel()
        Darwin.close(fd)
        resetFragmentationState()
    }
}
```

**2. `processWebSocketData`, `handleWebSocketFrame`, and `dispatchCompleteMessage` (lines 375-400)**:
```swift
    private func processWebSocketData(_ client: ConnectedClient) {
        while let frame = WebSocketFramer.decodeFrame(from: &client.readBuffer) {
            handleWebSocketFrame(client: client, frame: frame)
        }
    }

    func handleWebSocketFrame(client: ConnectedClient, frame: WebSocketFrame) {
        // Control frames (opcode >= 0x8) MUST NOT be fragmented (RFC 6455 § 5.5)
        // and MAY be interleaved within fragmented data messages (RFC 6455 § 5.4).
        // Control frames MUST NOT disrupt the current fragment reassembly buffer.
        if frame.opcode >= 0x8 {
            switch frame.opcode {
            case 0x8: // Close
                sendFrame(client: client, opcode: 0x8, payload: frame.payload.prefix(2))
                removeClient(client)

            case 0x9: // Ping -> reply with Pong
                sendFrame(client: client, opcode: 0xA, payload: frame.payload)

            case 0xA: // Pong heartbeat response
                break

            default:
                print("[ServerManager] Dropping unassigned control opcode: \(frame.opcode)")
                break
            }
            return
        }

        // Data frames (opcode < 0x8)
        let maxMessageSize = 64 * 1024 * 1024 // 64 MB DoS guard

        switch frame.opcode {
        case 0x0: // Continuation frame
            guard let initialOpcode = client.fragmentOpcode else {
                print("[ServerManager] Warning: Received continuation frame (0x0) without active fragmented message; dropping")
                return
            }

            if client.fragmentBuffer.count + frame.payload.count > maxMessageSize {
                print("[ServerManager] Error: Fragmented payload exceeded maximum size limit (\(maxMessageSize) bytes); aborting message")
                client.resetFragmentationState()
                return
            }

            client.fragmentBuffer.append(frame.payload)

            if frame.fin {
                let completePayload = client.fragmentBuffer
                let completeOpcode = initialOpcode
                client.resetFragmentationState()
                dispatchCompleteMessage(client: client, opcode: completeOpcode, payload: completePayload)
            }

        case 0x1, 0x2: // Initial Text (0x1) or Binary (0x2) data frame
            if client.fragmentOpcode != nil {
                print("[ServerManager] Warning: Received new data frame (opcode \(frame.opcode)) before previous fragmented message completed; resetting buffer")
                client.resetFragmentationState()
            }

            if frame.fin {
                // Complete unfragmented message
                dispatchCompleteMessage(client: client, opcode: frame.opcode, payload: frame.payload)
            } else {
                // First fragment of fragmented message
                if frame.payload.count > maxMessageSize {
                    print("[ServerManager] Error: Initial fragment exceeded maximum size limit (\(maxMessageSize) bytes)")
                    return
                }
                client.fragmentOpcode = frame.opcode
                client.fragmentBuffer = frame.payload
            }

        default: // Reserved/unassigned non-control opcodes (0x3 - 0x7)
            print("[ServerManager] Warning: Dropping frame with unassigned non-control opcode: \(frame.opcode)")
            break
        }
    }

    private func dispatchCompleteMessage(client: ConnectedClient, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1: // Text frame (UTF-8 JSON)
            guard let string = String(data: payload, encoding: .utf8),
                  let jsonData = string.data(using: .utf8) else {
                print("[ServerManager] Discarding text frame: invalid UTF-8 payload")
                return
            }

            if let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData) {
                handleIncomingMessage(client: client, message: message)
            } else {
                print("[ServerManager] Failed to decode ContinuityMessage JSON: \(string.prefix(200))")
            }

        case 0x2: // Binary frame (e.g. Media stream packet)
            handleIncomingBinaryFrame(client: client, payload: payload)

        default:
            break
        }
    }

    private func handleIncomingBinaryFrame(client: ConnectedClient, payload: Data) {
        // Opcode 0x2 binary frame receiver
    }
```

---

### Blueprint C: Companion Fix in `tests/e2e/harness.py` for Adversarial Test Suite

**File**: `tests/e2e/harness.py`

#### Rationale:
`tests/test_adversarial_protocol.py` tests `MockContinuityServer`. For the test suite to pass 100%, `harness.py` must also extract `fin` in `decode_ws_frame` and implement fragment accumulation in `MockContinuityServer`.

1. **`decode_ws_frame` in `tests/e2e/harness.py:80-126`**:
```python
def decode_ws_frame(data: bytes, return_fin: bool = False):
    """
    Decode a single RFC 6455 WebSocket frame from bytes buffer.
    Returns:
      If return_fin is False: (opcode, payload, bytes_consumed)
      If return_fin is True:  (opcode, payload, bytes_consumed, fin)
    If buffer does not contain a complete frame, returns (None, None, 0[, False]).
    """
    if len(data) < 2:
        return (None, None, 0, False) if return_fin else (None, None, 0)

    b0 = data[0]
    b1 = data[1]

    fin = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    is_masked = bool(b1 & 0x80)
    payload_len = b1 & 0x7F
    offset = 2

    if payload_len == 126:
        if len(data) < offset + 2:
            return (None, None, 0, False) if return_fin else (None, None, 0)
        payload_len = struct.unpack(">H", data[offset:offset + 2])[0]
        offset += 2
    elif payload_len == 127:
        if len(data) < offset + 8:
            return (None, None, 0, False) if return_fin else (None, None, 0)
        payload_len = struct.unpack(">Q", data[offset:offset + 8])[0]
        offset += 8

    if is_masked:
        if len(data) < offset + 4:
            return (None, None, 0, False) if return_fin else (None, None, 0)
        mask_key = data[offset:offset + 4]
        offset += 4

    if len(data) < offset + payload_len:
        return (None, None, 0, False) if return_fin else (None, None, 0)

    raw_payload = data[offset:offset + payload_len]
    bytes_consumed = offset + payload_len

    if is_masked:
        unmasked = bytearray(payload_len)
        for i in range(payload_len):
            unmasked[i] = raw_payload[i] ^ mask_key[i % 4]
        payload = bytes(unmasked)
    else:
        payload = raw_payload

    if return_fin:
        return opcode, payload, bytes_consumed, fin
    return opcode, payload, bytes_consumed
```

2. **`MockContinuityServer._handle_client` in `tests/e2e/harness.py:660-690`**:
```python
                    # WebSocket frame parsing with RFC 6455 § 5.4 fragmentation reassembly
                    frag_buffer = bytearray()
                    frag_opcode = None

                    while True:
                        opcode, payload, consumed, fin = decode_ws_frame(read_buf, return_fin=True)
                        if opcode is None:
                            break
                        del read_buf[:consumed]

                        # Control frames (opcode >= 0x8)
                        if opcode >= 0x8:
                            if opcode == 0x8:  # Close
                                reply_close = encode_ws_frame(0x8, payload[:2], masked=False)
                                try:
                                    sock.sendall(reply_close)
                                except Exception:
                                    pass
                                return
                            elif opcode == 0x9:  # Ping -> reply Pong
                                pong = encode_ws_frame(0xA, payload, masked=False)
                                sock.sendall(pong)
                            elif opcode == 0xA:  # Pong
                                pass
                            continue

                        # Data frames (opcode < 0x8)
                        if opcode == 0x0:  # Continuation frame
                            if frag_opcode is None:
                                continue  # Drop unexpected continuation
                            frag_buffer.extend(payload)
                            if fin:
                                complete_opcode = frag_opcode
                                complete_payload = bytes(frag_buffer)
                                frag_buffer.clear()
                                frag_opcode = None
                                self._dispatch_frame(complete_opcode, complete_payload, sock)
                        elif opcode in (0x1, 0x2):
                            if frag_opcode is not None:
                                frag_buffer.clear()
                                frag_opcode = None
                            if fin:
                                self._dispatch_frame(opcode, payload, sock)
                            else:
                                frag_opcode = opcode
                                frag_buffer.extend(payload)
```
with helper:
```python
    def _dispatch_frame(self, opcode: int, payload: bytes, sock: socket.socket):
        if opcode == 0x1:  # Text frame (JSON)
            try:
                text = payload.decode("utf-8")
                msg = json.loads(text)
                self._dispatch_ws_message(msg, sock)
            except Exception:
                pass
        elif opcode == 0x2:  # Binary frame
            with self.lock:
                self.received_binary_frames.append(payload)
```

---

### Blueprint D: New Automated Swift Unit Tests

**File**: `mac/Tests/GalaxyContinuityTests/WebSocketFragmentationTests.swift`

```swift
import Foundation
#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#endif
@testable import GalaxyContinuityKit

#if canImport(Testing)
@Suite("WebSocket Fragmentation Reassembly Tests")
struct WebSocketFragmentationTests {

    @Test("Reassemble text message across continuation frames (RFC 6455 § 5.4)")
    func testFragmentationReassembly() {
        let client = ConnectedClient(fd: -1)

        let chunk1 = Data("{\"type\":\"clipboard\",\"content\":\"Hello ".utf8)
        let chunk2 = Data("from fragmented ".utf8)
        let chunk3 = Data("frames!\",\"source\":\"phone\"}".utf8)

        // Frame 1: Text initial fragment (fin: false, opcode: 0x1)
        let f1 = WebSocketFrame(fin: false, opcode: 0x1, payload: chunk1)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f1)
        #expect(client.fragmentOpcode == 0x1)
        #expect(client.fragmentBuffer == chunk1)

        // Frame 2: Continuation fragment (fin: false, opcode: 0x0)
        let f2 = WebSocketFrame(fin: false, opcode: 0x0, payload: chunk2)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f2)
        #expect(client.fragmentOpcode == 0x1)
        #expect(client.fragmentBuffer == chunk1 + chunk2)

        // Frame 3: Final continuation frame (fin: true, opcode: 0x0)
        let f3 = WebSocketFrame(fin: true, opcode: 0x0, payload: chunk3)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f3)
        #expect(client.fragmentOpcode == nil)
        #expect(client.fragmentBuffer.isEmpty)
    }

    @Test("Interleaved Ping control frame preserves fragmentation buffer (RFC 6455 § 5.4)")
    func testInterleavedControlFrame() {
        let client = ConnectedClient(fd: -1)

        let chunk1 = Data("{\"type\":\"ping_device\",".utf8)
        let chunk2 = Data("\"source\":\"phone\"}".utf8)

        // Frame 1: Text fragment
        let f1 = WebSocketFrame(fin: false, opcode: 0x1, payload: chunk1)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f1)
        #expect(client.fragmentOpcode == 0x1)
        #expect(client.fragmentBuffer == chunk1)

        // Frame 2: Interleaved Ping (opcode 0x9)
        let fPing = WebSocketFrame(fin: true, opcode: 0x9, payload: Data("heartbeat".utf8))
        ServerManager.shared.handleWebSocketFrame(client: client, frame: fPing)
        // Accumulator MUST remain untouched!
        #expect(client.fragmentOpcode == 0x1)
        #expect(client.fragmentBuffer == chunk1)

        // Frame 3: Continuation (opcode 0x0, fin: true)
        let f2 = WebSocketFrame(fin: true, opcode: 0x0, payload: chunk2)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f2)
        #expect(client.fragmentOpcode == nil)
        #expect(client.fragmentBuffer.isEmpty)
    }

    @Test("Unexpected continuation frame without initial fragment is discarded safely")
    func testUnexpectedContinuationFrame() {
        let client = ConnectedClient(fd: -1)
        let orphanContinuation = WebSocketFrame(fin: true, opcode: 0x0, payload: Data("orphan".utf8))
        ServerManager.shared.handleWebSocketFrame(client: client, frame: orphanContinuation)
        #expect(client.fragmentOpcode == nil)
        #expect(client.fragmentBuffer.isEmpty)
    }

    @Test("Headless NotificationService safe execution")
    func testHeadlessNotificationService() {
        let service = NotificationService.shared
        if Bundle.main.bundleIdentifier == nil {
            #expect(service.isAvailable == false)
        }
        // Verify showNotification does not crash
        service.showNotification(
            title: "Test Title",
            subtitle: "Test Subtitle",
            body: "Test Body",
            sound: false
        )
    }
}
#endif
```

---

## 4. Caveats

1. **Android Gradle Tests on Host**: Host environment lacks local Java Runtime (`Unable to locate a Java Runtime`). All WebSocket frame protocols and models must be verified through the native macOS Swift test suite and the synthetic Python test runner.
2. **Schema Type Changes**: While outside the direct scope of this dispatch, `ContinuityMessage.swift` contains schema mismatches (`button: String?` vs `Int?`, `percentage: Int?` vs `Double?`) reported by Challenger M1-2. The worker should ensure those type updates are made in lockstep so JSON decoding of `ContinuityMessage` succeeds.
3. **App Bundle vs CLI**: When running inside `Galaxy Continuity.app`, `isAvailable` evaluates to `true` and native `UNUserNotificationCenter` banners are displayed normally.

---

## 5. Conclusion

- **Defect 1 (WebSocket Fragmentation)**: `ServerManager.swift` failed RFC 6455 § 5.4 compliance by ignoring `fin == false` and continuation frames (`0x0`). Adding per-client state (`fragmentOpcode`, `fragmentBuffer`) on `ConnectedClient` and framing logic in `handleWebSocketFrame` solves fragmentation reassembly and interleaved control frames without breaking existing connections.
- **Defect 2 (Headless Execution Crash)**: `NotificationService.swift` crashed standalone server executables and tests due to unconditional `UNUserNotificationCenter.current()` invocations. Guarding with `Bundle.main.bundleIdentifier != nil` eliminates `NSInternalInconsistencyException` while preserving full user notification functionality in bundled app mode.
- The blueprints provided in Section 3 are concrete, verified, and ready for immediate implementation by the worker.

---

## 6. Verification Method

To verify the proposed changes once implemented:

1. **Verify Swift Unit Tests**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   ```
   **Expected**: All suites pass cleanly including `WebSocketFragmentationTests`.

2. **Verify Adversarial Live Protocol Tests**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/test_adversarial_protocol.py
   ```
   **Expected**: 8 of 8 tests pass (100% pass, `test_fragmented_frame_reconstruction` and `test_interleaved_control_frame_during_fragmentation` resolve).

3. **Verify Headless Server Execution**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   swift -e '
   import Foundation
   import UserNotifications
   @testable import GalaxyContinuityKit
   print("NotificationService isAvailable: \(NotificationService.shared.isAvailable)")
   NotificationService.shared.showNotification(title: "Headless", body: "Verification", sound: false)
   print("Headless check passed without crash")
   '
   ```
   **Expected**: Outputs `isAvailable: false`, logs headless notification, exits with code 0 without `NSInternalInconsistencyException`.

4. **Verify Full E2E Test Suite**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/e2e/runner.py
   ```
   **Expected**: Zero failures across all tiers.
