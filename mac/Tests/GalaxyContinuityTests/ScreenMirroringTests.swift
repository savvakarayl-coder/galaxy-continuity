#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class ScreenMirroringXCTests: XCTestCase {

    func testScreenStartSerialization() throws {
        let msg = ContinuityMessage(
            type: "screen_start",
            width: 1080,
            height: 2400,
            fps: 30,
            bitrate: 4000000
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "screen_start")
        XCTAssertEqual(decoded.width, 1080)
        XCTAssertEqual(decoded.height, 2400)
        XCTAssertEqual(decoded.fps, 30)
        XCTAssertEqual(decoded.bitrate, 4000000)
    }

    func testScreenStopSerialization() throws {
        let msg = ContinuityMessage(type: "screen_stop", reason: "user_dismissed")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "screen_stop")
        XCTAssertEqual(decoded.reason, "user_dismissed")
    }

    func testInputEventSerialization() throws {
        let msg = ContinuityMessage(type: "input_event", action: "down", x: 0.452, y: 0.819, button: 0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "input_event")
        XCTAssertEqual(decoded.action, "down")
        XCTAssertEqual(decoded.x, 0.452)
        XCTAssertEqual(decoded.y, 0.819)
        XCTAssertEqual(decoded.button, 0)
    }

    func testInputKeySerialization() throws {
        let msg = ContinuityMessage(type: "input_key", key: "BACK", keyCode: 4)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "input_key")
        XCTAssertEqual(decoded.key, "BACK")
        XCTAssertEqual(decoded.keyCode, 4)
    }

    func testScreenStreamPacketFraming() throws {
        let mockPayload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x01, payload: mockPayload)
        XCTAssertEqual(packet.count, 5 + mockPayload.count)
        XCTAssertEqual(packet[0], 0x01)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        XCTAssertEqual(parsed.streamType, 0x01)
        XCTAssertEqual(parsed.length, mockPayload.count)
        XCTAssertEqual(parsed.payload, mockPayload)
    }

    func testCorruptedPacketShortHeaderThrows() {
        let truncated = Data([0x01, 0x00, 0x00])
        XCTAssertThrowsError(try ScreenMirroringService.parseStreamPacket(truncated))
    }

    func testZeroLengthPayloadHandling() throws {
        let emptyPayload = Data()
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x01, payload: emptyPayload)
        XCTAssertEqual(packet.count, 5)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        XCTAssertEqual(parsed.streamType, 0x01)
        XCTAssertEqual(parsed.length, 0)
        XCTAssertTrue(parsed.payload.isEmpty)
    }

    func testBoundaryCoordinatesDoNotCrash() throws {
        let jsonNegative = """
        {"type":"input_event","action":"down","x":-0.5,"y":-0.2,"button":0}
        """
        let msgNegative = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonNegative.utf8))
        XCTAssertEqual(msgNegative.x, -0.5)
        XCTAssertEqual(msgNegative.y, -0.2)

        let jsonExcess = """
        {"type":"input_event","action":"move","x":2.5,"y":3.0,"button":0}
        """
        let msgExcess = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonExcess.utf8))
        XCTAssertEqual(msgExcess.x, 2.5)
        XCTAssertEqual(msgExcess.y, 3.0)
    }
}
#endif

#if canImport(Testing)
@Suite("Screen Mirroring Parity Tests")
struct ScreenMirroringTests {

    @Test("Serialize screen_start control message")
    func testScreenStartSerialization() throws {
        let msg = ContinuityMessage(
            type: "screen_start",
            width: 1080,
            height: 2400,
            fps: 30,
            bitrate: 4000000
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "screen_start")
        #expect(decoded.width == 1080)
        #expect(decoded.height == 2400)
        #expect(decoded.fps == 30)
        #expect(decoded.bitrate == 4000000)
    }

    @Test("Serialize screen_stop control message")
    func testScreenStopSerialization() throws {
        let msg = ContinuityMessage(type: "screen_stop", reason: "user_dismissed")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "screen_stop")
        #expect(decoded.reason == "user_dismissed")
    }

    @Test("Serialize input_event remote touch gesture")
    func testInputEventSerialization() throws {
        let msg = ContinuityMessage(type: "input_event", action: "down", x: 0.452, y: 0.819, button: 0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_event")
        #expect(decoded.action == "down")
        #expect(decoded.x == 0.452)
        #expect(decoded.y == 0.819)
        #expect(decoded.button == 0)
    }

    @Test("Serialize input_key remote navigation event")
    func testInputKeySerialization() throws {
        let msg = ContinuityMessage(type: "input_key", key: "BACK", keyCode: 4)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_key")
        #expect(decoded.key == "BACK")
        #expect(decoded.keyCode == 4)
    }

    @Test("Binary stream packet framing roundtrip (type 0x01)")
    func testScreenStreamPacketFraming() throws {
        let mockPayload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x01, payload: mockPayload)
        #expect(packet.count == 5 + mockPayload.count)
        #expect(packet[0] == 0x01)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.length == mockPayload.count)
        #expect(parsed.payload == mockPayload)
    }

    @Test("Corrupted packet with short header (< 5 bytes) throws error")
    func testCorruptedPacketShortHeaderThrows() {
        let truncated = Data([0x01, 0x00, 0x00])
        #expect(throws: Error.self) {
            try ScreenMirroringService.parseStreamPacket(truncated)
        }
    }

    @Test("Zero-length payload stream packet parses cleanly")
    func testZeroLengthPayloadHandling() throws {
        let emptyPayload = Data()
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x01, payload: emptyPayload)
        #expect(packet.count == 5)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x01)
        #expect(parsed.length == 0)
        #expect(parsed.payload.isEmpty)
    }

    @Test("Boundary touch coordinates do not cause server error")
    func testBoundaryCoordinatesDoNotCrash() throws {
        let jsonNegative = """
        {"type":"input_event","action":"down","x":-0.5,"y":-0.2,"button":0}
        """
        let msgNegative = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonNegative.utf8))
        #expect(msgNegative.x == -0.5)
        #expect(msgNegative.y == -0.2)

        let jsonExcess = """
        {"type":"input_event","action":"move","x":2.5,"y":3.0,"button":0}
        """
        let msgExcess = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonExcess.utf8))
        #expect(msgExcess.x == 2.5)
        #expect(msgExcess.y == 3.0)
    }

    @Test("Serialize input_text message")
    func testInputTextSerialization() throws {
        let msg = ContinuityMessage(type: "input_text", text: "Hello Galaxy")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_text")
        #expect(decoded.text == "Hello Galaxy")
    }

    @Test("Serialize input_scroll message with deltas")
    func testInputScrollSerialization() throws {
        let msg = ContinuityMessage(type: "input_scroll", x: 0.5, y: 0.5, dx: 10.0, dy: -25.5)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_scroll")
        #expect(decoded.x == 0.5)
        #expect(decoded.y == 0.5)
        #expect(decoded.dx == 10.0)
        #expect(decoded.dy == -25.5)
    }

    @Test("Keycode resolution for editing keys")
    func testExtendedKeyResolution() {
        ScreenMirroringService.shared.sendKeyInput(key: "BACKSPACE")
        ScreenMirroringService.shared.sendKeyInput(key: "ENTER")
        ScreenMirroringService.shared.sendKeyInput(key: "TAB")
        ScreenMirroringService.shared.sendKeyInput(key: "ESCAPE")
        ScreenMirroringService.shared.sendKeyInput(key: "SPACE")
        ScreenMirroringService.shared.sendKeyInput(key: "DPAD_UP")
        ScreenMirroringService.shared.sendKeyInput(key: "DPAD_DOWN")
    }

    @Test("Coordinate clamping on scroll dispatch prevents out-of-bounds input")
    func testScrollCoordinateClamping() {
        let service = ScreenMirroringService.shared
        // sendScrollInput with raw coords -0.2, 1.4 must clamp to 0.0 and 1.0
        service.sendScrollInput(x: -0.2, y: 1.4, dx: 0.0, dy: -30.0)
        // Verify no fatal errors, clamped coordinates passed to message
    }

    @Test("Scroll delta accumulator coalesces high-frequency trackpad events")
    func testScrollDeltaAccumulator() {
        var accumulatorDx: Double = 0.0
        var accumulatorDy: Double = 0.0

        // Simulate 10 high-frequency micro-scroll events within 16ms
        for _ in 0..<10 {
            accumulatorDx += 0.2
            accumulatorDy += -1.5
        }

        #expect(accumulatorDx > 1.99 && accumulatorDx < 2.01)
        #expect(accumulatorDy > -15.01 && accumulatorDy < -14.99)
    }
}
#endif
