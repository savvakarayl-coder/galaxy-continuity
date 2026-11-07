#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

// MARK: - Swift Testing Implementation

#if canImport(Testing)
@Suite("WebSocket Framer Tests")
struct WebSocketFramerTests {

    @Test("7-bit payload length encoding and decoding (<= 125 bytes)")
    func test7BitPayloadLength() {
        let payload = Data("Hello, Continuity!".utf8)
        #expect(payload.count <= 125)

        // Encode unmasked text frame
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x1, payload: payload, fin: true, isMasked: false)
        #expect(encoded.count == 2 + payload.count)
        #expect(encoded[0] == 0x81) // FIN (0x80) | Text (0x01)
        #expect(encoded[1] == UInt8(payload.count)) // Unmasked (0x00) | length

        // Decode
        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded?.fin == true)
        #expect(decoded?.opcode == 0x1)
        #expect(decoded?.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test("16-bit payload length encoding and decoding (126 to 65535 bytes)")
    func test16BitPayloadLength() {
        // Create 1000 bytes payload
        let payload = Data(repeating: 0xAB, count: 1000)
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x2, payload: payload, fin: true, isMasked: false)

        #expect(encoded[0] == 0x82) // FIN | Binary
        #expect(encoded[1] == 126)  // 16-bit length indicator
        let lengthHigh = UInt16(encoded[2]) << 8
        let lengthLow = UInt16(encoded[3])
        let encodedLen = lengthHigh | lengthLow
        #expect(encodedLen == 1000)

        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded?.fin == true)
        #expect(decoded?.opcode == 0x2)
        #expect(decoded?.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test("64-bit payload length encoding and decoding (> 65535 bytes)")
    func test64BitPayloadLength() {
        // 70,000 bytes payload
        let payload = Data(repeating: 0x55, count: 70000)
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x2, payload: payload, fin: true, isMasked: false)

        #expect(encoded[0] == 0x82) // FIN | Binary
        #expect(encoded[1] == 127)  // 64-bit length indicator

        var decodedLen: UInt64 = 0
        for i in 2..<10 {
            decodedLen = (decodedLen << 8) | UInt64(encoded[i])
        }
        #expect(decodedLen == 70000)

        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded?.fin == true)
        #expect(decoded?.opcode == 0x2)
        #expect(decoded?.payload.count == 70000)
        #expect(decoded?.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test("Masking and unmasking with fixed mask key")
    func testMaskingWithFixedKey() {
        let payload = Data("Sensitive Continuity Payload".utf8)
        let maskKey: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

        let encoded = WebSocketFramer.encodeFrame(
            opcode: 0x1,
            payload: payload,
            fin: true,
            isMasked: true,
            maskKey: maskKey
        )

        // Mask bit must be set in byte 1
        #expect((encoded[1] & 0x80) != 0)
        #expect((encoded[1] & 0x7F) == UInt8(payload.count))

        // Bytes 2-5 are mask key
        #expect(Array(encoded[2..<6]) == maskKey)

        // Raw payload bytes should be XOR masked
        let rawMasked = encoded[6...]
        #expect(rawMasked != payload)

        // Decode should recover original unmasked data
        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded?.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test("Opcode handling: Ping, Pong, Close, and Continuation")
    func testOpcodeHandling() {
        let opcodes: [(UInt8, String)] = [
            (0x1, "Text"),
            (0x2, "Binary"),
            (0x8, "Close"),
            (0x9, "Ping"),
            (0xA, "Pong")
        ]

        for (opcode, _) in opcodes {
            let payload = Data("control_\(opcode)".utf8)
            let encoded = WebSocketFramer.encodeFrame(opcode: opcode, payload: payload, fin: true)
            var buffer = encoded
            let decoded = WebSocketFramer.decodeFrame(from: &buffer)
            #expect(decoded?.opcode == opcode)
            #expect(decoded?.payload == payload)
            #expect(decoded?.fin == true)
        }
    }

    @Test("FIN flag handling (fragmented vs complete frames)")
    func testFinFlagHandling() {
        let payload = Data("fragment".utf8)
        let nonFinFrame = WebSocketFramer.encodeFrame(opcode: 0x1, payload: payload, fin: false)
        var buffer = nonFinFrame
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        #expect(decoded != nil)
        #expect(decoded?.fin == false)
        #expect(decoded?.opcode == 0x1)
    }

    @Test("Partial and concatenated frame stream decoding")
    func testPartialAndConcatenatedFrames() {
        let p1 = Data("First message".utf8)
        let p2 = Data("Second message".utf8)

        let frame1 = WebSocketFramer.encodeFrame(opcode: 0x1, payload: p1)
        let frame2 = WebSocketFramer.encodeFrame(opcode: 0x1, payload: p2)

        var stream = frame1 + frame2

        // Decode first
        let d1 = WebSocketFramer.decodeFrame(from: &stream)
        #expect(d1?.payload == p1)
        #expect(!stream.isEmpty)

        // Decode second
        let d2 = WebSocketFramer.decodeFrame(from: &stream)
        #expect(d2?.payload == p2)
        #expect(stream.isEmpty)

        // Incremental feeding byte by byte
        var partial = Data()
        for b in frame1 {
            partial.append(b)
            if partial.count < frame1.count {
                var copy = partial
                #expect(WebSocketFramer.decodeFrame(from: &copy) == nil)
            }
        }
        let completed = WebSocketFramer.decodeFrame(from: &partial)
        #expect(completed?.payload == p1)
        #expect(partial.isEmpty)
    }
}
#endif

// MARK: - XCTest Implementation

#if canImport(XCTest)
final class WebSocketFramerXCTests: XCTestCase {

    func test7BitPayloadLength() {
        let payload = Data("Hello, Continuity!".utf8)
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x1, payload: payload, fin: true, isMasked: false)
        XCTAssertEqual(encoded[0], 0x81)
        XCTAssertEqual(encoded[1], UInt8(payload.count))

        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload, payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func test16BitPayloadLength() {
        let payload = Data(repeating: 0xAB, count: 1000)
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x2, payload: payload, fin: true, isMasked: false)
        XCTAssertEqual(encoded[0], 0x82)
        XCTAssertEqual(encoded[1], 126)

        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func test64BitPayloadLength() {
        let payload = Data(repeating: 0x55, count: 70000)
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x2, payload: payload, fin: true, isMasked: false)
        XCTAssertEqual(encoded[0], 0x82)
        XCTAssertEqual(encoded[1], 127)

        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload.count, 70000)
    }

    func testMaskingWithFixedKey() {
        let payload = Data("Sensitive Continuity Payload".utf8)
        let maskKey: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let encoded = WebSocketFramer.encodeFrame(opcode: 0x1, payload: payload, fin: true, isMasked: true, maskKey: maskKey)

        XCTAssertTrue((encoded[1] & 0x80) != 0)
        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testOpcodeHandling() {
        let opcodes: [UInt8] = [0x1, 0x2, 0x8, 0x9, 0xA]
        for op in opcodes {
            let payload = Data("op_\(op)".utf8)
            let encoded = WebSocketFramer.encodeFrame(opcode: op, payload: payload)
            var buffer = encoded
            let decoded = WebSocketFramer.decodeFrame(from: &buffer)
            XCTAssertEqual(decoded?.opcode, op)
        }
    }
}
#endif
