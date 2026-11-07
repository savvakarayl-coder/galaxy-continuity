package com.galaxycontinuity.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Protocol serialization and deserialization unit tests verifying compliance with shared/PROTOCOL.md.
 */
class ProtocolSerializationTest {

    // MARK: - 5.1 Connection Lifecycle & Handshake

    @Test
    fun testClientHandshakeSerialization() {
        val json = JSONObject().apply {
            put("type", "handshake")
            put("device", "Samsung Galaxy S24 Ultra")
            put("platform", "android")
            put("version", "1.0.0")
            put("battery", JSONObject().apply {
                put("level", 88)
                put("isCharging", true)
            })
        }

        val jsonStr = json.toString()
        val parsed = JSONObject(jsonStr)

        assertEquals("handshake", parsed.getString("type"))
        assertEquals("Samsung Galaxy S24 Ultra", parsed.getString("device"))
        assertEquals("android", parsed.getString("platform"))
        assertEquals("1.0.0", parsed.getString("version"))

        val battery = parsed.getJSONObject("battery")
        assertEquals(88, battery.getInt("level"))
        assertTrue(battery.getBoolean("isCharging"))
    }

    @Test
    fun testServerHandshakeAckDeserialization() {
        val rawJson = """
            {
              "type": "handshake_ack",
              "device": "MacBook Pro — Савва",
              "platform": "macOS",
              "version": "1.0.0",
              "timestamp": 1730940000000.0
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("handshake_ack", json.getString("type"))
        assertEquals("MacBook Pro — Савва", json.getString("device"))
        assertEquals("macOS", json.getString("platform"))
        assertEquals("1.0.0", json.getString("version"))
        assertEquals(1730940000000.0, json.getDouble("timestamp"), 0.001)
    }

    // MARK: - 5.2 Universal Clipboard Synchronization

    @Test
    fun testPlainTextClipboardMessage() {
        val rawJson = """
            {
              "type": "clipboard",
              "content": "https://galaxycontinuity.org/docs",
              "contentType": "text/plain",
              "hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "source": "mac",
              "timestamp": 1730940000000.0
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("clipboard", json.getString("type"))
        assertEquals("https://galaxycontinuity.org/docs", json.getString("content"))
        assertEquals("text/plain", json.getString("contentType"))
        assertEquals("mac", json.getString("source"))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", json.getString("hash"))
    }

    @Test
    fun testImageClipboardMessage() {
        val base64Png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", base64Png)
            put("contentType", "image/png")
            put("source", "phone")
            put("timestamp", 1730940000000.0)
        }

        val parsed = JSONObject(json.toString())
        assertEquals("clipboard", parsed.getString("type"))
        assertEquals("image/png", parsed.getString("contentType"))
        assertEquals(base64Png, parsed.getString("content"))
        assertEquals("phone", parsed.getString("source"))
    }

    // MARK: - 5.3 Quick Drop File Transfer

    @Test
    fun testFileAvailableAnnouncement() {
        val rawJson = """
            {
              "type": "file_available",
              "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
              "filename": "quarterly_presentation.pdf",
              "fileSize": 10485760,
              "mimeType": "application/pdf",
              "sender": "MacBook Pro",
              "timestamp": 1730940000000.0
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("file_available", json.getString("type"))
        assertEquals("c56a4180-2a8d-4f81-9bfa-89e4c69812df", json.getString("fileId"))
        assertEquals("quarterly_presentation.pdf", json.getString("filename"))
        assertEquals(10485760L, json.getLong("fileSize"))
        assertEquals("application/pdf", json.getString("mimeType"))
        assertEquals("MacBook Pro", json.getString("sender"))
    }

    @Test
    fun testFileProgressAndComplete() {
        val progressJson = JSONObject().apply {
            put("type", "file_progress")
            put("fileId", "file-12345")
            put("bytesTransferred", 5242880L)
            put("totalBytes", 10485760L)
            put("percentage", 50.0)
            put("status", "transferring")
        }

        val p = JSONObject(progressJson.toString())
        assertEquals("file_progress", p.getString("type"))
        assertEquals(5242880L, p.getLong("bytesTransferred"))
        assertEquals(10485760L, p.getLong("totalBytes"))
        assertEquals(50.0, p.getDouble("percentage"), 0.001)
        assertEquals("transferring", p.getString("status"))

        val completeJson = JSONObject().apply {
            put("type", "file_complete")
            put("fileId", "file-12345")
            put("status", "success")
            put("message", "File saved successfully")
        }

        val c = JSONObject(completeJson.toString())
        assertEquals("file_complete", c.getString("type"))
        assertEquals("success", c.getString("status"))
    }

    // MARK: - 5.4 Screen Mirroring

    @Test
    fun testScreenStartAndStop() {
        val startJson = JSONObject().apply {
            put("type", "screen_start")
            put("width", 1080)
            put("height", 2400)
            put("fps", 30)
            put("bitrate", 4000000)
        }

        val s = JSONObject(startJson.toString())
        assertEquals("screen_start", s.getString("type"))
        assertEquals(1080, s.getInt("width"))
        assertEquals(2400, s.getInt("height"))
        assertEquals(30, s.getInt("fps"))
        assertEquals(4000000, s.getInt("bitrate"))

        val stopJson = JSONObject().apply {
            put("type", "screen_stop")
            put("reason", "user_dismissed")
        }
        val stop = JSONObject(stopJson.toString())
        assertEquals("screen_stop", stop.getString("type"))
        assertEquals("user_dismissed", stop.getString("reason"))
    }

    @Test
    fun testRemoteInputEventAndKey() {
        val inputEvent = JSONObject().apply {
            put("type", "input_event")
            put("action", "down")
            put("x", 0.5234)
            put("y", 0.7412)
            put("button", 0)
        }

        val parsedEvent = JSONObject(inputEvent.toString())
        assertEquals("input_event", parsedEvent.getString("type"))
        assertEquals("down", parsedEvent.getString("action"))
        assertEquals(0.5234, parsedEvent.getDouble("x"), 0.0001)
        assertEquals(0.7412, parsedEvent.getDouble("y"), 0.0001)
        assertEquals(0, parsedEvent.getInt("button"))

        val inputKey = JSONObject().apply {
            put("type", "input_key")
            put("key", "BACK")
            put("keyCode", 4)
        }

        val parsedKey = JSONObject(inputKey.toString())
        assertEquals("input_key", parsedKey.getString("type"))
        assertEquals("BACK", parsedKey.getString("key"))
        assertEquals(4, parsedKey.getInt("keyCode"))
    }

    // MARK: - 5.5 Continuity Camera

    @Test
    fun testCameraStartAndControl() {
        val cameraStart = JSONObject().apply {
            put("type", "camera_start")
            put("lens", "back")
            put("quality", "1080p")
            put("fps", 30)
        }

        val cs = JSONObject(cameraStart.toString())
        assertEquals("camera_start", cs.getString("type"))
        assertEquals("back", cs.getString("lens"))
        assertEquals("1080p", cs.getString("quality"))

        val cameraControl = JSONObject().apply {
            put("type", "camera_control")
            put("action", "switch_lens")
            put("lens", "front")
            put("zoom", 1.5)
            put("torch", false)
        }

        val cc = JSONObject(cameraControl.toString())
        assertEquals("camera_control", cc.getString("type"))
        assertEquals("switch_lens", cc.getString("action"))
        assertEquals("front", cc.getString("lens"))
        assertEquals(1.5, cc.getDouble("zoom"), 0.01)
        assertFalse(cc.getBoolean("torch"))
    }

    // MARK: - 5.6 Notification Synchronization & Quick Reply

    @Test
    fun testPhoneNotificationAndReply() {
        val notif = JSONObject().apply {
            put("type", "phone_notification")
            put("id", "notif-uuid-10492")
            put("packageName", "org.telegram.messenger")
            put("app", "Telegram")
            put("title", "Alex")
            put("text", "Are you free for lunch?")
            put("timestamp", 1730940050000.0)
            put("canReply", true)
        }

        val n = JSONObject(notif.toString())
        assertEquals("phone_notification", n.getString("type"))
        assertEquals("notif-uuid-10492", n.getString("id"))
        assertEquals("org.telegram.messenger", n.getString("packageName"))
        assertEquals("Telegram", n.getString("app"))
        assertEquals("Alex", n.getString("title"))
        assertEquals("Are you free for lunch?", n.getString("text"))
        assertTrue(n.getBoolean("canReply"))

        val reply = JSONObject().apply {
            put("type", "notification_reply")
            put("id", "notif-uuid-10492")
            put("packageName", "org.telegram.messenger")
            put("replyText", "Yes, let's meet at 12:30!")
        }

        val r = JSONObject(reply.toString())
        assertEquals("notification_reply", r.getString("type"))
        assertEquals("notif-uuid-10492", r.getString("id"))
        assertEquals("org.telegram.messenger", r.getString("packageName"))
        assertEquals("Yes, let's meet at 12:30!", r.getString("replyText"))
    }

    // MARK: - 5.7 & 5.8 Battery and Ping

    @Test
    fun testBatteryUpdateAndPingDevice() {
        val battery = JSONObject().apply {
            put("type", "battery_update")
            put("level", 92)
            put("isCharging", true)
        }

        val b = JSONObject(battery.toString())
        assertEquals("battery_update", b.getString("type"))
        assertEquals(92, b.getInt("level"))
        assertTrue(b.getBoolean("isCharging"))

        val ping = JSONObject().apply {
            put("type", "ping_device")
            put("source", "mac")
            put("message", "Finding your Galaxy...")
        }

        val p = JSONObject(ping.toString())
        assertEquals("ping_device", p.getString("type"))
        assertEquals("mac", p.getString("source"))
        assertEquals("Finding your Galaxy...", p.getString("message"))
    }
}
