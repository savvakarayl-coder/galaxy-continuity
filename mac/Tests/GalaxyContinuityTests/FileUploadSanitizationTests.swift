#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class FileUploadSanitizationXCTests: XCTestCase {

    func testDirectoryTraversalSanitization() {
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("../outside.txt"), "outside.txt")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("../../../../etc/passwd"), "passwd")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("..%2F..%2Fsecrets.env"), "secrets.env")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("folder/nested/photo.png"), "photo.png")
    }

    func testHiddenAndDotSanitization() {
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("..").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename(".").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename(".hidden_file").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename(".zshrc").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("....").hasPrefix("Received_File_"))
    }

    func testEmptyAndWhitespaceSanitization() {
        XCTAssertTrue(ServerManager.sanitizeUploadFilename(nil).hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("   ").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("/").hasPrefix("Received_File_"))
        XCTAssertTrue(ServerManager.sanitizeUploadFilename("///").hasPrefix("Received_File_"))
    }

    func testWindowsBackslashSanitization() {
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("C:\\Users\\test\\doc.pdf"), "doc.pdf")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("nested\\folder\\image.jpg"), "image.jpg")
    }

    func testLegitimateFilenames() {
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("My Vacation (1).jpg"), "My Vacation (1).jpg")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("документ.txt"), "документ.txt")
        XCTAssertEqual(ServerManager.sanitizeUploadFilename("🚀_launch.zip"), "🚀_launch.zip")
    }
}
#endif

#if canImport(Testing)
@Suite("File Upload Path Traversal Sanitization Tests")
struct FileUploadSanitizationTests {

    @Test("Sanitize directory traversal attempts")
    func testDirectoryTraversalSanitization() {
        #expect(ServerManager.sanitizeUploadFilename("../outside.txt") == "outside.txt")
        #expect(ServerManager.sanitizeUploadFilename("../../../../etc/passwd") == "passwd")
        #expect(ServerManager.sanitizeUploadFilename("..%2F..%2Fsecrets.env") == "secrets.env")
        #expect(ServerManager.sanitizeUploadFilename("folder/nested/photo.png") == "photo.png")
    }

    @Test("Sanitize hidden files and dot-only strings to fallback")
    func testHiddenAndDotSanitization() {
        #expect(ServerManager.sanitizeUploadFilename("..").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename(".").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename(".hidden_file").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename(".zshrc").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename("....").hasPrefix("Received_File_"))
    }

    @Test("Sanitize empty, whitespace, and root slash strings to fallback")
    func testEmptyAndWhitespaceSanitization() {
        #expect(ServerManager.sanitizeUploadFilename(nil).hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename("").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename("   ").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename("/").hasPrefix("Received_File_"))
        #expect(ServerManager.sanitizeUploadFilename("///").hasPrefix("Received_File_"))
    }

    @Test("Sanitize Windows backslash paths")
    func testWindowsBackslashSanitization() {
        #expect(ServerManager.sanitizeUploadFilename("C:\\Users\\test\\doc.pdf") == "doc.pdf")
        #expect(ServerManager.sanitizeUploadFilename("nested\\folder\\image.jpg") == "image.jpg")
    }

    @Test("Preserve legitimate filenames including spaces and unicode")
    func testLegitimateFilenames() {
        #expect(ServerManager.sanitizeUploadFilename("report.pdf") == "report.pdf")
        #expect(ServerManager.sanitizeUploadFilename("My Vacation (1).jpg") == "My Vacation (1).jpg")
        #expect(ServerManager.sanitizeUploadFilename("документ.txt") == "документ.txt")
        #expect(ServerManager.sanitizeUploadFilename("🚀_launch.zip") == "🚀_launch.zip")
    }
}
#endif
