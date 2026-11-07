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

    @Test
    fun testDownloadFailureClosesResponseAndReturnsError() {
        server.enqueue(MockResponse().setResponseCode(404).setBody("Not Found"))

        val result = client.downloadFile(
            serverUrl = server.url("/").toString().removeSuffix("/"),
            fileId = "missing-id",
            destinationDir = tempDir,
            expectedFilename = "missing.txt"
        )

        assertTrue(result.isFailure)
        val missingFile = File(tempDir, "missing.txt")
        assertFalse("File should not be created on 404 response", missingFile.exists())
    }

    @Test
    fun testUploadFailureClosesResponseAndReturnsError() {
        val testFile = File(tempDir, "sample_err.txt")
        testFile.writeText("Error content")

        server.enqueue(MockResponse().setResponseCode(500).setBody("Server Error"))

        val result = client.uploadFile(
            serverUrl = server.url("/").toString().removeSuffix("/"),
            file = testFile,
            filename = "sample_err.txt"
        )

        assertTrue(result.isFailure)
    }
}
