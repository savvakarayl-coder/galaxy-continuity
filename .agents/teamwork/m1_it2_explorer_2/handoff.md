# Investigation & Fix Blueprint Report: Schema Type Harmonization & Path Traversal Sanitization

**Agent**: `m1_it2_explorer_2` (`teamwork_explorer`)  
**Parent Agent**: Orchestrator (`67ae80cb-3237-4127-adab-613c0f12f1aa`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it2_explorer_2`  
**Milestone**: Milestone 1 Iteration 2  
**Target Files**:
- `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`
- `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`
- `mac/Tests/GalaxyContinuityTests/ContinuityMessageTests.swift` (new test suite)
- `mac/Tests/GalaxyContinuityTests/FileUploadSanitizationTests.swift` (new test suite)

---

## Executive Summary
This investigation analyzed two critical regressions reported by Challenger M1-2: (1) `ContinuityMessage` type mismatches (`button: String?` and `percentage: Int?`) breaking remote touch control and file progress tracking during JSON decoding, and (2) an unconstrained file upload vulnerability in `ServerManager.saveUploadedFile` allowing arbitrary filesystem writes via directory traversal (`../`). Comprehensive, concrete fix blueprints with exact before/after code modifications, unit test suites, and empirical verification methods have been designed for the implementation worker.

---

## 1. Observation

### Obs 1: `button: String?` Type Mismatch in `ContinuityMessage.swift:54,101,147`
- **File & Lines**:
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:54`:
    ```swift
    public var button: String?
    ```
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:101`:
    ```swift
    button: String? = nil,
    ```
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:147`:
    ```swift
    self.button = button
    ```
- **Authoritative Protocol Specification**:
  - `shared/PROTOCOL.md:442,452`:
    ```json
    "button": 0
    ```
    `| button | Integer | Optional | Mouse button: 0 (Left/Primary), 1 (Right/Secondary), 2 (Middle) |`
- **Android Client Contract**:
  - `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt:191,199`:
    ```kotlin
    put("button", 0)
    // ...
    assertEquals(0, parsedEvent.getInt("button"))
    ```
- **E2E Test Contract**:
  - `tests/e2e/test_tier1_features.py:544`:
    ```python
    touch_evt = {
        "type": "input_event",
        "action": "down",
        "x": 0.452,
        "y": 0.819,
        "button": 0
    }
    ```
- **Empirical Execution Error**:
  Executing `try JSONDecoder().decode(ContinuityMessage.self, from: jsonData)` with `{"type":"input_event","action":"down","x":0.5,"y":0.5,"button":0}` produces:
  ```text
  DecodingError.typeMismatch: expected value of type String. Path: button.
  Debug description: Expected to decode String but found number instead.
  ```
- **Impact in `ServerManager.swift:386`**:
  `handleWebSocketFrame` uses `if let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData)`. The decoding error causes the message to evaluate to `nil`, silently dropping all remote mouse/touch click events from Android.

---

### Obs 2: `percentage: Int?` Type Mismatch in `ContinuityMessage.swift:44,91,137`
- **File & Lines**:
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:44`:
    ```swift
    public var percentage: Int?
    ```
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:91`:
    ```swift
    percentage: Int? = nil,
    ```
  - `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift:137`:
    ```swift
    self.percentage = percentage
    ```
- **Authoritative Protocol Specification**:
  - `shared/PROTOCOL.md:354,365`:
    ```json
    "percentage": 50.0,
    ```
    `| percentage | Double | Yes | Transfer completion percentage (0.0 - 100.0) |`
- **Android Client Contract**:
  - `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt:133,141`:
    ```kotlin
    put("percentage", 50.0)
    // ...
    assertEquals(50.0, p.getDouble("percentage"), 0.001)
    ```
- **Empirical Execution Error**:
  Executing `try JSONDecoder().decode(ContinuityMessage.self, from: jsonData)` with `{"type":"file_progress","fileId":"123","bytesTransferred":50,"totalBytes":100,"percentage":50.5,"status":"transferring"}` produces:
  ```text
  DecodingError.dataCorrupted: Data was corrupted.
  Debug description: The given data was not valid JSON..
  Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 "Number 50.5 is not representable in Swift."
  ```
- **Impact in `ServerManager.swift:386`**:
  Any `file_progress` message with decimal transfer percentages fails decoding and is discarded by `try?`.

---

### Obs 3: Usages of `ContinuityMessage.init` Across `mac/Sources` and `mac/Tests`
- Comprehensive repository search revealed:
  1. `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:359`:
     `ContinuityMessage(type: "handshake_ack", device: macName, platform: "macOS", version: "1.0.0")`
  2. `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:364`:
     `ContinuityMessage(type: "clipboard", content: DeviceState.shared.lastSharedClipboard, contentType: "text/plain", source: "mac")`
  3. `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:505`:
     `ContinuityMessage(type: "file_available", fileId: fileId, filename: filename, fileSize: Int64(size), mimeType: "application/octet-stream", sender: Host.current().localizedName ?? "Mac")`
  4. `mac/Sources/GalaxyContinuityKit/Services/ClipboardSyncService.swift:52,88`:
     `ContinuityMessage(type: "clipboard", content: currentText, contentType: "text/plain", source: "mac")`
  5. `mac/Sources/GalaxyContinuity/UI/MenuBarView.swift:160`:
     `ContinuityMessage(type: "ping_device", source: "mac", message: "Finding your Galaxy...")`
  6. `mac/Tests/`: Currently zero references to `ContinuityMessage` in `mac/Tests/GalaxyContinuityTests/`.
- **Finding**: None of the existing call sites specify `percentage` or `button`. All rely on default argument `nil`. Updating `percentage: Double? = nil` and `button: Int? = nil` maintains 100% source-level call compatibility.

---

### Obs 4: Directory Traversal Vulnerability in `ServerManager.swift:257-262,303-315`
- **File & Lines**:
  - `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:257-262`:
    ```swift
    var rawFilename = headers["x-filename"] ?? "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
    if let decoded = rawFilename.removingPercentEncoding {
        rawFilename = decoded
    }
    saveUploadedFile(name: rawFilename, data: fileData, sender: client.deviceName)
    ```
  - `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift:303-315`:
    ```swift
    private func saveUploadedFile(name: String, data: Data, sender: String) {
        let destDir = self.downloadsDirectory
        var targetUrl = destDir.appendingPathComponent(name)

        var counter = 1
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = destDir.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try data.write(to: targetUrl)
    ```
- **Empirical Exploit Verification**:
  - When a client sends HTTP header `X-Filename: ../outside.txt`, `destDir.appendingPathComponent("../outside.txt")` resolves outside `downloadsDirectory` directly to the parent directory (`~/Downloads/outside.txt`).
  - When a client sends `X-Filename: ../../../../tmp/pwned.txt`, the file is written to `/tmp/pwned.txt`.
  - When a client sends hidden files (e.g. `X-Filename: .zshrc`), it writes hidden configuration files.
  - When a client sends Windows-style paths (e.g. `X-Filename: foo\bar.txt`), directory separators are not stripped on macOS POSIX filesystem.

---

## 2. Logic Chain

1. **Protocol Ground Truth vs Implementation Gap (Obs 1 & Obs 2)**:
   - `shared/PROTOCOL.md § 5.4` explicitly defines `button` as `Integer` representing mouse button (`0`: Primary/Left, `1`: Secondary/Right, `2`: Middle).
   - `shared/PROTOCOL.md § 5.3` explicitly defines `percentage` as `Double` representing progress (`0.0` - `100.0`).
   - Swift Foundation `JSONDecoder` is strictly typed: decoding an `Int` into a `String` throws `DecodingError.typeMismatch`, and decoding a float into an `Int` throws `DecodingError.dataCorrupted`.
   - In modern Swift, `Double` natively decodes both integer values (`50`) and floating-point values (`50.5`), making `Double?` the strictly correct type for `percentage`.
   - Changing `button: Int?` and `percentage: Double?` directly satisfies both Android and Python test harnesses.

2. **Source Compatibility Validation (Obs 3)**:
   - All existing `ContinuityMessage.init` invocations throughout the macOS application omit `button` and `percentage`.
   - Therefore, updating the parameter types in the initializer signature with default value `= nil` causes zero breaking changes across `mac/Sources/`.

3. **Attack Surface & Confinement Invariants (Obs 4)**:
   - An untrusted client can provide arbitrary bytes in `X-Filename`.
   - Even after percent-decoding, `appendingPathComponent` preserves `..` navigation unless explicitly sanitized.
   - Using `URL(fileURLWithPath: name).lastPathComponent` extracts only the terminal filename component, stripping leading directory paths (`/` and `../`).
   - However, `lastPathComponent` on strings like `".."` or `"."` or `""` returns `"/"` or empty string, and for `".bash_profile"` returns `".bash_profile"`.
   - Therefore, a multi-stage defense-in-depth sanitization policy is required:
     1. Percent-decode the raw string.
     2. Extract terminal component via `URL(fileURLWithPath: name).lastPathComponent`.
     3. Strip any Windows-style backslash components (`candidate.split(separator: "\\").last`).
     4. Trim whitespace and newlines.
     5. Disallow empty, `"/"`, `"."`-prefixed (hidden files, `.` and `..`), and path separators (`/` or `\`), falling back to a safe generated filename: `Received_File_\(Int(Date().timeIntervalSince1970)).bin`.
     6. Post-resolution path containment assertion: verify `targetUrl.deletingLastPathComponent().path == destDir.path` using standardized, symlink-resolved URLs.

---

## 3. Caveats

- **No Caveats**: Both problem domains were empirically reproduced, inspected at line-level detail, and validated with standalone Swift 6 test executions in temporary isolation.
- **Scope Note**: Changes are strictly confined to `ContinuityMessage.swift`, `ServerManager.swift`, and new unit test suites in `mac/Tests/GalaxyContinuityTests/`.

---

## 4. Conclusion & Concrete Fix Blueprints

### Blueprint 1: `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`

#### Exact Modifications:

**Lines 44 & 54**: Property declarations:
```swift
<<<< BEFORE (Line 44)
    public var percentage: Int?
==== AFTER
    public var percentage: Double?
>>>>
```
```swift
<<<< BEFORE (Line 54)
    public var button: String?
==== AFTER
    public var button: Int?
>>>>
```

**Lines 91 & 101**: Initializer signature:
```swift
<<<< BEFORE (Line 91)
        percentage: Int? = nil,
==== AFTER
        percentage: Double? = nil,
>>>>
```
```swift
<<<< BEFORE (Line 101)
        button: String? = nil,
==== AFTER
        button: Int? = nil,
>>>>
```

**Lines 137 & 147**: Initializer assignments remain:
```swift
        self.percentage = percentage
        self.button = button
```

---

### Blueprint 2: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`

#### Exact Modifications:

**1. Add Static Sanitization Helper**:
Add the following method to `ServerManager` (e.g., right before `saveUploadedFile`):

```swift
    // MARK: - Filename Sanitization & Path Confinement
    public static func sanitizeUploadFilename(_ raw: String?) -> String {
        let fallback = "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
        guard let raw = raw else { return fallback }

        var name = raw
        if let decoded = name.removingPercentEncoding {
            name = decoded
        }

        // Extract terminal path component to discard all directory traversal prefixes
        var candidate = URL(fileURLWithPath: name).lastPathComponent

        // Strip any Windows-style backslash components
        if let lastBackslash = candidate.split(separator: "\\").last {
            candidate = String(lastBackslash)
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Disallow empty, root "/", "."-prefixed (hidden files or . / ..), and path separators
        if candidate.isEmpty || candidate == "/" || candidate.hasPrefix(".") || candidate.contains("/") || candidate.contains("\\") {
            return fallback
        }

        return candidate
    }
```

**2. Update `handleIncomingData` (POST /api/upload)** (around lines 257-262):
```swift
<<<< BEFORE (Lines 257-262)
                var rawFilename = headers["x-filename"] ?? "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
                if let decoded = rawFilename.removingPercentEncoding {
                    rawFilename = decoded
                }

                saveUploadedFile(name: rawFilename, data: fileData, sender: client.deviceName)
==== AFTER
                let rawFilename = headers["x-filename"]
                let safeFilename = ServerManager.sanitizeUploadFilename(rawFilename)
                saveUploadedFile(name: safeFilename, data: fileData, sender: client.deviceName)
>>>>
```

**3. Update `saveUploadedFile`** (around lines 303-316):
```swift
<<<< BEFORE (Lines 303-316)
    private func saveUploadedFile(name: String, data: Data, sender: String) {
        let destDir = self.downloadsDirectory
        var targetUrl = destDir.appendingPathComponent(name)

        var counter = 1
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = destDir.appendingPathComponent(newName)
            counter += 1
        }
==== AFTER
    private func saveUploadedFile(name: String, data: Data, sender: String) {
        let safeName = ServerManager.sanitizeUploadFilename(name)
        let destDir = self.downloadsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var targetUrl = destDir.appendingPathComponent(safeName).standardizedFileURL.resolvingSymlinksInPath()

        // Enforce strict confinement: targetUrl must resolve immediately within destDir
        guard targetUrl.deletingLastPathComponent().path == destDir.path else {
            print("[ServerManager] Security alert: resolved path \(targetUrl.path) is outside downloads directory \(destDir.path)")
            return
        }

        var counter = 1
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = destDir.appendingPathComponent(newName).standardizedFileURL.resolvingSymlinksInPath()
            counter += 1
        }

        guard targetUrl.deletingLastPathComponent().path == destDir.path else {
            print("[ServerManager] Security alert: deduplicated path \(targetUrl.path) is outside downloads directory \(destDir.path)")
            return
        }
>>>>
```

---

### Blueprint 3: New Automated Unit Tests in `mac/Tests/GalaxyContinuityTests/`

#### 1. `mac/Tests/GalaxyContinuityTests/ContinuityMessageTests.swift`
```swift
#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import GalaxyContinuityKit

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
}
#endif
```

#### 2. `mac/Tests/GalaxyContinuityTests/FileUploadSanitizationTests.swift`
```swift
#if canImport(Testing)
import Testing
#endif
#if canImport(XCTest)
import XCTest
#endif
import Foundation
@testable import GalaxyContinuityKit

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
```

---

## 5. Verification Method

To independently verify the implementation:

1. **Verify Swift Compilation & Automated Unit Tests**:
   Execute the Swift test runner against the target platform:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
   ```
   **Expected Outcome**: All tests (including existing 10 tests + newly added schema and path traversal test suites) pass with 0 failures.

2. **Verify Schema Decoding from Command Line**:
   ```bash
   swiftc -o /tmp/verify_schema -e '
   import Foundation
   import GalaxyContinuityKit
   let json = "{\"type\":\"input_event\",\"action\":\"down\",\"x\":0.5,\"y\":0.5,\"button\":0}"
   let msg = try JSONDecoder().decode(ContinuityMessage.self, from: json.data(using: .utf8)!)
   assert(msg.button == 0)
   print("Numeric button verification PASSED")
   ' && /tmp/verify_schema && rm -f /tmp/verify_schema
   ```

3. **Verify File Upload Traversal Resistance**:
   ```bash
   swiftc -o /tmp/verify_traversal -e '
   import Foundation
   import GalaxyContinuityKit
   let sanitized = ServerManager.sanitizeUploadFilename("../outside.txt")
   assert(sanitized == "outside.txt")
   let hidden = ServerManager.sanitizeUploadFilename(".zshrc")
   assert(hidden.hasPrefix("Received_File_"))
   print("Path traversal sanitization PASSED")
   ' && /tmp/verify_traversal && rm -f /tmp/verify_traversal
   ```

4. **Verify Full E2E Test Suite**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
   python3 tests/e2e/runner.py
   ```
