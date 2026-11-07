# Dispatch: Worker M2 (Universal Clipboard & Quick Drop Parity Implementation)

You are `worker_m2` (`teamwork_worker`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m2`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification § 5.2, § 5.3, § 3.2, § 3.3)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1/handoff.md` (Universal Clipboard blueprints for macOS & Android)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_2/handoff.md` (Quick Drop blueprints for macOS & Android)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_spec_miner_3/handoff.md` (Specifications & test verification matrix)

## Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Write Ownership Boundaries
- `mac/Sources/**`, `mac/Tests/**`
- `android/app/src/main/**`, `android/app/src/test/**`, `android/app/src/main/res/**`
- `.agents/teamwork/worker_m2/**`

## Assigned Implementation Tasks

### 1. Universal Clipboard on macOS (`mac/Sources/GalaxyContinuityKit/`)
Follow `m2_explorer_1/handoff.md § 3.1 - § 3.5`:
- `ClipboardSyncService.swift`:
  - Implement bidirectional plain text AND image clipboard sync.
  - Image capture: check `.png` and `.tiff` (convert `.tiff` to PNG via `NSBitmapImageRep`).
  - Calculate SHA-256 hex digest (`CryptoKit.SHA256`) of payload for echo suppression.
  - Broadcast clipboard message with `contentType: "image/png"` and base64 payload when an image is copied.
  - On incoming clipboard: handle `contentType == "text/plain"` (write string to `NSPasteboard`) and `image/png` / `image/jpeg` (decode base64, write `NSImage` / PNG data to `NSPasteboard`).
  - Strict loop suppression: maintain `lastSeenHash` and `lastSentHash`, check `isUpdatingInternally` lock, drop if incoming hash matches.
  - Support empty string clipboard without dropping (`""`).
- `ServerManager.swift`:
  - Update `"clipboard"` handler to extract `contentType`, `hash`, and check both `content` and `payload`.
- `DeviceState.swift` & `MenuBarView.swift`:
  - Add `lastSharedClipboardType: String` to `DeviceState`.
  - In `MenuBarView.swift`, if `lastSharedClipboardType.hasPrefix("image/")`, display `"[Image Clipboard]"` instead of raw base64 text.

### 2. Universal Clipboard on Android (`android/app/src/main/`)
Follow `m2_explorer_1/handoff.md § 4.1 - § 4.5`:
- `android/app/src/main/res/xml/file_paths.xml`:
  - Create file provider XML paths (`<cache-path name="clipboard_images" path="clipboard_images/" />`).
- `android/app/src/main/AndroidManifest.xml`:
  - Declare `androidx.core.content.FileProvider`.
- `ClipboardSync.kt`:
  - Handle both text and image clips (check `hasMimeType("image/*")`, read bitmap from URI, compress to PNG byte array, base64 encode).
  - Compute SHA-256 hash using `MessageDigest.getInstance("SHA-256")`.
  - On incoming image: decode base64, save to cache file, create `ClipData.newUri` via `FileProvider`.
  - Symmetric echo suppression with `lastSeenHash` and `lastSentHash`.
- `WebSocketClient.kt` & `ContinuityService.kt`:
  - Parse `contentType`, `hash`, `payload`/`content`.
  - Add `sendClipboard(content: String, contentType: String, hash: String)`.

### 3. Quick Drop on macOS (`mac/Sources/GalaxyContinuityKit/`)
Follow `m2_explorer_2/handoff.md § 3.1 - § 3.3`:
- Create `mac/Sources/GalaxyContinuityKit/Services/QuickDropService.swift`:
  - Encapsulates file registration, collision renaming (`filename (1).ext`), transfer items in `DeviceState.shared.fileTransfers`, and completion notification.
- In `ServerManager.swift`:
  - Outgoing (`GET /api/download/:fileId`): stream file in 64 KB chunks using `FileHandle` or read loop, setting `Content-Length`, `Content-Type: application/octet-stream`, `Content-Disposition: attachment; filename="<encodedName>"`. Emit `file_progress` during download.
  - Incoming (`POST /api/upload`): stream upload body, sanitize filename, apply collision renaming `(1)`, `(2)`, save to `~/Downloads/GalaxyContinuity/`, emit `file_complete` WebSocket message.

### 4. Quick Drop on Android (`android/app/src/main/`)
Follow `m2_explorer_2/handoff.md § 4.1 - § 4.4`:
- Create `android/app/src/main/java/com/galaxycontinuity/app/network/FileTransferClient.kt`:
  - Implement OkHttp `uploadFile(serverUrl, fileUri, filename, progressCallback)` using `POST /api/upload` with `X-Filename` header and custom `ProgressRequestBody`.
  - Implement `downloadFile(serverUrl, fileId, filename, destinationDir, progressCallback)` using `GET /api/download/:fileId` with chunked streaming and collision renaming.
- Update `ContinuityService.kt`:
  - In `onFileAvailable(fileId, filename, size)`: launch coroutine using `FileTransferClient.downloadFile`, update Android notification progress bar, emit `file_complete`.
- Update `WebSocketClient.kt`:
  - Add handlers for `file_progress` and `file_complete`.

### 5. Automated Unit Tests
- Add `mac/Tests/GalaxyContinuityTests/ClipboardSyncTests.swift`:
  - Test text sync, image sync (PNG & TIFF), SHA-256 echo suppression, empty string copy, large base64 payload.
- Add `mac/Tests/GalaxyContinuityTests/QuickDropTests.swift`:
  - Test file registration, collision renaming `(1)`, `(2)`, `(3)`, download streaming headers, upload sanitization.
- Add `android/app/src/test/java/com/galaxycontinuity/app/ClipboardSyncUnitTest.kt`:
  - Test SHA-256 hashing, loop prevention logic, image payload serialization.
- Add `android/app/src/test/java/com/galaxycontinuity/app/FileTransferClientTest.kt`:
  - Test upload and download workflows with MockWebServer.

### 6. Verification
- Run `cd mac && swift build`
- Run `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- Run `python3 tests/test_adversarial_protocol.py`
- Run `python3 tests/e2e/runner.py` (verify all 122 tests pass cleanly)
- Document all changes, files, and test outputs in `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m2/handoff.md` and notify parent via `send_message`.


## 2026-11-07T10:30:19Z
Sender: 67ae80cb-3237-4127-adab-613c0f12f1aa (Parent Orchestrator)
Priority: HIGH
Content: You are worker_m2. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m2/DISPATCH.md. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Implement all Milestone 2 tasks: Universal Clipboard (text & image, base64, SHA-256 echo suppression) on macOS and Android, and Quick Drop (bidirectional upload/download, chunked streaming, collision renaming, progress tracking) on macOS and Android. Add unit tests, run swift build, swift test, and python3 tests/e2e/runner.py. Write your report to /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m2/handoff.md and notify your parent via send_message.
