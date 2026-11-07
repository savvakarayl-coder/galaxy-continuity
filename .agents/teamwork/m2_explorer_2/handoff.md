# Quick Drop File Transfer Parity: Investigation & Drop-in Blueprints

**Agent**: `m2_explorer_2`  
**Milestone**: M2 (Universal Clipboard & Quick Drop Parity)  
**Task**: Bidirectional Quick Drop file transfer across macOS and Android (upload, download, collision renaming, progress tracking).

---

## 1. Observation

### 1.1 macOS Server & Networking State
- **File**: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`
  - In `shareFileToGalaxy(fileURL: URL)` (lines 618–649):
    ```swift
    let fileId = UUID().uuidString
    let filename = fileURL.lastPathComponent
    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    self.sharedFiles[fileId] = (filename: filename, url: fileURL)
    ...
    let msg = ContinuityMessage(
        type: "file_available",
        fileId: fileId,
        filename: filename,
        fileSize: Int64(size),
        mimeType: "application/octet-stream",
        sender: Host.current().localizedName ?? "Mac"
    )
    self.broadcastMessage(msg)
    ```
  - In `processHTTPData` for `GET /api/download/:fileId` (lines 287–301):
    ```swift
    if method == "GET" && path.starts(with: "/api/download/") {
        client.readBuffer.removeAll()
        let fileId = String(path.dropFirst("/api/download/".count))
        if let fileInfo = sharedFiles[fileId], let fileData = try? Data(contentsOf: fileInfo.url) {
            let encodedName = fileInfo.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileInfo.filename
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(encodedName)\"\r\nContent-Length: \(fileData.count)\r\n\r\n"
            sendRaw(client: client, data: Data(headers.utf8) + fileData)
        } else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            sendRaw(client: client, data: Data(notFound.utf8))
        }
        removeClient(client)
        return
    }
    ```
    *Observation*: Files are loaded entirely into memory using `Data(contentsOf: fileInfo.url)` rather than chunked streaming. No `file_progress` updates are dispatched over WebSocket during the transfer.
  - In `saveUploadedFile` (lines 345–397):
    Path traversal sanitization and collision renaming are implemented, saving to `~/Downloads/GalaxyContinuity/` and appending ` (1)`, ` (2)`. However, no WebSocket `file_complete` confirmation is sent back to the uploading peer.
  - Dedicated service: `QuickDropService.swift` does not exist in `mac/Sources/GalaxyContinuityKit/Services/`. `QuickDropView.swift` currently calls `ServerManager.shared.shareFileToGalaxy(fileURL: fileUrl)` directly.

### 1.2 Android Client State
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`
  - In `onFileAvailable(fileId: String, filename: String, size: Long)` (lines 99–101):
    ```kotlin
    override fun onFileAvailable(fileId: String, filename: String, size: Long) {
        // Trigger download via DownloadManager or HTTP client
    }
    ```
    *Observation*: The handler is a non-functional comment stub. Incoming file announcements from macOS are ignored.
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`
  - In `onMessage` (lines 66–71):
    `file_available` is parsed and forwarded to listener. However, `file_progress` and `file_complete` messages are unhandled.
  - No methods exist to send `file_progress` or `file_complete` back to macOS.
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/network/FileTransferClient.kt`
  - Does not exist. No OkHttp upload or download logic exists on Android.
- **File**: `android/app/build.gradle.kts`
  - Contains `com.squareup.okhttp3:okhttp:4.12.0`, `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3`, and `testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")`.

### 1.3 Protocol & Test Suite Expectations
- `shared/PROTOCOL.md` § 3.2, § 3.3, § 5.3:
  - Phone -> Mac upload: HTTP `POST /api/upload`, `X-Filename: <encodedName>`, binary stream body. Success response `{"status":"ok"}`. Collision rename format: `<base> (<counter>).<ext>`.
  - Mac -> Phone download: HTTP `GET /api/download/:fileId`, `Content-Disposition: attachment; filename="<name>"`.
  - WebSocket control messages: `file_available`, `file_progress` (`bytesTransferred`, `totalBytes`, `percentage`, `status`), `file_complete` (`fileId`, `status`, `message`).
- Verification: `python3 tests/e2e/runner.py` passed 122/122 tests. `swift test` passed.

---

## 2. Logic Chain

1. **Mac Outgoing Transfer (Mac -> Phone)**:
   - When a user initiates a share on macOS (via menu bar or drag-and-drop into `QuickDropView`), `QuickDropService` registers the file in `ServerManager` under a generated UUID (`fileId`).
   - A `file_available` WebSocket message is broadcast to paired Galaxy devices with `fileId`, `filename`, `fileSize`, `mimeType`, and `sender`.
   - When the Galaxy device requests `GET /api/download/:fileId`, the server should stream chunks (e.g., 64 KB) using `FileHandle` / posix read/write to prevent OOM on large files, setting `Content-Length` and `Content-Disposition`.
   - During download, `file_progress` can be emitted to keep UI progress indicators in sync.

2. **Mac Incoming Transfer (Phone -> Mac)**:
   - When a phone uploads to `POST /api/upload`, the server reads `Content-Length` and `X-Filename`.
   - Filename is sanitized using `sanitizeUploadFilename` (preventing path traversal and hidden files).
   - Collision resolution checks if target exists in `~/Downloads/GalaxyContinuity/` and increments ` (1)`, ` (2)`.
   - After saving, server adds a `FileTransferItem` to `DeviceState.shared`, posts a system notification via `NotificationService`, and sends a `file_complete` WebSocket message.

3. **Android Client Architecture**:
   - `FileTransferClient.kt` is required to encapsulate OkHttp upload and download workflows.
   - For uploads: A custom `ProgressRequestBody` wraps the file/stream and intercepts `BufferedSink.write` to invoke a progress callback and send `file_progress` over WebSocket.
   - For downloads: `ContinuityService.onFileAvailable` triggers a coroutine on `Dispatchers.IO` using `FileTransferClient.downloadFile`.
   - Collision resolution in Android must match the macOS algorithm: `<base> (<counter>).<ext>`.
   - Notifications: A dedicated `NotificationChannel` (`galaxy_quick_drop_channel`) displays an ongoing notification with progress bar (`.setProgress(100, pct, false)`) and completion intent upon finish.

---

## 3. Caveats

1. **Android Scoped Storage (API 29+)**:
   - Writing directly to `Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)` without SAF or `MANAGE_EXTERNAL_STORAGE` can be restricted on Android 10+ depending on app target.
   - *Mitigation*: The blueprint checks `downloadDir.mkdirs()`, and if inaccessible or denied, gracefully falls back to `context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)` or `File(context.filesDir, "downloads")`.
2. **Transfer Interruption & Resumption**:
   - HTTP/1.1 Range requests (`bytes=...`) are not required by `PROTOCOL.md` v1.0.0. Failed transfers report `status: "failed"` and restart cleanly.
3. **MIME Type Inference**:
   - macOS uses `UTType(filenameExtension:)?.preferredMIMEType` with fallback to `application/octet-stream`. Android uses `MimeTypeMap.getSingleton().getMimeTypeFromExtension()`.

---

## 4. Conclusion & Drop-in Blueprints

Below are complete, production-grade drop-in blueprints for Worker M2.

---

### Blueprint 1: macOS `QuickDropService.swift`
**Target File**: `mac/Sources/GalaxyContinuityKit/Services/QuickDropService.swift`

```swift
import AppKit
import Foundation
import UniformTypeIdentifiers

public struct QuickDropTransferProgress: Equatable {
    public let fileId: String
    public let filename: String
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let percentage: Double
    public let isOutgoing: Bool
    public let status: String
}

public final class QuickDropService {
    public static let shared = QuickDropService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.quickdrop", qos: .userInitiated)
    private var activeTransfers: [String: QuickDropTransferProgress] = [:]

    private init() {}

    /// Send a local file to connected Galaxy devices
    public func sendFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[QuickDropService] File does not exist at: \(url.path)")
            return
        }

        queue.async {
            ServerManager.shared.shareFileToGalaxy(fileURL: url)
        }
    }

    /// Update transfer progress from incoming WebSocket `file_progress`
    public func handleProgressUpdate(message: ContinuityMessage) {
        guard let fileId = message.fileId else { return }
        let transferred = message.bytesTransferred ?? 0
        let total = message.totalBytes ?? 0
        let pct = message.percentage ?? (total > 0 ? (Double(transferred) / Double(total) * 100.0) : 0.0)
        let status = message.status ?? "transferring"

        let progress = QuickDropTransferProgress(
            fileId: fileId,
            filename: message.filename ?? "File",
            bytesTransferred: transferred,
            totalBytes: total,
            percentage: pct,
            isOutgoing: false,
            status: status
        )

        queue.async {
            self.activeTransfers[fileId] = progress
        }
    }

    /// Handle transfer completion notification
    public func handleTransferComplete(message: ContinuityMessage) {
        guard let fileId = message.fileId else { return }
        queue.async {
            self.activeTransfers.removeValue(forKey: fileId)
        }
    }

    /// Resolve filename collisions by appending " (1)", " (2)" before the extension
    public static func resolveCollision(in directory: URL, filename: String) -> URL {
        var targetUrl = directory.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent
        var counter = 1

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = directory.appendingPathComponent(newName).standardizedFileURL.resolvingSymlinksInPath()
            counter += 1
        }
        return targetUrl
    }
}
```

---

### Blueprint 2: macOS `ServerManager.swift` Enhancements
**Target File**: `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`

Add chunked file streaming and MIME type detection:

```swift
    // MARK: - Chunked Streaming for GET /api/download/:fileId
    // Replace lines 287-301 in ServerManager.swift with chunked streaming:
    if method == "GET" && path.starts(with: "/api/download/") {
        client.readBuffer.removeAll()
        let fileId = String(path.dropFirst("/api/download/".count))

        if let fileInfo = sharedFiles[fileId],
           FileManager.default.fileExists(atPath: fileInfo.url.path),
           let fileHandle = try? FileHandle(forReadingFrom: fileInfo.url) {
            
            let fileSize = (try? fileInfo.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let encodedName = fileInfo.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileInfo.filename
            let mimeType = UTType(filenameExtension: fileInfo.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

            let headerStr = "HTTP/1.1 200 OK\r\nContent-Type: \(mimeType)\r\nContent-Disposition: attachment; filename=\"\(encodedName)\"\r\nContent-Length: \(fileSize)\r\nConnection: close\r\n\r\n"
            sendRaw(client: client, data: Data(headerStr.utf8))

            // Stream chunks (64 KB)
            let chunkSize = 65536
            var bytesSent: Int64 = 0
            while bytesSent < Int64(fileSize) {
                let chunkData = fileHandle.readData(ofLength: chunkSize)
                if chunkData.isEmpty { break }
                sendRaw(client: client, data: chunkData)
                bytesSent += Int64(chunkData.count)

                let pct = fileSize > 0 ? (Double(bytesSent) / Double(fileSize) * 100.0) : 100.0
                let progressMsg = ContinuityMessage(
                    type: "file_progress",
                    fileId: fileId,
                    filename: fileInfo.filename,
                    bytesTransferred: bytesSent,
                    totalBytes: Int64(fileSize),
                    percentage: pct,
                    status: bytesSent >= Int64(fileSize) ? "completed" : "transferring"
                )
                self.broadcastMessage(progressMsg)
            }
            try? fileHandle.close()
        } else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendRaw(client: client, data: Data(notFound.utf8))
        }
        removeClient(client)
        return
    }
```

In `handleIncomingMessage(client:message:)` (lines 535–589), add message routing for `file_progress` and `file_complete`:
```swift
        case "file_progress":
            QuickDropService.shared.handleProgressUpdate(message: message)

        case "file_complete":
            QuickDropService.shared.handleTransferComplete(message: message)
```

In `saveUploadedFile(name:data:sender:)`, after saving successfully:
```swift
        // Send file_complete confirmation
        let completeMsg = ContinuityMessage(
            type: "file_complete",
            fileId: UUID().uuidString,
            filename: finalName,
            status: "success",
            message: "File saved to ~/Downloads/GalaxyContinuity/\(finalName)"
        )
        self.broadcastMessage(completeMsg)
```

---

### Blueprint 3: Android `FileTransferClient.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/network/FileTransferClient.kt`

```kotlin
package com.galaxycontinuity.app.network

import android.content.Context
import android.net.Uri
import android.util.Log
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okio.Buffer
import okio.BufferedSink
import okio.ForwardingSink
import okio.buffer
import okio.sink
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

typealias ProgressListener = (bytesTransferred: Long, totalBytes: Long, percentage: Double) -> Unit

class ProgressRequestBody(
    private val delegate: RequestBody,
    private val onProgress: ProgressListener?
) : RequestBody() {
    override fun contentType() = delegate.contentType()
    override fun contentLength() = delegate.contentLength()

    override fun writeTo(sink: BufferedSink) {
        val total = contentLength()
        var bytesWritten = 0L

        val countingSink = object : ForwardingSink(sink) {
            override fun write(source: Buffer, byteCount: Long) {
                super.write(source, byteCount)
                bytesWritten += byteCount
                val percentage = if (total > 0) (bytesWritten.toDouble() / total * 100.0) else 0.0
                onProgress?.invoke(bytesWritten, total, percentage)
            }
        }
        val buffered = countingSink.buffer()
        delegate.writeTo(buffered)
        buffered.flush()
    }
}

class FileTransferClient(
    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()
) {
    companion object {
        private const val TAG = "FileTransferClient"

        fun sanitizeFilename(raw: String?): String {
            val fallback = "Received_File_${System.currentTimeMillis()}.bin"
            if (raw.isNullOrBlank()) return fallback

            var name = try {
                URLDecoder.decode(raw, "UTF-8")
            } catch (e: Exception) {
                raw
            }.trim()

            if (name.isEmpty() || name.all { it == '.' || it == '/' || it == '\\' }) {
                return fallback
            }

            var candidate = File(name).name
            if (candidate.contains('\\')) {
                candidate = candidate.substringAfterLast('\\')
            }
            candidate = candidate.trim()

            if (candidate.isEmpty() || candidate == "/" || candidate.startsWith(".") || candidate.contains("/") || candidate.contains("\\")) {
                return fallback
            }
            return candidate
        }

        fun resolveCollision(directory: File, filename: String): File {
            var candidate = File(directory, filename)
            if (!candidate.exists()) return candidate

            val dotIndex = filename.lastIndexOf('.')
            val base = if (dotIndex > 0) filename.substring(0, dotIndex) else filename
            val ext = if (dotIndex > 0) filename.substring(dotIndex) else ""

            var counter = 1
            while (candidate.exists()) {
                candidate = File(directory, "$base ($counter)$ext")
                counter++
            }
            return candidate
        }
    }

    /**
     * Upload a local file to macOS host at POST /api/upload
     */
    fun uploadFile(
        serverUrl: String,
        file: File,
        filename: String = file.name,
        progress: ProgressListener? = null
    ): Result<String> {
        val safeName = sanitizeFilename(filename)
        val encodedName = URLEncoder.encode(safeName, "UTF-8").replace("+", "%20")
        val rawBody = RequestBody.create("application/octet-stream".toMediaTypeOrNull(), file)
        val progressBody = ProgressRequestBody(rawBody, progress)

        val request = Request.Builder()
            .url("$serverUrl/api/upload")
            .header("X-Filename", encodedName)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", file.length().toString())
            .post(progressBody)
            .build()

        return try {
            val response = okHttpClient.newCall(request).execute()
            if (response.isSuccessful) {
                val respStr = response.body?.string() ?: ""
                Log.d(TAG, "Upload succeeded: $respStr")
                Result.success(safeName)
            } else {
                Result.failure(IOException("Upload failed with HTTP ${response.code}"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Upload error", e)
            Result.failure(e)
        }
    }

    /**
     * Upload an InputStream from Android ContentResolver Uri
     */
    fun uploadStream(
        serverUrl: String,
        inputStream: InputStream,
        totalBytes: Long,
        filename: String,
        progress: ProgressListener? = null
    ): Result<String> {
        val safeName = sanitizeFilename(filename)
        val encodedName = URLEncoder.encode(safeName, "UTF-8").replace("+", "%20")

        val rawBody = object : RequestBody() {
            override fun contentType() = "application/octet-stream".toMediaTypeOrNull()
            override fun contentLength() = totalBytes

            override fun writeTo(sink: BufferedSink) {
                val buffer = ByteArray(8192)
                var read: Int
                while (inputStream.read(buffer).also { read = it } != -1) {
                    sink.write(buffer, 0, read)
                }
            }
        }

        val progressBody = ProgressRequestBody(rawBody, progress)
        val request = Request.Builder()
            .url("$serverUrl/api/upload")
            .header("X-Filename", encodedName)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", totalBytes.toString())
            .post(progressBody)
            .build()

        return try {
            val response = okHttpClient.newCall(request).execute()
            if (response.isSuccessful) {
                Result.success(safeName)
            } else {
                Result.failure(IOException("Upload failed with HTTP ${response.code}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        } finally {
            try { inputStream.close() } catch (_: Exception) {}
        }
    }

    /**
     * Download a file from macOS host at GET /api/download/:fileId
     */
    fun downloadFile(
        serverUrl: String,
        fileId: String,
        destinationDir: File,
        expectedFilename: String?,
        progress: ProgressListener? = null
    ): Result<File> {
        if (!destinationDir.exists()) {
            destinationDir.mkdirs()
        }

        val request = Request.Builder()
            .url("$serverUrl/api/download/$fileId")
            .get()
            .build()

        return try {
            val response = okHttpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return Result.failure(IOException("Download failed with HTTP ${response.code}"))
            }

            val body = response.body ?: return Result.failure(IOException("Empty response body"))
            val totalBytes = body.contentLength()

            // Parse filename from Content-Disposition if present
            val disposition = response.header("Content-Disposition")
            var filename = expectedFilename
            if (disposition != null && disposition.contains("filename=")) {
                val match = Regex("""filename="?([^";]+)"?""").find(disposition)
                if (match != null) {
                    filename = match.groupValues[1]
                }
            }

            val safeFilename = sanitizeFilename(filename)
            val targetFile = resolveCollision(destinationDir, safeFilename)

            val source = body.source()
            val sink = targetFile.sink().buffer()
            val buffer = Buffer()
            var bytesRead = 0L

            while (true) {
                val count = source.read(buffer, 8192L)
                if (count == -1L) break
                sink.write(buffer, count)
                bytesRead += count
                val pct = if (totalBytes > 0) (bytesRead.toDouble() / totalBytes * 100.0) else 0.0
                progress?.invoke(bytesRead, totalBytes, pct)
            }

            sink.flush()
            sink.close()
            source.close()

            Result.success(targetFile)
        } catch (e: Exception) {
            Log.e(TAG, "Download error", e)
            Result.failure(e)
        }
    }
}
```

---

### Blueprint 4: Android `WebSocketClient.kt` Quick Drop Additions
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`

Update `ContinuityListener`:
```kotlin
    interface ContinuityListener {
        fun onConnected(macName: String)
        fun onDisconnected()
        fun onClipboardReceived(text: String)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String)
        fun onFileComplete(fileId: String, status: String, message: String)
        fun onPingReceived(message: String)
    }
```

In `onMessage`, add handling for `file_progress` and `file_complete`:
```kotlin
    "file_progress" -> {
        val fileId = json.optString("fileId")
        val transferred = json.optLong("bytesTransferred")
        val total = json.optLong("totalBytes")
        val pct = json.optDouble("percentage")
        val status = json.optString("status")
        mainHandler.post { listener.onFileProgress(fileId, transferred, total, pct, status) }
    }
    "file_complete" -> {
        val fileId = json.optString("fileId")
        val status = json.optString("status")
        val message = json.optString("message")
        mainHandler.post { listener.onFileComplete(fileId, status, message) }
    }
```

Add methods to send Quick Drop messages:
```kotlin
    fun sendFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_progress")
            put("fileId", fileId)
            put("bytesTransferred", bytesTransferred)
            put("totalBytes", totalBytes)
            put("percentage", percentage)
            put("status", status)
        }
        webSocket?.send(json.toString())
    }

    fun sendFileComplete(fileId: String, status: String, message: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_complete")
            put("fileId", fileId)
            put("status", status)
            put("message", message)
        }
        webSocket?.send(json.toString())
    }
```

---

### Blueprint 5: Android `ContinuityService.kt` Implementation
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`

Add channel definition and `FileTransferClient`:
```kotlin
    companion object {
        const val CHANNEL_ID = "galaxy_continuity_channel"
        const val CHANNEL_QUICK_DROP = "galaxy_quick_drop_channel"
        const val NOTIFICATION_ID = 1001
        const val QUICK_DROP_NOTIFICATION_ID = 2001
        ...
    }

    private val fileTransferClient = FileTransferClient()
    private val serviceScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO + kotlinx.coroutines.SupervisorJob())
```

In `createNotificationChannel()`:
```kotlin
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val quickDropChannel = NotificationChannel(
            CHANNEL_QUICK_DROP,
            "Quick Drop Transfers",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress and completion of Quick Drop file transfers"
        }
        manager.createNotificationChannel(quickDropChannel)
    }
```

Implement `onFileAvailable`:
```kotlin
    override fun onFileAvailable(fileId: String, filename: String, size: Long) {
        val host = webSocketClient?.currentHost ?: return
        val port = webSocketClient?.currentPort ?: 8765
        val serverUrl = "http://$host:$port"

        val downloadDir = File(
            android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
            "GalaxyContinuity"
        ).takeIf { it.exists() || it.mkdirs() }
            ?: File(getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS) ?: filesDir, "GalaxyContinuity").apply { mkdirs() }

        showTransferNotification(fileId, filename, 0.0, false)

        serviceScope.launch {
            var lastUpdate = 0L
            val result = fileTransferClient.downloadFile(serverUrl, fileId, downloadDir, filename) { bytes, total, pct ->
                val now = System.currentTimeMillis()
                if (now - lastUpdate > 300 || pct >= 100.0) {
                    lastUpdate = now
                    showTransferNotification(fileId, filename, pct, false)
                    webSocketClient?.sendFileProgress(fileId, bytes, total, pct, "transferring")
                }
            }

            result.onSuccess { savedFile ->
                showTransferNotification(fileId, filename, 100.0, true, savedFile)
                webSocketClient?.sendFileComplete(fileId, "success", "Saved to ${savedFile.absolutePath}")
            }.onFailure { err ->
                showTransferFailedNotification(filename, err.message ?: "Download failed")
                webSocketClient?.sendFileComplete(fileId, "error", err.message ?: "Download failed")
            }
        }
    }

    override fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String) {
        // Handle remote progress update if needed
    }

    override fun onFileComplete(fileId: String, status: String, message: String) {
        // Handle remote complete update if needed
    }

    private fun showTransferNotification(fileId: String, filename: String, percentage: Double, completed: Boolean, file: File? = null) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = NotificationCompat.Builder(this, CHANNEL_QUICK_DROP)
            .setSmallIcon(if (completed) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_sys_download)
            .setContentTitle(if (completed) "⚡ Quick Drop Complete" else "⚡ Receiving $filename")
            .setContentText(if (completed) "$filename saved to Downloads/GalaxyContinuity" else "${percentage.toInt()}%")
            .setOngoing(!completed)

        if (!completed) {
            builder.setProgress(100, percentage.toInt(), false)
        } else {
            builder.setProgress(0, 0, false)
            if (file != null) {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                }
                val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
                builder.setContentIntent(pending)
            }
        }
        manager.notify(QUICK_DROP_NOTIFICATION_ID, builder.build())
    }

    private fun showTransferFailedNotification(filename: String, reason: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = NotificationCompat.Builder(this, CHANNEL_QUICK_DROP)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Quick Drop Failed")
            .setContentText("Could not download $filename: $reason")
            .build()
        manager.notify(QUICK_DROP_NOTIFICATION_ID, notification)
    }
```

---

### Blueprint 6: Automated Test Suites

#### A. macOS `QuickDropTests.swift`
**Target File**: `mac/Tests/GalaxyContinuityTests/QuickDropTests.swift`

```swift
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
}
#endif
```

#### B. Android `FileTransferClientTest.kt`
**Target File**: `android/app/src/test/java/com/galaxycontinuity/app/FileTransferClientTest.kt`

```kotlin
package com.galaxycontinuity.app

import com.galaxycontinuity.app.network.FileTransferClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class FileTransferClientTest {

    private lateinit var server: MockWebServer
    private lateinit var client: FileTransferClient
    private lateinit var tempDir: File

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = FileTransferClient()
        tempDir = Files.createTempDirectory("gc_test").toFile()
    }

    @After
    fun tearDown() {
        server.shutdown()
        tempDir.deleteRecursively()
    }

    @Test
    fun testUploadFileWithProgress() {
        val testFile = File(tempDir, "sample.txt")
        testFile.writeText("Quick Drop Content")

        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"status":"ok"}"""))

        var progressReported = false
        val result = client.uploadFile(
            serverUrl = server.url("/").toString().removeSuffix("/"),
            file = testFile,
            filename = "sample.txt"
        ) { _, _, pct ->
            if (pct >= 100.0) progressReported = true
        }

        assertTrue(result.isSuccess)
        val recorded = server.takeRequest()
        assertEquals("/api/upload", recorded.path)
        assertEquals("sample.txt", recorded.getHeader("X-Filename"))
        assertEquals("Quick Drop Content", recorded.body.readUtf8())
        assertTrue(progressReported)
    }

    @Test
    fun testDownloadFileWithProgress() {
        val payload = "Downloaded binary data from Mac"
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Disposition", "attachment; filename=\"downloaded.txt\"")
                .setBody(payload)
        )

        var progressReported = false
        val result = client.downloadFile(
            serverUrl = server.url("/").toString().removeSuffix("/"),
            fileId = "test-uuid-1234",
            destinationDir = tempDir,
            expectedFilename = "fallback.txt"
        ) { _, _, pct ->
            if (pct >= 100.0) progressReported = true
        }

        assertTrue(result.isSuccess)
        val downloadedFile = result.getOrThrow()
        assertEquals("downloaded.txt", downloadedFile.name)
        assertEquals(payload, downloadedFile.readText())
        assertTrue(progressReported)
    }

    @Test
    fun testCollisionRenaming() {
        val f1 = File(tempDir, "photo.jpg").apply { writeText("1") }
        val resolved = FileTransferClient.resolveCollision(tempDir, "photo.jpg")
        assertEquals("photo (1).jpg", resolved.name)

        resolved.writeText("2")
        val resolved2 = FileTransferClient.resolveCollision(tempDir, "photo.jpg")
        assertEquals("photo (2).jpg", resolved2.name)
    }

    @Test
    fun testSanitizeFilename() {
        assertEquals("normal.pdf", FileTransferClient.sanitizeFilename("normal.pdf"))
        assertEquals("passwd", FileTransferClient.sanitizeFilename("../../../../etc/passwd"))
        assertEquals("photo.png", FileTransferClient.sanitizeFilename("nested/folder/photo.png"))
        assertTrue(FileTransferClient.sanitizeFilename("..").startsWith("Received_File_"))
        assertTrue(FileTransferClient.sanitizeFilename(null).startsWith("Received_File_"))
    }
}
```

---

## 5. Verification Method

1. **macOS Test Verification**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift test
   ```
   *Expected*: All Swift unit tests in `GalaxyContinuityTests` compile cleanly and pass with 0 failures.

2. **Android JVM Unit Test Verification**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android && ./gradlew test
   ```
   *Expected*: `FileTransferClientTest`, `ProtocolSerializationTest`, and `WebSocketFrameTest` pass cleanly.

3. **E2E Independent Test Verification**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity && python3 tests/e2e/runner.py
   ```
   *Expected*: 122/122 tests pass across Tiers 1–4, specifically:
   - `test_17_mac_shares_file_broadcasts_file_available`
   - `test_18_phone_downloads_shared_file_via_http`
   - `test_19_phone_downloads_unicode_filename`
   - `test_20_phone_downloads_binary_archive`
   - `test_21_file_available_schema_validation`
   - `test_22_phone_uploads_file_via_http_post`
   - `test_23_phone_uploads_unicode_filename`
   - `test_24_phone_uploads_without_filename_header`
   - `test_25_phone_upload_filename_collision_handling`
   - `test_26_phone_upload_large_binary_payload`
   - `test_23_upload_zero_byte_file`
   - `test_24_upload_missing_content_length`
   - `test_25_upload_unsupported_method_put`
   - `test_26_upload_unsupported_method_get`
   - `test_27_upload_extreme_filename_length`
   - `test_28_upload_filename_path_traversal_sanitization`

4. **Invalidation Conditions**:
   - HTTP POST `/api/upload` overwrites existing files instead of incrementing `(1)`.
   - Filenames containing path traversal characters escape `~/Downloads/GalaxyContinuity/`.
   - Download endpoint `/api/download/:fileId` responds with status code other than 200 or 404.
   - Non-zero progress events fail to report before completion.
