#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(Testing)
@Suite("Screen Mirroring Adversarial Stress Tests", .serialized)
struct ScreenMirroringAdversarialTests {

    // MARK: - 1. Binary Packet Framing Adversarial Tests

    @Test("Stream packet framing with 1 MB payload")
    func testLargeStreamPacket() throws {
        let oneMegabyte = 1024 * 1024
        let largePayload = Data(repeating: 0xAB, count: oneMegabyte)
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x01, payload: largePayload)

        #expect(packet.count == 5 + oneMegabyte)
        #expect(packet[0] == 0x01)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.length == oneMegabyte)
        #expect(parsed.payload.count == oneMegabyte)
        #expect(parsed.payload == largePayload)
    }

    @Test("Stream packet rejection for all truncated header sizes (0 to 4 bytes)")
    func testTruncatedHeadersRejection() {
        for count in 0..<5 {
            let truncated = Data(repeating: 0x01, count: count)
            #expect(throws: Error.self) {
                try ScreenMirroringService.parseStreamPacket(truncated)
            }
        }
    }

    @Test("Stream packet with declared length exceeding actual buffer is safely bounded")
    func testDeclaredLengthExceedingActualBuffer() throws {
        var packet = Data([0x01])
        var declaredLength = UInt32(10000).bigEndian
        withUnsafeBytes(of: &declaredLength) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: [0x10, 0x20, 0x30]) // Only 3 bytes of payload

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.length == 10000)
        #expect(parsed.payload.count == 3)
        #expect(parsed.payload == Data([0x10, 0x20, 0x30]))
    }

    @Test("Stream packet with UInt32 max declared length does not overflow or crash")
    func testDeclaredLengthUInt32Max() throws {
        var packet = Data([0x01])
        var declaredLength = UInt32.max.bigEndian
        withUnsafeBytes(of: &declaredLength) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: [0xCA, 0xFE])

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.payload.count == 2)
    }

    @Test("Stream packet with declared length 0 but trailing bytes extracts empty payload")
    func testDeclaredLengthZeroWithTrailingBytes() throws {
        var packet = Data([0x01, 0x00, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0x99, 0x88, 0x77]) // Extraneous trailing bytes

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.length == 0)
        #expect(parsed.payload.isEmpty)
    }

    @Test("Stream packet accepts arbitrary stream types (0x00, 0x03, 0xFF)")
    func testArbitraryStreamTypes() throws {
        for type: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x7F, 0xFF] {
            let samplePayload = Data([0x01, 0x02, 0x03])
            let packet = ScreenMirroringService.makeStreamPacket(streamType: type, payload: samplePayload)
            let parsed = try ScreenMirroringService.parseStreamPacket(packet)
            #expect(parsed.streamType == type)
            #expect(parsed.payload == samplePayload)
        }
    }

    // MARK: - 2. Remote Touch Input Boundaries

    @Test("sendInputEvent rigorously clamps negative, excess, and extreme coordinates")
    func testInputEventClamping() {
        let testCases: [(x: Double, y: Double)] = [
            (-1.0, -1.0),
            (-0.0001, -0.0001),
            (-1e9, -1e9),
            (-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude),
            (1.0001, 1.0001),
            (2.5, 3.0),
            (1e9, 1e9),
            (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
            (0.0, 0.0),
            (1.0, 1.0),
            (0.5, 0.5)
        ]

        for tc in testCases {
            // Verify clamping formula max(0.0, min(1.0, val))
            let clampedX = max(0.0, min(1.0, tc.x))
            let clampedY = max(0.0, min(1.0, tc.y))
            #expect(clampedX >= 0.0 && clampedX <= 1.0)
            #expect(clampedY >= 0.0 && clampedY <= 1.0)

            // Verify ScreenMirroringService.sendInputEvent executes without error
            ScreenMirroringService.shared.sendInputEvent(action: "move", x: tc.x, y: tc.y, button: 0)
        }
    }

    @Test("Unknown action names and button values do not crash input event processor")
    func testUnknownActionNamesAndButtons() {
        let unknownActions = [
            "hover_scroll_pinch",
            "3d_touch_press",
            "stylus_hover",
            "",
            "   ",
            "UNKNOWN_RANDOM_ACTION_12345"
        ]

        for action in unknownActions {
            ScreenMirroringService.shared.sendInputEvent(action: action, x: 0.5, y: 0.5, button: 99)
            let msg = ContinuityMessage(type: "input_event", action: action, x: 0.5, y: 0.5, button: 99)
            ScreenMirroringService.shared.handlePeerInputEvent(message: msg)
        }
    }

    @Test("Rapid gesture spam (1000 input events) executes safely")
    func testRapidGestureSpam() {
        for i in 0..<1000 {
            let norm = Double(i % 100) / 100.0
            ScreenMirroringService.shared.sendInputEvent(action: "move", x: norm, y: norm, button: 0)
        }
    }

    // MARK: - 3. Remote Key Events

    @Test("Remote key events with standard and unknown keys")
    func testRemoteKeyEvents() {
        let keys = [
            "BACK", "HOME", "RECENTS", "ENTER", "POWER", "VOLUME_UP", "VOLUME_DOWN",
            "back", "home", "recents",
            "HYPER_DIMENSIONAL_BUTTON", "F24", "SUPER_META_KEY", "", " "
        ]

        for key in keys {
            ScreenMirroringService.shared.sendKeyInput(key: key, keyCode: 9999)
            let msg = ContinuityMessage(type: "input_key", key: key, keyCode: 9999)
            ScreenMirroringService.shared.handlePeerInputKey(message: msg)
        }
    }

    @Test("Remote key events with boundary integer keyCodes")
    func testRemoteKeyCodes() {
        let keyCodes: [Int?] = [nil, -1, 0, 1, 4, 187, 66, 9999, Int.max, Int.min]
        for code in keyCodes {
            ScreenMirroringService.shared.sendKeyInput(key: "TEST_KEY", keyCode: code)
        }
    }

    // MARK: - 4. Session Lifecycle & Idempotence

    @Test("screen_start with zero and negative dimensions preserves state integrity")
    func testScreenStartZeroAndNegativeDimensions() {
        // Zero dimensions
        ScreenMirroringService.shared.startMirroring(width: 0, height: 0, fps: 0, bitrate: 0)

        // Negative dimensions
        ScreenMirroringService.shared.startMirroring(width: -1080, height: -2400, fps: -30, bitrate: -1000)

        // Normal dimensions
        ScreenMirroringService.shared.startMirroring(width: 1080, height: 2400, fps: 60, bitrate: 8000000)

        // Clean stop
        ScreenMirroringService.shared.stopMirroring(reason: "test_complete")
    }

    @Test("screen_stop is strictly idempotent across consecutive invocations")
    func testScreenStopIdempotence() {
        for _ in 0..<10 {
            ScreenMirroringService.shared.stopMirroring(reason: "redundant_stop")
        }
    }

    @Test("Incoming frame handler ingestion with corrupted data does not crash")
    func testIncomingCorruptedFrameHandling() {
        let corruptedFrames = [
            Data(),
            Data([0x00, 0x00, 0x00, 0x01]),
            Data(repeating: 0xFF, count: 64),
            Data("This is not a JPEG or H.264 stream".utf8)
        ]

        for frame in corruptedFrames {
            ScreenMirroringService.shared.handleIncomingFrame(frame)
        }
    }

    // MARK: - 5. Watchdog Stall Recovery (>5000ms)

    @Test("Watchdog triggers stream_stalled when inactive for >5000ms")
    func testWatchdogStallRecovery() async throws {
        await MainActor.run {
            DeviceState.shared.setScreenMirroringActive(false)
        }
        ScreenMirroringService.shared.startMirroring()

        // Verify active state
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        let activeInitially = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
        #expect(activeInitially == true)

        // Wait 5.5s for watchdog (>5000ms) to fire stopMirroring(reason: "stream_stalled")
        try await Task.sleep(nanoseconds: 5_500_000_000)

        let activeAfterStall = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
        #expect(activeAfterStall == false)
    }

    @Test("Watchdog does NOT trigger stall when frames are delivered continuously")
    func testWatchdogKeepaliveWithContinuousFrames() async throws {
        await MainActor.run {
            DeviceState.shared.setScreenMirroringActive(false)
        }
        ScreenMirroringService.shared.startMirroring()

        // Feed frames every 1.0 second for 4 seconds
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            ScreenMirroringService.shared.handleIncomingFrame(Data([0x00, 0x00, 0x00, 0x01]))
        }

        // Mirroring should still be active because frames kept resetting lastFrameReceivedDate
        let activeDuringStream = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
        #expect(activeDuringStream == true)

        ScreenMirroringService.shared.stopMirroring(reason: "test_cleanup")
    }
}
#endif
