package com.galaxycontinuity.app

import com.galaxycontinuity.app.service.ClipboardSync
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ClipboardSyncUnitTest {

    @Test
    fun testProductionSHA256Computation() {
        val emptyHash = ClipboardSync.sha256Hex(ByteArray(0))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", emptyHash)

        val helloHash = ClipboardSync.sha256Hex("hello world".toByteArray(Charsets.UTF_8))
        assertEquals("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", helloHash)
    }

    @Test
    fun testProductionBase64EncodingAndDecoding() {
        val rawBytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val b64 = ClipboardSync.encodeBase64(rawBytes)
        val decoded = ClipboardSync.decodeBase64(b64)
        assertArrayEquals(rawBytes, decoded)
    }

    @Test
    fun testProductionEchoSuppressionLogic() {
        var lastSeenHash = ""
        var lastSentHash = ""
        var lastSeenText = ""

        val text = "Deduplication Test"
        val hash = ClipboardSync.sha256Hex(text.toByteArray(Charsets.UTF_8))

        // Initial receive: not suppressed
        val shouldSuppressFirst = ClipboardSync.shouldSuppress(hash, text, lastSeenHash, lastSentHash, lastSeenText)
        assertFalse("First receive must not be suppressed", shouldSuppressFirst)

        // Update state
        lastSeenHash = hash
        lastSeenText = text

        // Duplicate receive: MUST be suppressed by production logic
        val shouldSuppressDuplicate = ClipboardSync.shouldSuppress(hash, text, lastSeenHash, lastSentHash, lastSeenText)
        assertTrue("Duplicate receive must be suppressed", shouldSuppressDuplicate)

        // Distinct content: must NOT be suppressed
        val text2 = "Another distinct string"
        val hash2 = ClipboardSync.sha256Hex(text2.toByteArray(Charsets.UTF_8))
        val shouldSuppressSecond = ClipboardSync.shouldSuppress(hash2, text2, lastSeenHash, lastSentHash, lastSeenText)
        assertFalse("Distinct content must not be suppressed", shouldSuppressSecond)
    }

    @Test
    fun testTextClipboardMessageSerialization() {
        val text = "Galaxy to Mac Text Sync"
        val hash = ClipboardSync.sha256Hex(text.toByteArray(Charsets.UTF_8))

        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", text)
            put("payload", text)
            put("contentType", "text/plain")
            put("source", "phone")
            put("hash", hash)
        }

        val jsonStr = json.toString()
        val parsed = JSONObject(jsonStr)

        assertEquals("clipboard", parsed.getString("type"))
        assertEquals(text, parsed.getString("content"))
        assertEquals(text, parsed.getString("payload"))
        assertEquals("text/plain", parsed.getString("contentType"))
        assertEquals("phone", parsed.getString("source"))
        assertEquals(hash, parsed.getString("hash"))
    }

    @Test
    fun testImageClipboardPayloadEncoding() {
        val rawBytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val b64 = ClipboardSync.encodeBase64(rawBytes)
        val hash = ClipboardSync.sha256Hex(rawBytes)

        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", b64)
            put("payload", b64)
            put("contentType", "image/png")
            put("source", "phone")
            put("hash", hash)
        }

        val parsed = JSONObject(json.toString())
        assertEquals("image/png", parsed.getString("contentType"))
        val decodedBytes = ClipboardSync.decodeBase64(parsed.getString("content"))
        assertArrayEquals(rawBytes, decodedBytes)
        assertEquals(hash, parsed.getString("hash"))
    }

    @Test
    fun testEmptyStringClipboardSerialization() {
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", "")
            put("payload", "")
            put("contentType", "text/plain")
            put("source", "phone")
        }

        val parsed = JSONObject(json.toString())
        assertEquals("", parsed.getString("content"))
        assertEquals("text/plain", parsed.getString("contentType"))
    }

    @Test
    fun testEmptyStringProductionSuppression() {
        val emptyText = ""
        val emptyHash = ClipboardSync.sha256Hex(emptyText.toByteArray(Charsets.UTF_8))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", emptyHash)

        // First receive with empty string state: not suppressed
        val firstReceive = ClipboardSync.shouldSuppress(emptyHash, emptyText, null, null, null)
        assertFalse("First empty string receive must not be suppressed", firstReceive)

        // Duplicate receive of empty string: must be suppressed
        val duplicateReceive = ClipboardSync.shouldSuppress(emptyHash, emptyText, emptyHash, null, emptyText)
        assertTrue("Duplicate empty string receive must be suppressed", duplicateReceive)
    }

    @Test
    fun testUniqueImageFilenameConvention() {
        val rawBytes = byteArrayOf(0x01, 0x02, 0x03)
        val hash = ClipboardSync.sha256Hex(rawBytes)
        val expectedPrefix = "synced_clip_${hash.take(8)}"
        val filenamePng = "$expectedPrefix.png"

        assertTrue(filenamePng.startsWith("synced_clip_"))
        assertTrue(filenamePng.endsWith(".png"))
        assertEquals(8, hash.take(8).length)
        assertEquals(hash.take(8), filenamePng.removePrefix("synced_clip_").removeSuffix(".png"))
    }
}
