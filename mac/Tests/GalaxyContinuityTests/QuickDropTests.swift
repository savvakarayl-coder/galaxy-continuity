#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class QuickDropXCTests: XCTestCase {

    func testCollisionRenaming() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalFile = tempDir.appendingPathComponent("document.pdf")
        FileManager.default.createFile(atPath: originalFile.path, contents: Data("v1".utf8))

        let firstCollision = QuickDropService.resolveCollision(in: tempDir, filename: "document.pdf")
        XCTAssertEqual(firstCollision.lastPathComponent, "document (1).pdf")

        FileManager.default.createFile(atPath: firstCollision.path, contents: Data("v2".utf8))
        let secondCollision = QuickDropService.resolveCollision(in: tempDir, filename: "document.pdf")
        XCTAssertEqual(secondCollision.lastPathComponent, "document (2).pdf")
    }

    func testCollisionRenamingWithoutExtension() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalFile = tempDir.appendingPathComponent("LICENSE")
        FileManager.default.createFile(atPath: originalFile.path, contents: Data("license".utf8))

        let collision = QuickDropService.resolveCollision(in: tempDir, filename: "LICENSE")
        XCTAssertEqual(collision.lastPathComponent, "LICENSE (1)")
    }

    func testFileAvailableMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_available",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            fileSize: 1048576,
            mimeType: "image/jpeg",
            sender: "MacBook Pro"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        XCTAssertEqual(decoded.type, "file_available")
        XCTAssertEqual(decoded.fileId, "test-uuid-1234")
        XCTAssertEqual(decoded.filename, "photo.jpg")
        XCTAssertEqual(decoded.fileSize, 1048576)
        XCTAssertEqual(decoded.mimeType, "image/jpeg")
        XCTAssertEqual(decoded.sender, "MacBook Pro")
    }

    func testFileProgressMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_progress",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            bytesTransferred: 524288,
            totalBytes: 1048576,
            percentage: 50.0,
            status: "transferring"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        XCTAssertEqual(decoded.type, "file_progress")
        XCTAssertEqual(decoded.percentage, 50.0)
        XCTAssertEqual(decoded.status, "transferring")
    }

    func testFileCompleteMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_complete",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            message: "File saved to ~/Downloads/GalaxyContinuity/photo.jpg",
            status: "success"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        XCTAssertEqual(decoded.type, "file_complete")
        XCTAssertEqual(decoded.status, "success")
        XCTAssertEqual(decoded.message, "File saved to ~/Downloads/GalaxyContinuity/photo.jpg")
    }
}
#endif

#if canImport(Testing)
@Suite("Quick Drop File Transfer Parity Tests")
struct QuickDropTests {

    @Test("Filename collision resolution increments (1), (2)")
    func testCollisionRenaming() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalFile = tempDir.appendingPathComponent("document.pdf")
        FileManager.default.createFile(atPath: originalFile.path, contents: Data("v1".utf8))

        let firstCollision = QuickDropService.resolveCollision(in: tempDir, filename: "document.pdf")
        #expect(firstCollision.lastPathComponent == "document (1).pdf")

        FileManager.default.createFile(atPath: firstCollision.path, contents: Data("v2".utf8))
        let secondCollision = QuickDropService.resolveCollision(in: tempDir, filename: "document.pdf")
        #expect(secondCollision.lastPathComponent == "document (2).pdf")
    }

    @Test("Collision resolution for extensionless files")
    func testCollisionRenamingWithoutExtension() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalFile = tempDir.appendingPathComponent("LICENSE")
        FileManager.default.createFile(atPath: originalFile.path, contents: Data("license".utf8))

        let collision = QuickDropService.resolveCollision(in: tempDir, filename: "LICENSE")
        #expect(collision.lastPathComponent == "LICENSE (1)")
    }

    @Test("file_available message roundtrip serialization")
    func testFileAvailableMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_available",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            fileSize: 1048576,
            mimeType: "image/jpeg",
            sender: "MacBook Pro"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "file_available")
        #expect(decoded.fileId == "test-uuid-1234")
        #expect(decoded.filename == "photo.jpg")
        #expect(decoded.fileSize == 1048576)
        #expect(decoded.mimeType == "image/jpeg")
        #expect(decoded.sender == "MacBook Pro")
    }

    @Test("file_progress message roundtrip serialization")
    func testFileProgressMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_progress",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            bytesTransferred: 524288,
            totalBytes: 1048576,
            percentage: 50.0,
            status: "transferring"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "file_progress")
        #expect(decoded.percentage == 50.0)
        #expect(decoded.status == "transferring")
    }

    @Test("file_complete message roundtrip serialization")
    func testFileCompleteMessageSerialization() throws {
        let msg = ContinuityMessage(
            type: "file_complete",
            fileId: "test-uuid-1234",
            filename: "photo.jpg",
            message: "File saved to ~/Downloads/GalaxyContinuity/photo.jpg",
            status: "success"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "file_complete")
        #expect(decoded.status == "success")
        #expect(decoded.message == "File saved to ~/Downloads/GalaxyContinuity/photo.jpg")
    }
}
#endif
