#if canImport(Testing)
import Testing
#endif
@testable import GalaxyContinuityKit

final class HandshakeTests: XCTestCase {

    func testRFC6455StandardTestVector() {
        // RFC 6455 Section 1.3 standard test vector:
        // Client sends: "dGhlIHNhbXBsZSBub25jZQ=="
        // Server computes: SHA1("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        // Base64 encoded result MUST be: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let clientKey = "dGhlIHNhbXBsZSBub25jZQ=="
        let expectedAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

        let computedAccept = WebSocketFramer.computeAcceptKey(for: clientKey)
        XCTAssertEqual(computedAccept, expectedAccept, "WebSocket accept key calculation must match RFC 6455 standard vector")
    }

    func testComputeAcceptKeyWithWhitespace() {
        // Client key with surrounding whitespace should be trimmed
        let clientKeyWithSpaces = "  dGhlIHNhbXBsZSBub25jZQ== \r\n"
        let expectedAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

        let computedAccept = WebSocketFramer.computeAcceptKey(for: clientKeyWithSpaces)
        XCTAssertEqual(computedAccept, expectedAccept, "Leading/trailing whitespace should be trimmed before hashing")
    }

    func testComputeAcceptKeyWithVariousKeys() {
        let testCases: [(key: String, expectedGuidSuffix: String)] = [
            ("x3JJHMbDL1EzLkh9GBhXDw==", "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
            ("HSmrc0sMlYUkAGmm5OPpG2==", "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        ]

        for tc in testCases {
            let accept = WebSocketFramer.computeAcceptKey(for: tc.key)
            XCTAssertFalse(accept.isEmpty, "Accept key must not be empty")
            // Base64 of SHA1 (20 bytes) is always 28 characters ending with "="
            XCTAssertEqual(accept.count, 28, "SHA-1 base64 string must be 28 characters")
            XCTAssertTrue(accept.hasSuffix("="), "20-byte SHA-1 base64 hash must have single padding char =")
        }
    }
}
