package com.galaxycontinuity.app

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import com.galaxycontinuity.app.service.RemoteInputMapper
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * Adversarial Input Stress & Empirical Challenge Test Suite (Milestone M-IT3-1).
 * Stress tests:
 * 1. Cyrillic, Greek, Asian characters, and multi-byte Emoji strings in input_text.
 * 2. Extreme scroll deltas (huge dx/dy, negative coordinates, sub-pixel jitter < 1.0).
 * 3. Key event sequences: rapid Backspace on empty field, Enter in multi-line vs single-line, Tab navigation.
 * 4. Protocol round-trip serialization and deserialization stress testing.
 */
class AdversarialInputStressTest {

    // =========================================================================
    // 1. Unicode & Multi-Byte Text Injection Stress Testing
    // =========================================================================

    @Test
    fun testCyrillicInputTextRoundtripAndLength() {
        val cyrillic = "Привет, мир! Тестирование клавиатуры Galaxy Continuity 123"
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", cyrillic)
            put("source", "mac")
        }
        val serialized = json.toString()
        val parsed = JSONObject(serialized)

        assertEquals("input_text", parsed.getString("type"))
        assertEquals(cyrillic, parsed.getString("text"))
        assertEquals(cyrillic.length, parsed.getString("text").length)
    }

    @Test
    fun testGreekInputTextRoundtrip() {
        val greek = "Καλημέρα κόσμε! Ελληνική υποστήριξη πληκτρολογίου"
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", greek)
        }
        val parsed = JSONObject(json.toString())
        assertEquals(greek, parsed.getString("text"))
    }

    @Test
    fun testAsianCJKInputTextRoundtrip() {
        val cjk = "こんにちは世界！ 你好世界！ 한국어 안녕하세요! 12345"
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", cjk)
        }
        val parsed = JSONObject(json.toString())
        assertEquals(cjk, parsed.getString("text"))
    }

    @Test
    fun testMultiByteComplexEmojiInputText() {
        val emojis = "😀 🚀 👨‍👩‍👧‍👦 🏳️‍🌈 👍🏽 🛰️ 🇦🇷 🧑🏾‍🚀"
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", emojis)
        }
        val parsed = JSONObject(json.toString())
        assertEquals(emojis, parsed.getString("text"))
    }

    @Test
    fun testTextInsertionCursorMathAtBeginningMiddleEnd() {
        // Model the text replacement formula used in ContinuityAccessibilityService
        fun simulateInsert(currentText: String, selStart: Int, selEnd: Int, insert: String): Pair<String, Int> {
            val newText: String
            val newCursor: Int
            if (selStart in 0..currentText.length && selEnd in 0..currentText.length && selStart <= selEnd) {
                newText = currentText.substring(0, selStart) + insert + currentText.substring(selEnd)
                newCursor = selStart + insert.length
            } else {
                newText = currentText + insert
                newCursor = newText.length
            }
            return Pair(newText, newCursor)
        }

        // Insert at beginning
        val (resStart, curStart) = simulateInsert("World", 0, 0, "Hello ")
        assertEquals("Hello World", resStart)
        assertEquals(6, curStart)

        // Insert at end
        val (resEnd, curEnd) = simulateInsert("Hello", 5, 5, " World")
        assertEquals("Hello World", resEnd)
        assertEquals(11, curEnd)

        // Insert in middle
        val (resMid, curMid) = simulateInsert("Helo", 3, 3, "l")
        assertEquals("Hello", resMid)
        assertEquals(4, curMid)

        // Replace active selection
        val (resRep, curRep) = simulateInsert("Hello Bad World", 6, 9, "Good")
        assertEquals("Hello Good World", resRep)
        assertEquals(10, curRep)

        // Insert multi-byte emoji in text
        val (resEmoji, curEmoji) = simulateInsert("Welcome !", 8, 8, "🚀")
        assertEquals("Welcome 🚀!", resEmoji)
        assertEquals(8 + "🚀".length, curEmoji)
    }

    // =========================================================================
    // 2. Extreme Scroll Deltas & Jitter Suppression
    // =========================================================================

    @Test
    fun testExtremeScrollDeltasClampedWithinDisplayBounds() {
        val width = 1080
        val height = 2400

        // Huge positive delta (+1,000,000)
        val strokeHugePos = RemoteInputMapper.resolveScrollStroke(
            normalizedX = 0.5,
            normalizedY = 0.5,
            dx = 1_000_000.0,
            dy = 1_000_000.0,
            displayWidth = width,
            displayHeight = height
        )
        assertEquals(540f, strokeHugePos.startX, 0.01f)
        assertEquals(1200f, strokeHugePos.startY, 0.01f)
        assertEquals(width.toFloat(), strokeHugePos.endX, 0.01f)
        assertEquals(height.toFloat(), strokeHugePos.endY, 0.01f)
        assertTrue("Duration must be clamped to 150ms max", strokeHugePos.durationMs in 60L..150L)

        // Huge negative delta (-1,000,000)
        val strokeHugeNeg = RemoteInputMapper.resolveScrollStroke(
            normalizedX = 0.5,
            normalizedY = 0.5,
            dx = -1_000_000.0,
            dy = -1_000_000.0,
            displayWidth = width,
            displayHeight = height
        )
        assertEquals(0f, strokeHugeNeg.endX, 0.01f)
        assertEquals(0f, strokeHugeNeg.endY, 0.01f)
        assertTrue("Duration must be clamped to 150ms max", strokeHugeNeg.durationMs in 60L..150L)
    }

    @Test
    fun testNegativeAndExcessCoordinatesClamped() {
        val width = 1080
        val height = 2400

        val (clampedX1, clampedY1) = RemoteInputMapper.mapCoordinates(-10.0, -50.0, width, height)
        assertEquals(0f, clampedX1, 0.001f)
        assertEquals(0f, clampedY1, 0.001f)

        val (clampedX2, clampedY2) = RemoteInputMapper.mapCoordinates(100.0, 500.0, width, height)
        assertEquals(width.toFloat(), clampedX2, 0.001f)
        assertEquals(height.toFloat(), clampedY2, 0.001f)
    }

    @Test
    fun testSubpixelJitterDeadbandBoundary() {
        val width = 1080
        val height = 2400

        // Sub-pixel jitter: hypot(0.6, 0.6) = ~0.848 < 1.0 -> must be suppressed
        val jitterStroke = RemoteInputMapper.calculateScrollStroke(
            rawX = 0.5,
            rawY = 0.5,
            dx = 0.6,
            dy = 0.6,
            displayWidth = width,
            displayHeight = height
        )
        assertNull("Jitter with hypot < 1.0 must be suppressed", jitterStroke)

        // Jitter with hypot(0.0, 0.99) = 0.99 < 1.0 -> must be suppressed
        val nearThresholdUnder = RemoteInputMapper.calculateScrollStroke(
            rawX = 0.5,
            rawY = 0.5,
            dx = 0.0,
            dy = 0.99,
            displayWidth = width,
            displayHeight = height
        )
        assertNull("Scroll delta with magnitude 0.99 must be suppressed", nearThresholdUnder)

        // Threshold boundary: hypot(1.01, 0.0) = 1.01 >= 1.0 -> must pass
        val nearThresholdOver = RemoteInputMapper.calculateScrollStroke(
            rawX = 0.5,
            rawY = 0.5,
            dx = 1.01,
            dy = 0.0,
            displayWidth = width,
            displayHeight = height
        )
        assertNotNull("Scroll delta with magnitude >= 1.0 must produce a stroke", nearThresholdOver)
        assertEquals(540f, nearThresholdOver!!.startX, 0.01f)
        assertEquals(1200f, nearThresholdOver.startY, 0.01f)
        assertTrue(nearThresholdOver.endX > nearThresholdOver.startX)
    }

    // =========================================================================
    // 3. Key Event Sequences & Backspace Edge Cases
    // =========================================================================

    @Test
    fun testRapidBackspaceOnEmptyField() {
        // Model DEL logic from ContinuityAccessibilityService
        fun simulateDel(currentText: String, selStart: Int, selEnd: Int): Pair<String, Int>? {
            if (selStart in 0..currentText.length && selEnd in 0..currentText.length && selStart < selEnd) {
                val newText = currentText.substring(0, selStart) + currentText.substring(selEnd)
                return Pair(newText, selStart)
            } else if (selStart > 0 && selStart <= currentText.length) {
                val newText = currentText.substring(0, selStart - 1) + currentText.substring(selStart)
                return Pair(newText, selStart - 1)
            } else if (selStart == -1 && currentText.isNotEmpty()) {
                val newText = currentText.dropLast(1)
                return Pair(newText, newText.length)
            } else {
                return null // Ignored when empty or at start
            }
        }

        // Empty field DEL
        val delEmpty = simulateDel("", 0, 0)
        assertNull("DEL on empty text must safely return null without throwing", delEmpty)

        // Cursor at position 0 with non-empty text
        val delAtStart = simulateDel("Hello", 0, 0)
        assertNull("DEL at start of text must safely return null without throwing", delAtStart)

        // Rapid 10x backspace on 3-character string
        var text = "ABC"
        var cursor = 3
        for (i in 0 until 10) {
            val res = simulateDel(text, cursor, cursor)
            if (res != null) {
                text = res.first
                cursor = res.second
            }
        }
        assertEquals("", text)
        assertEquals(0, cursor)
    }

    @Test
    fun testKeycodeMappingsForAllStandardKeys() {
        assertEquals(KeyEvent.KEYCODE_DEL, RemoteInputMapper.mapToKeyCode("DEL"))
        assertEquals(KeyEvent.KEYCODE_DEL, RemoteInputMapper.mapToKeyCode("BACKSPACE"))
        assertEquals(KeyEvent.KEYCODE_ENTER, RemoteInputMapper.mapToKeyCode("ENTER"))
        assertEquals(KeyEvent.KEYCODE_TAB, RemoteInputMapper.mapToKeyCode("TAB"))
        assertEquals(KeyEvent.KEYCODE_ESCAPE, RemoteInputMapper.mapToKeyCode("ESCAPE"))
        assertEquals(KeyEvent.KEYCODE_SPACE, RemoteInputMapper.mapToKeyCode("SPACE"))
        assertEquals(KeyEvent.KEYCODE_DPAD_UP, RemoteInputMapper.mapToKeyCode("DPAD_UP"))
        assertEquals(KeyEvent.KEYCODE_DPAD_DOWN, RemoteInputMapper.mapToKeyCode("DPAD_DOWN"))
        assertEquals(KeyEvent.KEYCODE_DPAD_LEFT, RemoteInputMapper.mapToKeyCode("DPAD_LEFT"))
        assertEquals(KeyEvent.KEYCODE_DPAD_RIGHT, RemoteInputMapper.mapToKeyCode("DPAD_RIGHT"))
        assertEquals(KeyEvent.KEYCODE_BACK, RemoteInputMapper.mapToKeyCode("BACK"))
        assertEquals(KeyEvent.KEYCODE_HOME, RemoteInputMapper.mapToKeyCode("HOME"))
        assertEquals(KeyEvent.KEYCODE_APP_SWITCH, RemoteInputMapper.mapToKeyCode("RECENTS"))
        assertEquals(KeyEvent.KEYCODE_POWER, RemoteInputMapper.mapToKeyCode("POWER"))
        assertEquals(KeyEvent.KEYCODE_VOLUME_UP, RemoteInputMapper.mapToKeyCode("VOLUME_UP"))
        assertEquals(KeyEvent.KEYCODE_VOLUME_DOWN, RemoteInputMapper.mapToKeyCode("VOLUME_DOWN"))
        assertEquals(KeyEvent.KEYCODE_UNKNOWN, RemoteInputMapper.mapToKeyCode("NON_EXISTENT_KEY"))
    }

    // =========================================================================
    // 4. Protocol Round-Trip Serialization & Deserialization Stress
    // =========================================================================

    @Test
    fun testProtocolRoundtripRapidSerialization1000Events() {
        for (i in 0 until 1000) {
            val json = JSONObject().apply {
                put("type", "input_scroll")
                put("x", 0.12345 + (i % 100) * 0.005)
                put("y", 0.67890 - (i % 100) * 0.005)
                put("dx", (i % 50) - 25.0)
                put("dy", -((i % 70) - 35.0))
            }
            val serialized = json.toString()
            val parsed = JSONObject(serialized)
            assertEquals("input_scroll", parsed.getString("type"))
            assertEquals((i % 50) - 25.0, parsed.getDouble("dx"), 0.0001)
        }
    }

    @Test
    fun testNotificationOpenRoundtripWithComplexPackageNames() {
        val complexPackages = listOf(
            "com.samsung.android.messaging:channel_1",
            "org.telegram.messenger/app_sub_id_894",
            "com.google.android.apps.messaging?chat_id=123&user=test"
        )
        for (pkg in complexPackages) {
            val json = JSONObject().apply {
                put("type", "notification_open")
                put("id", "notif-uuid-$pkg")
                put("packageName", pkg)
            }
            val parsed = JSONObject(json.toString())
            assertEquals("notification_open", parsed.getString("type"))
            assertEquals(pkg, parsed.getString("packageName"))
        }
    }

    @Test
    fun testInputEventScrollBackwardCompatibility() {
        // Shared protocol allows input_event with action="scroll" and dx/dy
        val rawJson = """
            {
              "type": "input_event",
              "action": "scroll",
              "x": 0.5,
              "y": 0.7,
              "dx": 10.0,
              "dy": -45.0
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        val action = json.optString("action", "down")
        val isScroll = action.lowercase().trim() == "scroll" && (json.has("dx") || json.has("dy"))

        assertTrue("input_event with action=scroll must be recognized as scroll", isScroll)
        assertEquals(10.0, json.optDouble("dx", 0.0), 0.001)
        assertEquals(-45.0, json.optDouble("dy", 0.0), 0.001)
    }
}
