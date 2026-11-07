#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class WebSocketFragmentationXCTests: XCTestCase {

    func testFragmentationReassembly() {
        let client = ConnectedClient(fd: -1)

        let chunk1 = Data("{\"type\":\"clipboard\",\"content\":\"Hello ".utf8)
        let chunk2 = Data("from fragmented ".utf8)
        let chunk3 = Data("frames!\",\"source\":\"phone\"}".utf8)

        // Frame 1: Text initial fragment (fin: false, opcode: 0x1)
        let f1 = WebSocketFrame(fin: false, opcode: 0x1, payload: chunk1)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f1)
        XCTAssertEqual(client.fragmentOpcode, 0x1)
        XCTAssertEqual(client.fragmentBuffer, chunk1)

        // Frame 2: Continuation fragment (fin: false, opcode: 0x0)
        let f2 = WebSocketFrame(fin: false, opcode: 0x0, payload: chunk2)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f2)
        XCTAssertEqual(client.fragmentOpcode, 0x1)
        XCTAssertEqual(client.fragmentBuffer, chunk1 + chunk2)

        // Frame 3: Final continuation frame (fin: true, opcode: 0x0)
        let f3 = WebSocketFrame(fin: true, opcode: 0x0, payload: chunk3)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f3)
        XCTAssertNil(client.fragmentOpcode)
        XCTAssertTrue(client.fragmentBuffer.isEmpty)
    }

    func testInterleavedControlFrame() {
        let client = ConnectedClient(fd: -1)

        let chunk1 = Data("{\"type\":\"ping_device\",".utf8)
        let chunk2 = Data("\"source\":\"phone\"}".utf8)

        // Frame 1: Text fragment
        let f1 = WebSocketFrame(fin: false, opcode: 0x1, payload: chunk1)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f1)
        XCTAssertEqual(client.fragmentOpcode, 0x1)
        XCTAssertEqual(client.fragmentBuffer, chunk1)

        // Frame 2: Interleaved Ping (opcode 0x9)
        let fPing = WebSocketFrame(fin: true, opcode: 0x9, payload: Data("heartbeat".utf8))
        ServerManager.shared.handleWebSocketFrame(client: client, frame: fPing)
        // Accumulator MUST remain untouched
        XCTAssertEqual(client.fragmentOpcode, 0x1)
        XCTAssertEqual(client.fragmentBuffer, chunk1)

        // Frame 3: Continuation (opcode 0x0, fin: true)
        let f2 = WebSocketFrame(fin: true, opcode: 0x0, payload: chunk2)
        ServerManager.shared.handleWebSocketFrame(client: client, frame: f2)
        XCTAssertNil(client.fragmentOpcode)
        XCTAssertTrue(client.fragmentBuffer.isEmpty)
    }

    func testUnexpectedContinuationFrame() {
        let client = ConnectedClient(fd: -1)
        let orphanContinuation = WebSocketFrame(fin: true, opcode: 0x0, payload: Data("orphan".utf8))
        ServerManager.shared.handleWebSocketFrame(client: client, frame: orphanContinuation)
        XCTAssertNil(client.fragmentOpcode)
        XCTAssertTrue(client.fragmentBuffer.isEmpty)
    }

    func testHeadlessNotificationService() {
        let service = NotificationService.shared
        if Bundle.main.bundleIdentifier == nil {
            XCTAssertFalse(service.isAvailable)
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
