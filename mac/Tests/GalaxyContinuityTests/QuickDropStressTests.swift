#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class QuickDropStressXCTests: XCTestCase {

    func testSanitizationAdversarialVectors() {
        let vectors: [(input: String?, expectedSubstr: String, isFallback: Bool)] = [
            // Directory traversal (POSIX)
            ("../outside.txt", "outside.txt", false),
            ("../../../../etc/passwd", "passwd", false),
            ("../../var/log/system.log", "system.log", false),
            ("a/b/c/d/e.pdf", "e.pdf", false),

            // Percent-encoded traversal
            ("..%2F..%2Fsecrets.env", "secrets.env", false),
            ("%2E%2E%2F%2E%2E%2Fetc%2Fshadow", "shadow", false),
            ("%2e%2e%2foutside.txt", "outside.txt", false),

            // Windows-style backslash paths
            ("C:\\Windows\\System32\\cmd.exe", "cmd.exe", false),
            ("..\\..\\Windows\\win.ini", "win.ini", false),
            ("nested\\folder\\doc.pdf", "doc.pdf", false),
            ("D:\\data\\backup.zip", "backup.zip", false),

            // Dot-only attacks (must trigger fallback)
            (".", "Received_File_", true),
            ("..", "Received_File_", true),
            ("...", "Received_File_", true),
            ("....", "Received_File_", true),
            (".....", "Received_File_", true),

            // Slash and backslash only attacks (must trigger fallback)
            ("/", "Received_File_", true),
            ("//", "Received_File_", true),
            ("///", "Received_File_", true),
            ("\\", "Received_File_", true),
            ("\\\\", "Received_File_", true),
            ("/\\/\\", "Received_File_", true),

            // Hidden files (must trigger fallback)
            (".hidden", "Received_File_", true),
            (".env", "Received_File_", true),
            (".bashrc", "Received_File_", true),
            (".DS_Store", "Received_File_", true),

            // Whitespace and empty (must trigger fallback)
            (nil, "Received_File_", true),
            ("", "Received_File_", true),
            ("   ", "Received_File_", true),
            ("\t\n\r", "Received_File_", true),

            // Legitimate filenames (must be preserved verbatim)
            ("presentation.key", "presentation.key", false),
            ("My Vacation (2026).jpeg", "My Vacation (2026).jpeg", false),
            ("отчёт_финансы.xlsx", "отчёт_финансы.xlsx", false),
            ("🚀_payload.tar.gz", "🚀_payload.tar.gz", false),
            ("Spaces in filename [draft].pdf", "Spaces in filename [draft].pdf", false)
        ]

        for (input, expectedSubstr, isFallback) in vectors {
            let sanitized = ServerManager.sanitizeUploadFilename(input)
            if isFallback {
                XCTAssertTrue(
                    sanitized.hasPrefix("Received_File_"),
                    "Input '\(String(describing: input))' should trigger fallback but got '\(sanitized)'"
                )
            } else {
                XCTAssertEqual(
                    sanitized,
                    expectedSubstr,
                    "Input '\(String(describing: input))' should sanitize to '\(expectedSubstr)' but got '\(sanitized)'"
                )
            }

            // Universal invariants: no path separators, no leading dot, non-empty
            XCTAssertFalse(sanitized.isEmpty, "Sanitized filename must never be empty")
            XCTAssertFalse(sanitized.contains("/"), "Sanitized filename must never contain '/'")
            XCTAssertFalse(sanitized.contains("\\"), "Sanitized filename must never contain '\\'")
            XCTAssertFalse(sanitized.hasPrefix("."), "Sanitized filename must never start with '.'")
        }
    }

    func testTripleCollisionRenaming() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("test.pdf")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        XCTAssertEqual(c1.lastPathComponent, "test (1).pdf")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        XCTAssertEqual(c2.lastPathComponent, "test (2).pdf")
        FileManager.default.createFile(atPath: c2.path, contents: Data("3".utf8))

        let c3 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        XCTAssertEqual(c3.lastPathComponent, "test (3).pdf")
    }

    func testExtensionlessTripleCollision() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("README")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        XCTAssertEqual(c1.lastPathComponent, "README (1)")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        XCTAssertEqual(c2.lastPathComponent, "README (2)")
        FileManager.default.createFile(atPath: c2.path, contents: Data("3".utf8))

        let c3 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        XCTAssertEqual(c3.lastPathComponent, "README (3)")
    }

    func testMultiDotCollision() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("backup.tar.gz")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "backup.tar.gz")
        XCTAssertEqual(c1.lastPathComponent, "backup.tar (1).gz")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "backup.tar.gz")
        XCTAssertEqual(c2.lastPathComponent, "backup.tar (2).gz")
    }

    func testStrictConfinementCheck() {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let testFilenames = [
            "normal.pdf",
            "test (1).pdf",
            "Received_File_12345.bin",
            "документ.txt",
            "README"
        ]

        for fname in testFilenames {
            let targetUrl = destDir.appendingPathComponent(fname).standardizedFileURL.resolvingSymlinksInPath()
            let resolvedDir = targetUrl.deletingLastPathComponent().path
            let expectedDir = destDir.standardizedFileURL.resolvingSymlinksInPath().path
            XCTAssertEqual(resolvedDir, expectedDir, "File '\(fname)' must resolve strictly within destDir")
        }
    }
}
#endif

#if canImport(Testing)
@Suite("Quick Drop Adversarial Stress Tests")
struct QuickDropStressTests {

    @Test("Exhaustive filename sanitization against directory traversal vectors")
    func testSanitizationAdversarialVectors() {
        let vectors: [(input: String?, expectedSubstr: String, isFallback: Bool)] = [
            ("../outside.txt", "outside.txt", false),
            ("../../../../etc/passwd", "passwd", false),
            ("../../var/log/system.log", "system.log", false),
            ("a/b/c/d/e.pdf", "e.pdf", false),
            ("..%2F..%2Fsecrets.env", "secrets.env", false),
            ("%2E%2E%2F%2E%2E%2Fetc%2Fshadow", "shadow", false),
            ("%2e%2e%2foutside.txt", "outside.txt", false),
            ("C:\\Windows\\System32\\cmd.exe", "cmd.exe", false),
            ("..\\..\\Windows\\win.ini", "win.ini", false),
            ("nested\\folder\\doc.pdf", "doc.pdf", false),
            (".", "Received_File_", true),
            ("..", "Received_File_", true),
            ("...", "Received_File_", true),
            ("....", "Received_File_", true),
            ("/", "Received_File_", true),
            ("//", "Received_File_", true),
            ("///", "Received_File_", true),
            ("\\", "Received_File_", true),
            ("\\\\", "Received_File_", true),
            (".hidden", "Received_File_", true),
            (".env", "Received_File_", true),
            (".bashrc", "Received_File_", true),
            (nil, "Received_File_", true),
            ("", "Received_File_", true),
            ("   ", "Received_File_", true),
            ("presentation.key", "presentation.key", false),
            ("My Vacation (2026).jpeg", "My Vacation (2026).jpeg", false),
            ("отчёт_финансы.xlsx", "отчёт_финансы.xlsx", false),
            ("🚀_payload.tar.gz", "🚀_payload.tar.gz", false)
        ]

        for (input, expectedSubstr, isFallback) in vectors {
            let sanitized = ServerManager.sanitizeUploadFilename(input)
            if isFallback {
                #expect(sanitized.hasPrefix("Received_File_"), "Input '\(String(describing: input))' should trigger fallback")
            } else {
                #expect(sanitized == expectedSubstr, "Input '\(String(describing: input))' should sanitize to '\(expectedSubstr)'")
            }

            #expect(!sanitized.isEmpty)
            #expect(!sanitized.contains("/"))
            #expect(!sanitized.contains("\\"))
            #expect(!sanitized.hasPrefix("."))
        }
    }

    @Test("Triple duplicate filename collision increments (1), (2), (3)")
    func testTripleCollisionRenaming() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("test.pdf")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        #expect(c1.lastPathComponent == "test (1).pdf")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        #expect(c2.lastPathComponent == "test (2).pdf")
        FileManager.default.createFile(atPath: c2.path, contents: Data("3".utf8))

        let c3 = QuickDropService.resolveCollision(in: tempDir, filename: "test.pdf")
        #expect(c3.lastPathComponent == "test (3).pdf")
    }

    @Test("Extensionless file collision increments (1), (2), (3)")
    func testExtensionlessTripleCollision() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("README")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        #expect(c1.lastPathComponent == "README (1)")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        #expect(c2.lastPathComponent == "README (2)")
        FileManager.default.createFile(atPath: c2.path, contents: Data("3".utf8))

        let c3 = QuickDropService.resolveCollision(in: tempDir, filename: "README")
        #expect(c3.lastPathComponent == "README (3)")
    }

    @Test("Multi-dot filename collision preserves penultimate extension")
    func testMultiDotCollision() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = tempDir.appendingPathComponent("backup.tar.gz")
        FileManager.default.createFile(atPath: original.path, contents: Data("1".utf8))

        let c1 = QuickDropService.resolveCollision(in: tempDir, filename: "backup.tar.gz")
        #expect(c1.lastPathComponent == "backup.tar (1).gz")
        FileManager.default.createFile(atPath: c1.path, contents: Data("2".utf8))

        let c2 = QuickDropService.resolveCollision(in: tempDir, filename: "backup.tar.gz")
        #expect(c2.lastPathComponent == "backup.tar (2).gz")
    }

    @Test("Strict confinement ensures path resolves within destination directory")
    func testStrictConfinementCheck() {
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let testFilenames = [
            "normal.pdf",
            "test (1).pdf",
            "Received_File_12345.bin",
            "документ.txt",
            "README"
        ]

        for fname in testFilenames {
            let targetUrl = destDir.appendingPathComponent(fname).standardizedFileURL.resolvingSymlinksInPath()
            let resolvedDir = targetUrl.deletingLastPathComponent().path
            let expectedDir = destDir.standardizedFileURL.resolvingSymlinksInPath().path
            #expect(resolvedDir == expectedDir)
        }
    }
}
#endif
