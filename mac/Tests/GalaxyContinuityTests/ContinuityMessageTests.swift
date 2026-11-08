#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class ContinuityMessageXCTests: XCTestCase {

    func testNumericButtonDecoding() throws {
        for btn in [0, 1, 2] {
            let json = """
            {"type":"input_event","action":"down","x":0.45,"y":0.82,"button":\(btn)}
            """
            let msg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
            XCTAssertEqual(msg.type, "input_event")
            XCTAssertEqual(msg.button, btn)
            XCTAssertEqual(msg.action, "down")
            XCTAssertEqual(msg.x, 0.45)
            XCTAssertEqual(msg.y, 0.82)
        }
    }

    func testPercentageDecoding() throws {
        let decJson = """
        {"type":"file_progress","fileId":"test-1","bytesTransferred":50,"totalBytes":100,"percentage":50.5,"status":"transferring"}
        """
        let decMsg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(decJson.utf8))
        XCTAssertEqual(decMsg.percentage, 50.5)

        let intJson = """
        {"type":"file_progress","fileId":"test-2","bytesTransferred":100,"totalBytes":100,"percentage":100,"status":"completed"}
        """
        let intMsg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(intJson.utf8))
        XCTAssertEqual(intMsg.percentage, 100.0)
    }

    func testRoundtripSerialization() throws {
        let original = ContinuityMessage(
            type: "input_event",
            percentage: 75.5,
            action: "move",
            x: 0.123,
            y: 0.456,
            button: 0
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
#endif

#if canImport(Testing)
@Suite("ContinuityMessage Schema Harmonization Tests")
struct ContinuityMessageTests {

    @Test("Decode input_event with numeric button (0, 1, 2)")
    func testNumericButtonDecoding() throws {
        for btn in [0, 1, 2] {
            let json = """
            {"type":"input_event","action":"down","x":0.45,"y":0.82,"button":\(btn)}
            """
            let msg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
            #expect(msg.type == "input_event")
            #expect(msg.button == btn)
            #expect(msg.action == "down")
            #expect(msg.x == 0.45)
            #expect(msg.y == 0.82)
        }
    }

    @Test("Decode file_progress with decimal and integer percentage")
    func testPercentageDecoding() throws {
        // Decimal percentage
        let decJson = """
        {"type":"file_progress","fileId":"test-1","bytesTransferred":50,"totalBytes":100,"percentage":50.5,"status":"transferring"}
        """
        let decMsg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(decJson.utf8))
        #expect(decMsg.percentage == 50.5)

        // Integer percentage
        let intJson = """
        {"type":"file_progress","fileId":"test-2","bytesTransferred":100,"totalBytes":100,"percentage":100,"status":"completed"}
        """
        let intMsg = try JSONDecoder().decode(ContinuityMessage.self, from: Data(intJson.utf8))
        #expect(intMsg.percentage == 100.0)
    }

    @Test("Roundtrip serialization of ContinuityMessage with button and percentage")
    func testRoundtripSerialization() throws {
        let original = ContinuityMessage(
            type: "input_event",
            percentage: 75.5,
            action: "move",
            x: 0.123,
            y: 0.456,
            button: 0
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Roundtrip serialization of input_text message")
    func testInputTextSerialization() throws {
        let msg = ContinuityMessage(type: "input_text", text: "Привет мир! 🚀")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_text")
        #expect(decoded.text == "Привет мир! 🚀")
    }

    @Test("Roundtrip serialization of input_scroll with float and integer deltas")
    func testInputScrollSerialization() throws {
        let msg = ContinuityMessage(type: "input_scroll", x: 0.5, y: 0.5, dx: 12.5, dy: -45.0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_scroll")
        #expect(decoded.x == 0.5)
        #expect(decoded.y == 0.5)
        #expect(decoded.dx == 12.5)
        #expect(decoded.dy == -45.0)
    }

    @Test("Decode input_scroll from raw JSON with integer and decimal values")
    func testInputScrollRawJsonDecoding() throws {
        let json = """
        {"type":"input_scroll","x":0.25,"y":0.75,"dx":0,"dy":-15}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: json)
        #expect(decoded.type == "input_scroll")
        #expect(decoded.dx == 0.0)
        #expect(decoded.dy == -15.0)
    }

    @Test("Roundtrip serialization of notification_open message")
    func testNotificationOpenSerialization() throws {
        let msg = ContinuityMessage(
            type: "notification_open",
            id: "notif-uuid-88991",
            packageName: "org.telegram.messenger"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "notification_open")
        #expect(decoded.id == "notif-uuid-88991")
        #expect(decoded.packageName == "org.telegram.messenger")
    }

    @Test("Serialization of editing keys in input_key (DEL, ENTER, TAB, ESCAPE)")
    func testEditingKeysSerialization() throws {
        let keys = [
            ("DEL", 67),
            ("ENTER", 66),
            ("TAB", 61),
            ("ESCAPE", 111),
            ("SPACE", 62)
        ]
        for (name, code) in keys {
            let msg = ContinuityMessage(type: "input_key", key: name, keyCode: code)
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
            #expect(decoded.type == "input_key")
            #expect(decoded.key == name)
            #expect(decoded.keyCode == code)
        }
    }
}
#endif
