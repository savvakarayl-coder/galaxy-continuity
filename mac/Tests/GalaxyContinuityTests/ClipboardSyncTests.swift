#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
import AppKit
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class ClipboardSyncXCTests: XCTestCase {

    @MainActor
    func testSHA256Computation() {
        let emptyHash = ClipboardSyncService.shared.sha256Hex(data: Data())
        XCTAssertEqual(emptyHash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let helloHash = ClipboardSyncService.shared.sha256Hex(data: Data("hello world".utf8))
        XCTAssertEqual(helloHash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    @MainActor
    func testTextClipboardMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "clipboard",
            content: "Hello from Mac",
            contentType: "text/plain",
            source: "mac",
            hash: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
            payload: "Hello from Mac"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        XCTAssertEqual(decoded.type, "clipboard")
        XCTAssertEqual(decoded.content, "Hello from Mac")
        XCTAssertEqual(decoded.contentType, "text/plain")
        XCTAssertEqual(decoded.source, "mac")
        XCTAssertEqual(decoded.hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        XCTAssertEqual(decoded.payload, "Hello from Mac")
    }

    @MainActor
    func testImageClipboardMessageSerialization() throws {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let msg = ContinuityMessage(
            type: "clipboard",
            content: b64,
            contentType: "image/png",
            source: "mac",
            hash: "test_hash_123",
            payload: b64
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        XCTAssertEqual(decoded.type, "clipboard")
        XCTAssertEqual(decoded.content, b64)
        XCTAssertEqual(decoded.contentType, "image/png")
        XCTAssertEqual(decoded.source, "mac")
    }

    @MainActor
    func testIncomingClipboardEchoSuppression() {
        let testText = "Unique Echo Test String \(UUID().uuidString)"
        let hash = ClipboardSyncService.shared.sha256Hex(data: Data(testText.utf8))

        // First receive
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: testText,
            contentType: "text/plain",
            hash: hash,
            sender: "Galaxy"
        )
        XCTAssertEqual(DeviceState.shared.lastSharedClipboard, testText)

        // Reset clipboard state to check if echo is dropped
        DeviceState.shared.lastSharedClipboard = "changed_locally"

        // Second receive with identical hash -> MUST drop
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: testText,
            contentType: "text/plain",
            hash: hash,
            sender: "Galaxy"
        )
        // Verify it was dropped and did not overwrite
        XCTAssertEqual(DeviceState.shared.lastSharedClipboard, "changed_locally")
    }

    @MainActor
    func testIncomingImageClipboardHandling() {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: b64,
            contentType: "image/png",
            hash: nil,
            sender: "Galaxy"
        )
        XCTAssertEqual(DeviceState.shared.lastSharedClipboard, b64)
        XCTAssertEqual(DeviceState.shared.lastSharedClipboardType, "image/png")
    }

    @MainActor
    func testCorruptedBase64DoesNotCrash() {
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: "!@#$%^&*()_InvalidBase64",
            contentType: "image/png",
            hash: nil,
            sender: "Galaxy"
        )
        XCTAssertTrue(true)
    }

    @MainActor
    func testEmptyStringClipboardHandling() {
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: "",
            contentType: "text/plain",
            hash: nil,
            sender: "Galaxy"
        )
        XCTAssertEqual(DeviceState.shared.lastSharedClipboard, "")
    }
}
#endif

#if canImport(Testing)
@Suite("Universal Clipboard Parity Tests")
struct ClipboardSyncTests {

    @Test("SHA-256 computation matches known test vectors")
    @MainActor
    func testSHA256Computation() {
        let emptyHash = ClipboardSyncService.shared.sha256Hex(data: Data())
        #expect(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let helloHash = ClipboardSyncService.shared.sha256Hex(data: Data("hello world".utf8))
        #expect(helloHash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    @Test("Text clipboard message roundtrip serialization")
    @MainActor
    func testTextClipboardMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "clipboard",
            content: "Hello from Mac",
            contentType: "text/plain",
            source: "mac",
            hash: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
            payload: "Hello from Mac"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "clipboard")
        #expect(decoded.content == "Hello from Mac")
        #expect(decoded.contentType == "text/plain")
        #expect(decoded.source == "mac")
        #expect(decoded.hash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(decoded.payload == "Hello from Mac")
    }

    @Test("Image clipboard message roundtrip serialization")
    @MainActor
    func testImageClipboardMessageSerialization() throws {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let msg = ContinuityMessage(
            type: "clipboard",
            content: b64,
            contentType: "image/png",
            source: "mac",
            hash: "test_hash_123",
            payload: b64
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "clipboard")
        #expect(decoded.content == b64)
        #expect(decoded.contentType == "image/png")
        #expect(decoded.source == "mac")
    }

    @Test("Incoming clipboard echo suppression prevents duplicate updates")
    @MainActor
    func testIncomingClipboardEchoSuppression() {
        let testText = "Unique Echo Test String \(UUID().uuidString)"
        let hash = ClipboardSyncService.shared.sha256Hex(data: Data(testText.utf8))

        ClipboardSyncService.shared.handleIncomingClipboard(
            content: testText,
            contentType: "text/plain",
            hash: hash,
            sender: "Galaxy"
        )
        #expect(DeviceState.shared.lastSharedClipboard == testText)

        DeviceState.shared.lastSharedClipboard = "changed_locally"

        ClipboardSyncService.shared.handleIncomingClipboard(
            content: testText,
            contentType: "text/plain",
            hash: hash,
            sender: "Galaxy"
        )
        #expect(DeviceState.shared.lastSharedClipboard == "changed_locally")
    }

    @Test("Incoming image clipboard updates device state")
    @MainActor
    func testIncomingImageClipboardHandling() {
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: b64,
            contentType: "image/png",
            hash: nil,
            sender: "Galaxy"
        )
        #expect(DeviceState.shared.lastSharedClipboard == b64)
        #expect(DeviceState.shared.lastSharedClipboardType == "image/png")
    }

    @Test("Corrupted base64 payload does not crash")
    @MainActor
    func testCorruptedBase64DoesNotCrash() {
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: "!@#$%^&*()_InvalidBase64",
            contentType: "image/png",
            hash: nil,
            sender: "Galaxy"
        )
        #expect(Bool(true))
    }

    @Test("Empty string clipboard is handled safely")
    @MainActor
    func testEmptyStringClipboardHandling() {
        ClipboardSyncService.shared.handleIncomingClipboard(
            content: "",
            contentType: "text/plain",
            hash: nil,
            sender: "Galaxy"
        )
        #expect(DeviceState.shared.lastSharedClipboard == "")
    }
}
#endif
