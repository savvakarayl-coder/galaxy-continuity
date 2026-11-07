import Foundation
import CryptoKit
import GalaxyContinuityKit

var testsPassed = 0
var testsFailed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #file, line: Int = #line) {
    if actual == expected {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("❌ FAIL [\(line)]: \(message) — Expected: \(expected), Got: \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        testsPassed += 1
    } else {
        testsFailed += 1
        print("❌ FAIL [\(line)]: \(message)")
    }
}

func assertFalse(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    assertTrue(!condition, message, file: file, line: line)
}

print("=================================================================")
print("RUNNING ADVERSARIAL WEBSOCKET FRAMER TESTS (SWIFT)")
print("=================================================================")

// MARK: 1. Boundary Length Verification
print("\n--- 1. Boundary Length Verification ---")
let testLengths = [0, 1, 124, 125, 126, 127, 65534, 65535, 65536, 65537, 100000]

for len in testLengths {
    let payload = Data(repeating: UInt8(len % 251), count: len)
    for isMasked in [false, true] {
        let mask: [UInt8]? = isMasked ? [0x12, 0x34, 0x56, 0x78] : nil
        let encoded = WebSocketFramer.encodeFrame(
            opcode: 0x2,
            payload: payload,
            fin: true,
            isMasked: isMasked,
            maskKey: mask
        )

        // Verify header encoding
        let b1 = encoded[1]
        let maskBit: UInt8 = isMasked ? 0x80 : 0x00
        if len <= 125 {
            assertEqual(b1, maskBit | UInt8(len), "Len \(len) 7-bit header byte")
        } else if len <= 65535 {
            assertEqual(b1, maskBit | 126, "Len \(len) 16-bit indicator")
            let encLen = (UInt16(encoded[2]) << 8) | UInt16(encoded[3])
            assertEqual(Int(encLen), len, "Len \(len) 16-bit extended length")
        } else {
            assertEqual(b1, maskBit | 127, "Len \(len) 64-bit indicator")
            var encLen: UInt64 = 0
            for i in 2..<10 {
                encLen = (encLen << 8) | UInt64(encoded[i])
            }
            assertEqual(Int(encLen), len, "Len \(len) 64-bit extended length")
        }

        // Verify roundtrip decoding
        var buffer = encoded
        let decoded = WebSocketFramer.decodeFrame(from: &buffer)
        assertTrue(decoded != nil, "Len \(len) masked=\(isMasked) decoded != nil")
        if let d = decoded {
            assertEqual(d.payload.count, len, "Len \(len) payload length matches")
            assertEqual(d.payload, payload, "Len \(len) payload content matches")
            assertEqual(d.opcode, 0x2, "Len \(len) opcode matches")
            assertTrue(d.fin, "Len \(len) fin is true")
        }
        assertTrue(buffer.isEmpty, "Len \(len) buffer empty after decode")
    }
}

// MARK: 2. Masking & Cyclic Byte Patterns
print("\n--- 2. Masking & Cyclic Patterns ---")
let cyclicMasks: [[UInt8]] = [
    [0x00, 0x00, 0x00, 0x00],
    [0xFF, 0xFF, 0xFF, 0xFF],
    [0xAA, 0x55, 0xAA, 0x55],
    [0x01, 0x02, 0x03, 0x04],
    [0xCA, 0xFE, 0xBA, 0xBE]
]

for mask in cyclicMasks {
    // Test payload with period matching mask length (4 bytes)
    let periodicPayload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
    let encoded = WebSocketFramer.encodeFrame(
        opcode: 0x1,
        payload: periodicPayload,
        fin: true,
        isMasked: true,
        maskKey: mask
    )

    var buffer = encoded
    let decoded = WebSocketFramer.decodeFrame(from: &buffer)
    assertTrue(decoded != nil, "Cyclic mask \(mask) decode not nil")
    assertEqual(decoded?.payload, periodicPayload, "Cyclic mask \(mask) payload matches")
}

// MARK: 3. Partial / Truncated Buffers
print("\n--- 3. Truncated Buffers & Streaming Decoding ---")
let samplePayload = Data("Adversarial stream fragmentation test payload".utf8)
let fullFrame = WebSocketFramer.encodeFrame(opcode: 0x1, payload: samplePayload, fin: true, isMasked: true)

// Every truncation prefix must return nil without consuming buffer
for cut in 0..<fullFrame.count {
    var prefix = fullFrame.prefix(cut)
    let origCount = prefix.count
    let decoded = WebSocketFramer.decodeFrame(from: &prefix)
    assertTrue(decoded == nil, "Truncated at \(cut)/\(fullFrame.count) should return nil")
    assertEqual(prefix.count, origCount, "Buffer should not be modified on nil return")
}

// Feed byte-by-byte into accumulator
var streamBuffer = Data()
var recoveredFrame: WebSocketFrame? = nil
for byte in fullFrame {
    streamBuffer.append(byte)
    if let f = WebSocketFramer.decodeFrame(from: &streamBuffer) {
        recoveredFrame = f
        break
    }
}
assertTrue(recoveredFrame != nil, "Incremental byte-by-byte feeding decodes frame")
assertEqual(recoveredFrame?.payload, samplePayload, "Byte-by-byte decoded payload matches")
assertTrue(streamBuffer.isEmpty, "Stream buffer empty after complete frame")

// MARK: 4. RFC 6455 WebSocket Accept Key Verification
print("\n--- 4. Sec-WebSocket-Accept Tests ---")
let testVectors: [(clientKey: String, expectedAccept: String)] = [
    ("dGhlIHNhbXBsZSBub25jZQ==", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), // RFC 6455 Section 1.3 vector
    ("  dGhlIHNhbXBsZSBub25jZQ==  \r\n", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), // Whitespace stripping
    ("x3JJHMbDL1EzLkh9GBhXDw==", "HSmrc0sMlYUkAGmm5OPpG2HaGWk=")
]

for tv in testVectors {
    let accept = WebSocketFramer.computeAcceptKey(for: tv.clientKey)
    assertEqual(accept, tv.expectedAccept, "Accept key computation for '\(tv.clientKey)'")
}

// MARK: 5. Fragmented Frames & FIN handling
print("\n--- 5. Fragmented Frame Flag Handling ---")
let frag1Payload = Data("Part 1 - ".utf8)
let frag2Payload = Data("Part 2".utf8)

let frameFrag1 = WebSocketFramer.encodeFrame(opcode: 0x1, payload: frag1Payload, fin: false, isMasked: false)
let frameFrag2 = WebSocketFramer.encodeFrame(opcode: 0x0, payload: frag2Payload, fin: true, isMasked: false)

var fragBuffer = frameFrag1 + frameFrag2
let dFrag1 = WebSocketFramer.decodeFrame(from: &fragBuffer)
assertTrue(dFrag1 != nil, "dFrag1 decoded")
assertEqual(dFrag1?.fin, false, "dFrag1 fin == false")
assertEqual(dFrag1?.opcode, 0x1, "dFrag1 opcode == 0x1")
assertEqual(dFrag1?.payload, frag1Payload, "dFrag1 payload matches")

let dFrag2 = WebSocketFramer.decodeFrame(from: &fragBuffer)
assertTrue(dFrag2 != nil, "dFrag2 decoded")
assertEqual(dFrag2?.fin, true, "dFrag2 fin == true")
assertEqual(dFrag2?.opcode, 0x0, "dFrag2 opcode == 0x0 (Continuation)")
assertEqual(dFrag2?.payload, frag2Payload, "dFrag2 payload matches")
assertTrue(fragBuffer.isEmpty, "fragBuffer empty after 2 frames")

print("\n=================================================================")
print("SWIFT FRAMER TEST RESULTS: \(testsPassed) Passed, \(testsFailed) Failed")
print("=================================================================")
if testsFailed > 0 {
    exit(1)
}
