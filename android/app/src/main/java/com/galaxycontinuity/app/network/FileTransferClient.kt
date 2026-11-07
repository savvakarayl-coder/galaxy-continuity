package com.galaxycontinuity.app.network

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

        private fun safeLogD(msg: String) {
            try { Log.d(TAG, msg) } catch (_: Throwable) {}
        }

        private fun safeLogE(msg: String, tr: Throwable? = null) {
            try { Log.e(TAG, msg, tr) } catch (_: Throwable) {}
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
            okHttpClient.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val respStr = response.body?.string() ?: ""
                    safeLogD("Upload succeeded: $respStr")
                    Result.success(safeName)
                } else {
                    Result.failure(IOException("Upload failed with HTTP ${response.code}"))
                }
            }
        } catch (e: Exception) {
            safeLogE("Upload error", e)
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
            okHttpClient.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    Result.success(safeName)
                } else {
                    Result.failure(IOException("Upload failed with HTTP ${response.code}"))
                }
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
            okHttpClient.newCall(request).execute().use { response ->
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

                try {
                    body.source().use { source ->
                        targetFile.sink().buffer().use { sink ->
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
                        }
                    }
                    Result.success(targetFile)
                } catch (e: Exception) {
                    if (targetFile.exists()) {
                        targetFile.delete()
                    }
                    safeLogE("Download stream error", e)
                    Result.failure(e)
                }
            }
        } catch (e: Exception) {
            safeLogE("Download error", e)
            Result.failure(e)
        }
    }
}
