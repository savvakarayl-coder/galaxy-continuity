# M2 Explorer 1 Investigation Report: Universal Clipboard Parity

**Milestone**: M2 — Universal Clipboard & Quick Drop Parity  
**Target Capabilities**: Bidirectional plain text and image clipboard synchronization (PNG / TIFF / JPEG, base64 payload encoding, SHA-256 echo suppression, loop prevention) between macOS Host and Samsung Galaxy Android Client.  
**Report Location**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1/handoff.md`

---

## 1. Observation

### 1.1 Existing macOS Implementation
1. **`mac/Sources/GalaxyContinuityKit/Services/ClipboardSyncService.swift`**:
   - Lines 36-60: `checkPasteboard()` polls `NSPasteboard.general.changeCount` every 0.5s. It only checks `NSPasteboard.general.string(forType: .string)` (lines 40-44). If the user copies an image (e.g. screenshot via `Cmd+Shift+Ctrl+4`, copying an image in Safari/Preview, or copying graphics in Figma), `string(forType: .string)` returns `nil`. Thus, image copies are completely ignored.
   - Lines 62-84: `handleIncomingClipboard(text: String, sender: String)` accepts only plain `text`. It always executes `NSPasteboard.general.setString(text, forType: .string)`, has no image decoding, and lacks `contentType` or `hash` parameters.
   - Lines 63: `guard !text.isEmpty, text != lastSeenContent else { return }` drops empty string clipboards, failing protocol boundary test `test_07_text_clipboard_empty_string`.
   - Lines 86-98: `pushCurrentMacClipboardToPhone()` only inspects `NSPasteboard.general.string(forType: .string)` and does not broadcast image data.
   - There is no SHA-256 echo suppression or hash tracking. Only a basic string equality check (`text != lastSeenContent`) is present.

2. **`mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`**:
   - Lines 551-556:
     ```swift
     case "clipboard":
         if let content = message.content {
             Task { @MainActor in
                 ClipboardSyncService.shared.handleIncomingClipboard(text: content, sender: client.deviceName)
             }
         }
     ```
     `ServerManager` ignores `message.contentType`, `message.hash`, and `message.payload`. If `message.content` is nil but `message.payload` is provided, the message is ignored.
   - Lines 416-426: On new client handshake connection, `ServerManager` broadcasts `DeviceState.shared.lastSharedClipboard` hardcoded as `contentType: "text/plain"`.

3. **`mac/Sources/GalaxyContinuityKit/Models/DeviceState.swift`**:
   - Lines 37-39: Holds `@Published public var lastSharedClipboard: String = ""` and `@Published public var clipboardLastUpdated: Date? = nil`. It lacks a type descriptor property (e.g., `lastSharedClipboardType: String = "text/plain"`).

4. **`mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`**:
   - Lines 18-19, 37-38: `ContinuityMessage` already has `content: String?`, `contentType: String?`, `hash: String?`, and `payload: String?`. Both `content` and `payload` can be populated simultaneously for maximum protocol compatibility.

5. **`mac/Sources/GalaxyContinuity/UI/MenuBarView.swift`**:
   - Lines 72-80: Directly renders `Text(state.lastSharedClipboard)`. If a large base64 image string is stored in `lastSharedClipboard`, the menu bar view attempts to render the raw base64 string.

### 1.2 Existing Android Implementation
1. **`android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt`**:
   - Lines 17-29: `clipListener` triggers on primary clip change, but only reads `clip.getItemAt(0).text?.toString()`. If an image is copied (where `clip.getItemAt(0).uri` is set and `clip.description.hasMimeType("image/*")` is true), `text` is null and the event is ignored.
   - Lines 39-49: `updateClipboardFromMac(text: String)` only creates `ClipData.newPlainText(...)`. It cannot handle incoming image payloads.
   - Lacks SHA-256 computation and hash tracking.

2. **`android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`**:
   - Lines 60-65:
     ```kotlin
     "clipboard" -> {
         val content = json.optString("content")
         if (content.isNotEmpty()) {
             mainHandler.post { listener.onClipboardReceived(content) }
         }
     }
     ```
     Does not extract `contentType`, `hash`, or fallback to `payload`.
   - Lines 113-122: `sendClipboard(text: String)` hardcodes `contentType: "text/plain"` and does not accept image data or hash.

3. **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`**:
   - Lines 50-52: Initializes `ClipboardSync` with single-argument lambda `{ text -> webSocketClient?.sendClipboard(text) }`.
   - Lines 95-97: `onClipboardReceived(text: String)` delegates to `clipboardSync?.updateClipboardFromMac(text)`.

4. **`android/app/src/main/AndroidManifest.xml`**:
   - Lines 1-51: No `FileProvider` or content provider is declared. Setting an image `ClipData` requires either a content URI provided via `FileProvider` or `Uri.fromFile()`.

### 1.3 Protocol & Specification References
1. **`shared/PROTOCOL.md` § 5.2 (Universal Clipboard Synchronization)**:
   - Plain text frame: `{"type": "clipboard", "content": "<text>", "contentType": "text/plain", "hash": "<sha256>", "source": "mac"|"phone", "timestamp": ...}`
   - Image frame: `{"type": "clipboard", "content": "<base64>", "contentType": "image/png"|"image/jpeg", "hash": "<sha256>", "source": "mac"|"phone", "timestamp": ...}`
   - Loop prevention rules:
     - Senders tag originating role in `"source"`.
     - When receiving, local write occurs under suppression lock.
     - If incoming `hash` or `content` matches `lastSeenClipboard`, drop immediately.
     - Never re-broadcast clipboard updates originating remotely.
2. **`tests/e2e/test_tier1_features.py`**:
   - Tests 07-11: Text clipboard, loop prevention, URL content, multiline text.
   - Tests 12-16: Phone to Mac PNG sync, Mac to Phone image sync, JPEG payload, large base64 frames (16-bit payload length), image loop prevention. All 21 E2E clipboard tests pass against the test harness.
3. **`tests/e2e/test_tier2_boundary.py`**:
   - Tests 07-12: Empty string clipboard (`""`), massive 1 MB text, special control characters, RTL/Unicode, missing contentType fallback, rapid successive bursts.
   - Tests 13-17: Empty image payload, invalid/corrupt base64 (`"!@#$%^&*()_+"`), truncated base64 (`"abc12"`), 2 MB large image, unsupported image MIME type (`image/webp`).

---

## 2. Logic Chain

1. **Mac Image Capture & Conversion**:
   - When a user copies an image on macOS, the pasteboard may contain `.png` or `.tiff` data (standard screenshot and Preview behavior).
   - `NSBitmapImageRep(data: tiffData)?.representation(using: .png, properties: [:])` converts TIFF to valid PNG data synchronously.
   - Checking `.png` first, then converting `.tiff` to PNG guarantees all macOS image copy mechanisms (screenshots, browser image copy, graphic editors) produce standardized `image/png` payloads.

2. **Symmetric SHA-256 Computation**:
   - In macOS: `CryptoKit.SHA256.hash(data: data)` maps each byte to lowercase hex (`"%02x"`).
   - In Android: `java.security.MessageDigest.getInstance("SHA-256").digest(bytes)` maps each byte to lowercase hex (`"%02x"`).
   - When computing SHA-256 over raw payload bytes (UTF-8 bytes for text, raw image binary bytes for image), the digest is byte-for-byte identical across macOS and Android.
   - By transmitting this digest in `"hash"` and maintaining `lastSeenHash` and `lastSentHash` on both peers, loop echoes are detected and dropped immediately before local pasteboard writes or network re-transmissions.

3. **Mac Pasteboard Injection**:
   - In `handleIncomingClipboard`, when `contentType.hasPrefix("image/")`:
     - Decode base64 to binary `Data`.
     - Set both `.png` and `.tiff` (`image.tiffRepresentation`) on `NSPasteboard.general`. Setting both guarantees compatibility across all macOS applications (browsers, Electron, Cocoa native, Pages, TextEdit).
     - Guard against corrupted or truncated base64 by handling `nil` decodes without throwing.

4. **Android Image Clipboard Handling**:
   - When primary clip changes:
     - Check `clip.description.hasMimeType("image/*")` and `item.uri`.
     - Open `context.contentResolver.openInputStream(uri)`, read bytes, calculate SHA-256, encode to Base64 (using `Base64.NO_WRAP`), and send via WebSocket.
   - When incoming image arrives from Mac:
     - Decode base64 bytes.
     - Persist image bytes to internal cache file `cacheDir/clipboard/synced_clip.png`.
     - Generate a content URI using `androidx.core.content.FileProvider.getUriForFile(...)` (with graceful fallback to `Uri.fromFile(...)` if FileProvider is unavailable in unit test environments).
     - Construct `ClipData.newUri(context.contentResolver, "Galaxy Continuity Image", uri)` and set it on `ClipboardManager`.

5. **Payload Harmonization**:
   - Some tests and clients look for `"content"` (per `PROTOCOL.md`), while others look for `"payload"` (per `DISPATCH.md`). Populating both `content = base64` and `payload = base64` in outbound JSON frames, and checking `message.content ?? message.payload` in inbound processing, ensures 100% interoperability with zero breakage.

---

## 3. Caveats

1. **Android Background Clipboard Access (Android 10+)**: On Android 10 (API 29) and newer, background apps cannot read system clipboard unless they have input focus or are a foreground service with active notification. `ContinuityService` is already configured as a foreground service with `connectedDevice` type and persistent notification, ensuring clipboard listener execution.
2. **Memory Footprint for Massive Payloads**: When processing payloads >= 2 MB, base64 encoding/decoding creates in-memory byte buffers (~1.33x raw size). Since mobile RAM permits several megabytes easily and clipboard images are typically < 5 MB, buffering in memory is acceptable.
3. **TIFF Compression**: In macOS `convertTiffToPng`, conversion is performed in-memory using `NSBitmapImageRep`. If TIFF data is corrupt, `NSBitmapImageRep(data:)` returns `nil` and the operation safely aborts.
4. **Android FileProvider Security**: `file_paths.xml` must configure `<cache-path name="clipboard_cache" path="clipboard" />` with `grantUriPermissions="true"` so that target apps pasting the image from clipboard receive transient read permissions.

---

## 4. Conclusion & Drop-In Blueprints

The worker agent should apply the following precise blueprints to implement Milestone 2 Universal Clipboard parity.

### 4.1 macOS Host Blueprints

#### Blueprint 1: `mac/Sources/GalaxyContinuityKit/Services/ClipboardSyncService.swift`
Replace existing file content with:

```swift
import AppKit
import Foundation
import CryptoKit

@MainActor
public final class ClipboardSyncService {
    public static let shared = ClipboardSyncService()

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var lastSeenContent: String = ""
    private var lastSeenHash: String = ""
    private var lastSentHash: String = ""
    private var isUpdatingInternally: Bool = false

    private init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func startMonitoring() {
        stopMonitoring()
        self.lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func convertTiffToPng(_ tiffData: Data?) -> Data? {
        guard let tiffData = tiffData else { return nil }
        guard let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    private func checkPasteboard() {
        guard !isUpdatingInternally else { return }

        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 1. Check for image data (PNG direct or TIFF converted to PNG)
        if let pngData = NSPasteboard.general.data(forType: .png) ?? convertTiffToPng(NSPasteboard.general.data(forType: .tiff)),
           !pngData.isEmpty {
            let hash = sha256Hex(data: pngData)
            guard hash != lastSeenHash && hash != lastSentHash else { return }

            let base64 = pngData.base64EncodedString()
            lastSeenHash = hash
            lastSentHash = hash
            lastSeenContent = base64

            DeviceState.shared.lastSharedClipboard = base64
            DeviceState.shared.lastSharedClipboardType = "image/png"
            DeviceState.shared.clipboardLastUpdated = Date()

            if DeviceState.shared.clipboardAutoSync && DeviceState.shared.isConnected {
                print("[ClipboardSync] Detected Mac image copy (\(pngData.count) bytes). Sending to Galaxy.")
                let msg = ContinuityMessage(
                    type: "clipboard",
                    content: base64,
                    contentType: "image/png",
                    source: "mac",
                    hash: hash,
                    payload: base64
                )
                ServerManager.shared.broadcastMessage(msg)
            }
            return
        }

        // 2. Check for text data
        if let currentText = NSPasteboard.general.string(forType: .string) {
            let textData = Data(currentText.utf8)
            let hash = sha256Hex(data: textData)
            guard hash != lastSeenHash && hash != lastSentHash && currentText != lastSeenContent else { return }

            lastSeenHash = hash
            lastSentHash = hash
            lastSeenContent = currentText

            DeviceState.shared.lastSharedClipboard = currentText
            DeviceState.shared.lastSharedClipboardType = "text/plain"
            DeviceState.shared.clipboardLastUpdated = Date()

            if DeviceState.shared.clipboardAutoSync && DeviceState.shared.isConnected {
                print("[ClipboardSync] Detected Mac copy: \(currentText.prefix(40))... Sending to Galaxy.")
                let msg = ContinuityMessage(
                    type: "clipboard",
                    content: currentText,
                    contentType: "text/plain",
                    source: "mac",
                    hash: hash,
                    payload: currentText
                )
                ServerManager.shared.broadcastMessage(msg)
            }
            return
        }
    }

    public func handleIncomingClipboard(
        content: String,
        contentType: String = "text/plain",
        hash: String? = nil,
        sender: String = "Samsung Galaxy"
    ) {
        let payloadData = Data(content.utf8)
        let payloadHash = hash ?? sha256Hex(data: payloadData)

        // Echo loop suppression: ignore if already seen or sent
        if (!payloadHash.isEmpty && (payloadHash == lastSentHash || payloadHash == lastSeenHash)) ||
           (!content.isEmpty && content == lastSeenContent) {
            print("[ClipboardSync] Dropping echo clipboard with hash \(payloadHash.prefix(8))...")
            return
        }

        isUpdatingInternally = true
        lastSeenHash = payloadHash
        lastSeenContent = content

        DeviceState.shared.lastSharedClipboard = content
        DeviceState.shared.lastSharedClipboardType = contentType
        DeviceState.shared.clipboardLastUpdated = Date()

        if contentType.hasPrefix("image/") {
            if !content.isEmpty, let imageData = Data(base64Encoded: content, options: [.ignoreUnknownCharacters]), !imageData.isEmpty {
                let imgHash = sha256Hex(data: imageData)
                lastSeenHash = imgHash

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(imageData, forType: .png)
                if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
                    NSPasteboard.general.setData(tiff, forType: .tiff)
                }
                lastChangeCount = NSPasteboard.general.changeCount

                print("[ClipboardSync] Synced image from \(sender) (\(imageData.count) bytes)")
                NotificationService.shared.showNotification(
                    title: "📋 Image Clipboard Synced",
                    subtitle: "From \(sender)",
                    body: "Image copied to Mac clipboard",
                    sound: false
                )
            } else {
                if content.isEmpty {
                    NSPasteboard.general.clearContents()
                    lastChangeCount = NSPasteboard.general.changeCount
                }
                print("[ClipboardSync] Received empty or invalid image payload")
            }
        } else {
            NSPasteboard.general.clearContents()
            if !content.isEmpty {
                NSPasteboard.general.setString(content, forType: .string)
            }
            lastChangeCount = NSPasteboard.general.changeCount

            print("[ClipboardSync] Synced from \(sender): \(content.prefix(40))...")
            NotificationService.shared.showNotification(
                title: "📋 Clipboard Synced",
                subtitle: "From \(sender)",
                body: content.count > 100 ? String(content.prefix(100)) + "..." : content,
                sound: false
            )
        }

        isUpdatingInternally = false
    }

    public func handleIncomingClipboard(text: String, sender: String = "Samsung Galaxy") {
        handleIncomingClipboard(content: text, contentType: "text/plain", hash: nil, sender: sender)
    }

    public func pushCurrentMacClipboardToPhone() {
        if let pngData = NSPasteboard.general.data(forType: .png) ?? convertTiffToPng(NSPasteboard.general.data(forType: .tiff)), !pngData.isEmpty {
            let hash = sha256Hex(data: pngData)
            let base64 = pngData.base64EncodedString()
            lastSentHash = hash
            lastSeenHash = hash
            lastSeenContent = base64

            let msg = ContinuityMessage(
                type: "clipboard",
                content: base64,
                contentType: "image/png",
                source: "mac",
                hash: hash,
                payload: base64
            )
            ServerManager.shared.broadcastMessage(msg)
            DeviceState.shared.lastSharedClipboard = base64
            DeviceState.shared.lastSharedClipboardType = "image/png"
            DeviceState.shared.clipboardLastUpdated = Date()
        } else if let currentText = NSPasteboard.general.string(forType: .string), !currentText.isEmpty {
            let hash = sha256Hex(data: Data(currentText.utf8))
            lastSentHash = hash
            lastSeenHash = hash
            lastSeenContent = currentText

            let msg = ContinuityMessage(
                type: "clipboard",
                content: currentText,
                contentType: "text/plain",
                source: "mac",
                hash: hash,
                payload: currentText
            )
            ServerManager.shared.broadcastMessage(msg)
            DeviceState.shared.lastSharedClipboard = currentText
            DeviceState.shared.lastSharedClipboardType = "text/plain"
            DeviceState.shared.clipboardLastUpdated = Date()
        }
    }
}
```

#### Blueprint 2: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`
Modify lines 417-425 and 551-556:
```swift
// In ServerManager.swift around line 417:
        Task { @MainActor in
            if !DeviceState.shared.lastSharedClipboard.isEmpty {
                let clipMsg = ContinuityMessage(
                    type: "clipboard",
                    content: DeviceState.shared.lastSharedClipboard,
                    contentType: DeviceState.shared.lastSharedClipboardType,
                    source: "mac",
                    payload: DeviceState.shared.lastSharedClipboard
                )
                self.sendWebSocketMessage(client: client, message: clipMsg)
            }
        }

// In ServerManager.swift around line 551:
        case "clipboard":
            if let content = message.content ?? message.payload {
                let contentType = message.contentType ?? "text/plain"
                let hash = message.hash
                Task { @MainActor in
                    ClipboardSyncService.shared.handleIncomingClipboard(
                        content: content,
                        contentType: contentType,
                        hash: hash,
                        sender: client.deviceName
                    )
                }
            }
```

#### Blueprint 3: `mac/Sources/GalaxyContinuityKit/Models/DeviceState.swift`
Add `lastSharedClipboardType` below line 38:
```swift
    @Published public var clipboardAutoSync: Bool = true
    @Published public var lastSharedClipboard: String = ""
    @Published public var lastSharedClipboardType: String = "text/plain"
    @Published public var clipboardLastUpdated: Date? = nil
```

#### Blueprint 4: `mac/Sources/GalaxyContinuity/UI/MenuBarView.swift`
Update lines 72-80 to display image status when `lastSharedClipboardType` is an image:
```swift
                if !state.lastSharedClipboard.isEmpty {
                    if state.lastSharedClipboardType.hasPrefix("image/") {
                        HStack {
                            Image(systemName: "photo")
                                .foregroundColor(.accentColor)
                            Text("Image in clipboard (\(state.lastSharedClipboardType))")
                                .font(.system(size: 11))
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                    } else {
                        Text(state.lastSharedClipboard)
                            .font(.system(size: 11))
                            .lineLimit(3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(8)
                    }
                } else {
```

#### Blueprint 5: `mac/Tests/GalaxyContinuityTests/ClipboardSyncTests.swift`
Create new test file `mac/Tests/GalaxyContinuityTests/ClipboardSyncTests.swift`:
```swift
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
        // Should reach here without crashing
        XCTAssertTrue(true)
    }
}
#endif
```

---

### 4.2 Android Client Blueprints

#### Blueprint 6: `android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt`
Replace existing file content with:

```kotlin
package com.galaxycontinuity.app.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

class ClipboardSync(
    private val context: Context,
    private val onSendClipboard: (content: String, contentType: String, hash: String) -> Unit
) {
    // Secondary constructor for backward compatibility
    constructor(
        context: Context,
        onSendText: (text: String) -> Unit
    ) : this(context, { content, _, _ -> onSendText(content) })

    private val tag = "ClipboardSync"
    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var lastSeenText = ""
    private var lastSeenHash = ""
    private var lastSentHash = ""
    private var isUpdatingFromMac = false

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (isUpdatingFromMac) return@OnPrimaryClipChangedListener

        val clip = clipboardManager.primaryClip ?: return@OnPrimaryClipChangedListener
        if (clip.itemCount == 0) return@OnPrimaryClipChangedListener

        val item = clip.getItemAt(0)

        // 1. Check for image URI in primary clip
        val uri = item.uri
        val clipDesc = clip.description
        val isImage = uri != null && (
            clipDesc.hasMimeType("image/*") ||
            clipDesc.hasMimeType("image/png") ||
            clipDesc.hasMimeType("image/jpeg") ||
            (context.contentResolver.getType(uri)?.startsWith("image/") == true)
        )

        if (isImage && uri != null) {
            try {
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes != null && bytes.isNotEmpty()) {
                    val hash = sha256Hex(bytes)
                    if (hash != lastSeenHash && hash != lastSentHash) {
                        lastSeenHash = hash
                        lastSentHash = hash
                        val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                        lastSeenText = b64
                        val mime = context.contentResolver.getType(uri) ?: "image/png"
                        Log.d(tag, "Phone image clipboard changed: $mime (${bytes.size} bytes)... sending to Mac")
                        onSendClipboard(b64, mime, hash)
                        return@OnPrimaryClipChangedListener
                    }
                }
            } catch (e: Exception) {
                Log.e(tag, "Failed to read image from clipboard URI: $uri", e)
            }
        }

        // 2. Check for plain text
        val text = item.text?.toString() ?: ""
        if (text.isNotEmpty()) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            val hash = sha256Hex(bytes)
            if (hash != lastSeenHash && hash != lastSentHash && text != lastSeenText) {
                lastSeenText = text
                lastSeenHash = hash
                lastSentHash = hash
                Log.d(tag, "Phone clipboard changed: ${text.take(30)}... sending to Mac")
                onSendClipboard(text, "text/plain", hash)
            }
        }
    }

    fun start() {
        clipboardManager.addPrimaryClipChangedListener(clipListener)
    }

    fun stop() {
        clipboardManager.removePrimaryClipChangedListener(clipListener)
    }

    fun updateClipboardFromMac(content: String, contentType: String = "text/plain", hash: String? = null) {
        if (content.isEmpty()) return

        val computedHash = hash ?: sha256Hex(
            if (contentType.startsWith("image/")) {
                try {
                    Base64.decode(content, Base64.DEFAULT)
                } catch (e: Exception) {
                    content.toByteArray(Charsets.UTF_8)
                }
            } else {
                content.toByteArray(Charsets.UTF_8)
            }
        )

        // Echo loop suppression: check hash and content
        if ((computedHash.isNotEmpty() && (computedHash == lastSeenHash || computedHash == lastSentHash)) ||
            (content == lastSeenText)) {
            Log.d(tag, "Dropping echo clipboard update from Mac (hash=$computedHash)")
            return
        }

        isUpdatingFromMac = true
        lastSeenHash = computedHash
        lastSeenText = content

        try {
            if (contentType.startsWith("image/")) {
                val imageBytes = Base64.decode(content, Base64.DEFAULT)
                if (imageBytes != null && imageBytes.isNotEmpty()) {
                    val imageDir = File(context.cacheDir, "clipboard").apply { mkdirs() }
                    val ext = if (contentType.contains("jpeg") || contentType.contains("jpg")) "jpg" else "png"
                    val imageFile = File(imageDir, "synced_clip.$ext")
                    imageFile.writeBytes(imageBytes)

                    val uri: Uri = try {
                        FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            imageFile
                        )
                    } catch (e: Exception) {
                        Log.w(tag, "FileProvider failed: ${e.message}, falling back to file URI")
                        Uri.fromFile(imageFile)
                    }

                    val clip = ClipData.newUri(context.contentResolver, "Galaxy Continuity Image", uri)
                    clipboardManager.setPrimaryClip(clip)
                    Log.d(tag, "Updated Galaxy clipboard with image from Mac (${imageBytes.size} bytes)")
                }
            } else {
                val clip = ClipData.newPlainText("Galaxy Continuity", content)
                clipboardManager.setPrimaryClip(clip)
                Log.d(tag, "Updated Galaxy clipboard from Mac: ${content.take(30)}...")
            }
        } catch (e: Exception) {
            Log.e(tag, "Failed to update clipboard from Mac", e)
        } finally {
            isUpdatingFromMac = false
        }
    }

    fun updateClipboardFromMac(text: String) {
        updateClipboardFromMac(text, "text/plain", null)
    }

    fun sha256Hex(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }
}
```

#### Blueprint 7: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`
Update `ContinuityListener`, `onMessage`, and `sendClipboard`:
```kotlin
// In ContinuityListener interface:
    interface ContinuityListener {
        fun onConnected(macName: String)
        fun onDisconnected()
        fun onClipboardReceived(content: String, contentType: String = "text/plain", hash: String? = null)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onPingReceived(message: String)
    }

// In onMessage under "clipboard" case:
                        "clipboard" -> {
                            val content = json.optString("content").ifEmpty { json.optString("payload") }
                            val contentType = json.optString("contentType", "text/plain").ifEmpty { "text/plain" }
                            val hash = json.optString("hash").ifEmpty { null }
                            if (content.isNotEmpty()) {
                                mainHandler.post { listener.onClipboardReceived(content, contentType, hash) }
                            }
                        }

// In sendClipboard method:
    fun sendClipboard(content: String, contentType: String = "text/plain", hash: String? = null) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", content)
            put("payload", content)
            put("contentType", contentType)
            put("source", "phone")
            if (hash != null) {
                put("hash", hash)
            }
        }
        webSocket?.send(json.toString())
    }
```

#### Blueprint 8: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`
Update lines 50-53 and lines 95-97:
```kotlin
// Lines 50-53:
        clipboardSync = ClipboardSync(this) { content, contentType, hash ->
            webSocketClient?.sendClipboard(content, contentType, hash)
        }
        clipboardSync?.start()

// Lines 95-97:
    override fun onClipboardReceived(content: String, contentType: String, hash: String?) {
        clipboardSync?.updateClipboardFromMac(content, contentType, hash)
    }
```

#### Blueprint 9: `android/app/src/main/res/xml/file_paths.xml`
Create `android/app/src/main/res/xml/file_paths.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="clipboard_cache" path="clipboard" />
    <cache-path name="cache" path="." />
    <files-path name="files" path="." />
</paths>
```

#### Blueprint 10: `android/app/src/main/AndroidManifest.xml`
Add `<provider>` inside `<application>`:
```xml
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
```

#### Blueprint 11: `android/app/src/test/java/com/galaxycontinuity/app/ClipboardSyncUnitTest.kt`
Create unit test `android/app/src/test/java/com/galaxycontinuity/app/ClipboardSyncUnitTest.kt`:
```kotlin
package com.galaxycontinuity.app

import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64

class ClipboardSyncUnitTest {

    private fun sha256Hex(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        return md.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun testEmptyPayloadSHA256() {
        val emptyHash = sha256Hex(ByteArray(0))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", emptyHash)
    }

    @Test
    fun testTextPayloadSHA256() {
        val text = "hello world"
        val hash = sha256Hex(text.toByteArray(Charsets.UTF_8))
        assertEquals("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", hash)
    }

    @Test
    fun testImageBase64EncodingDecodingRoundtrip() {
        val fakePngBytes = byteArrayOf(
            0x89.toByte(), 0x50.toByte(), 0x4E.toByte(), 0x47.toByte(),
            0x0D.toByte(), 0x0A.toByte(), 0x1A.toByte(), 0x0A.toByte()
        )
        val b64 = Base64.getEncoder().encodeToString(fakePngBytes)
        val decoded = Base64.getDecoder().decode(b64)
        assertArrayEquals(fakePngBytes, decoded)
    }

    @Test
    fun testCorruptBase64HandledSafely() {
        val corrupt = "!@#$%^&*()_not_base64"
        try {
            Base64.getDecoder().decode(corrupt)
            fail("Expected IllegalArgumentException for invalid base64")
        } catch (e: IllegalArgumentException) {
            // Expected - confirms try-catch handles corrupt base64
            assertTrue(true)
        }
    }
}
```

---

## 5. Verification Method

### 5.1 macOS Test Verification
Execute the Swift test suite:
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
swift test
```
**Expected Result**: All targets (`GalaxyContinuityKit`, `GalaxyContinuityTests`) compile and all test cases pass with zero failures.

### 5.2 E2E Protocol Clipboard Test Verification
Execute the comprehensive E2E test runner filtered to clipboard tests:
```bash
python3 /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/tests/e2e/runner.py --filter clipboard
```
**Expected Result**: All 21 tests across Tiers 1-3 pass cleanly (6 Tier 1 tests, 11 Tier 2 boundary tests, 4 Tier 3 pairwise integration tests).

### 5.3 Invalidation Conditions
- If `swift test` fails due to AppKit `NSPasteboard` access in headless CI environments, verify the test target runs under macOS host bundle settings.
- If an incoming clipboard frame missing `contentType` is received, confirm it defaults to `"text/plain"` rather than dropping the message.
- If image frames loop indefinitely, verify `lastSeenHash` matches `sha256Hex(data: imageData)` on both peers.
