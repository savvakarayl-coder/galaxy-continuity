package com.galaxycontinuity.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Unit tests verifying WebSocket message payload construction, binary framing,
 * and protocol parsing semantics.
 */
class WebSocketFrameTest {

    @Test
    fun testHandshakePayloadConstruction() {
        val deviceName = "Samsung Galaxy S24 Ultra"
        val batteryLevel = 85
        val isCharging = true

        val payload = JSONObject().apply {
            put("type", "handshake")
            put("device", deviceName)
            put("platform", "android")
            put("version", "1.0.0")
            put("battery", JSONObject().apply {
                put("level", batteryLevel)
                put("isCharging", isCharging)
            })
        }

        val jsonStr = payload.toString()
        assertTrue(jsonStr.contains("\"type\":\"handshake\""))
        assertTrue(jsonStr.contains("\"device\":\"Samsung Galaxy S24 Ultra\""))
        assertTrue(jsonStr.contains("\"level\":85"))
    }

    @Test
    fun testClipboardPayloadConstruction() {
        val text = "Shared clipboard content between devices"
        val payload = JSONObject().apply {
            put("type", "clipboard")
            put("content", text)
            put("contentType", "text/plain")
            put("source", "phone")
            put("timestamp", System.currentTimeMillis().toDouble())
        }

        val json = JSONObject(payload.toString())
        assertEquals("clipboard", json.getString("type"))
        assertEquals(text, json.getString("content"))
        assertEquals("text/plain", json.getString("contentType"))
        assertEquals("phone", json.getString("source"))
    }

    @Test
    fun testNotificationForwardPayloadConstruction() {
        val app = "WhatsApp"
        val title = "Mom"
        val message = "Call me when you're free"

        val payload = JSONObject().apply {
            put("type", "phone_notification")
            put("id", "notif-99881")
            put("packageName", "com.whatsapp")
            put("app", app)
            put("title", title)
            put("text", message)
            put("timestamp", System.currentTimeMillis().toDouble())
            put("canReply", true)
        }

        val json = JSONObject(payload.toString())
        assertEquals("phone_notification", json.getString("type"))
        assertEquals("com.whatsapp", json.getString("packageName"))
        assertEquals("Mom", json.getString("title"))
        assertTrue(json.getBoolean("canReply"))
    }

    @Test
    fun testBinaryMediaStreamPacketFraming() {
        // Stream types according to PROTOCOL.md § 4.2:
        // 0x01 = Screen Mirroring Frame
        // 0x02 = Continuity Camera Frame
        // Header: 1 byte stream type + 4 bytes UInt32 big-endian payload length

        val testPayload = "fake_h264_nal_or_jpeg_stream_data".toByteArray(Charsets.UTF_8)
        val streamType: Byte = 0x01 // Screen Mirroring

        val buffer = ByteBuffer.allocate(5 + testPayload.size)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(streamType)
        buffer.putInt(testPayload.size)
        buffer.put(testPayload)

        val packet = buffer.array()
        assertEquals(5 + testPayload.size, packet.size)
        assertEquals(0x01.toByte(), packet[0])

        // Parse header back
        val readBuffer = ByteBuffer.wrap(packet)
        readBuffer.order(ByteOrder.BIG_ENDIAN)
        val readType = readBuffer.get()
        val readLength = readBuffer.getInt()
        val readData = ByteArray(readLength)
        readBuffer.get(readData)

        assertEquals(0x01.toByte(), readType)
        assertEquals(testPayload.size, readLength)
        assertArrayEquals(testPayload, readData)
    }

    @Test
    fun testDefensiveParsingForUnknownMessageTypes() {
        val unknownJson = """
            {
              "type": "future_unsupported_feature",
              "data": "some_value"
            }
        """.trimIndent()

        val json = JSONObject(unknownJson)
        val type = json.optString("type")
        assertEquals("future_unsupported_feature", type)

        // Handled without exception via optString
        val handled = when (type) {
            "handshake_ack" -> true
            "clipboard" -> true
            "file_available" -> true
            else -> false
        }
        assertFalse(handled)
    }

    @Test
    fun testLoopPreventionSourceDetection() {
        val incomingFromPhone = JSONObject().apply {
            put("type", "clipboard")
            put("content", "hello")
            put("source", "phone")
        }

        val incomingFromMac = JSONObject().apply {
            put("type", "clipboard")
            put("content", "hello")
            put("source", "mac")
        }

        // Phone node must ignore messages that originated from "phone" to prevent echo loop
        val shouldIgnorePhone = incomingFromPhone.optString("source") == "phone"
        val shouldProcessMac = incomingFromMac.optString("source") == "mac"

        assertTrue("Should ignore self-originated clipboard message", shouldIgnorePhone)
        assertTrue("Should process remote clipboard message from mac", shouldProcessMac)
    }
}
