package com.galaxycontinuity.app

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import com.galaxycontinuity.app.service.RemoteInputMapper
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ScreenMirroringUnitTest {

    @Test
    fun testScreenStartMessageParsing() {
        val json = JSONObject().apply {
            put("type", "screen_start")
            put("width", 1080)
            put("height", 2400)
            put("fps", 60)
            put("bitrate", 6000000)
        }

        assertEquals("screen_start", json.getString("type"))
        assertEquals(1080, json.optInt("width", 1080))
        assertEquals(2400, json.optInt("height", 2400))
        assertEquals(60, json.optInt("fps", 30))
        assertEquals(6000000, json.optInt("bitrate", 4000000))
    }

    @Test
    fun testScreenStopMessageParsing() {
        val json = JSONObject().apply {
            put("type", "screen_stop")
            put("reason", "user_dismissed")
        }

        assertEquals("screen_stop", json.getString("type"))
        assertEquals("user_dismissed", json.optString("reason"))
    }

    @Test
    fun testCoordinateClampingNegative() {
        val (x, y) = RemoteInputMapper.mapCoordinates(-0.5, -0.2, 1080, 2400)
        assertEquals(0f, x, 0.001f)
        assertEquals(0f, y, 0.001f)
    }

    @Test
    fun testCoordinateClampingExcess() {
        val (x, y) = RemoteInputMapper.mapCoordinates(1.5, 2.0, 1080, 2400)
        assertEquals(1080f, x, 0.001f)
        assertEquals(2400f, y, 0.001f)
    }

    @Test
    fun testCoordinateNormalMapping() {
        val (x, y) = RemoteInputMapper.mapCoordinates(0.5, 0.25, 1080, 2400)
        assertEquals(540f, x, 0.001f)
        assertEquals(600f, y, 0.001f)
    }

    @Test
    fun testGlobalActionKeyMapping() {
        assertEquals(AccessibilityService.GLOBAL_ACTION_BACK, RemoteInputMapper.mapToGlobalAction("BACK", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_BACK, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_BACK))

        assertEquals(AccessibilityService.GLOBAL_ACTION_HOME, RemoteInputMapper.mapToGlobalAction("HOME", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_HOME, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_HOME))

        assertEquals(AccessibilityService.GLOBAL_ACTION_RECENTS, RemoteInputMapper.mapToGlobalAction("RECENTS", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_RECENTS, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_APP_SWITCH))

        assertEquals(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN, RemoteInputMapper.mapToGlobalAction("POWER", null))
        assertNull(RemoteInputMapper.mapToGlobalAction("UNKNOWN_KEY", 9999))
    }

    @Test
    fun testValidActionValidation() {
        assertTrue(RemoteInputMapper.isValidAction("down"))
        assertTrue(RemoteInputMapper.isValidAction("move"))
        assertTrue(RemoteInputMapper.isValidAction("up"))
        assertTrue(RemoteInputMapper.isValidAction("scroll"))
        assertFalse(RemoteInputMapper.isValidAction("invalid_action"))
    }

    @Test
    fun testResolveUpStrokeWithNormalDown() {
        // Normal down event preceded up
        val downTime = 1000L
        val currentTime = 1150L
        val stroke = RemoteInputMapper.resolveUpStroke(
            pixelX = 500f,
            pixelY = 600f,
            downX = 100f,
            downY = 200f,
            downTime = downTime,
            currentTime = currentTime
        )

        assertEquals(100f, stroke.startX, 0.001f)
        assertEquals(200f, stroke.startY, 0.001f)
        assertEquals(500f, stroke.endX, 0.001f)
        assertEquals(600f, stroke.endY, 0.001f)
        assertEquals(150L, stroke.durationMs)
    }

    @Test
    fun testResolveUpStrokeDefensiveGuardForMissedDown() {
        // Missed down event (downTime == 0L)
        val stroke = RemoteInputMapper.resolveUpStroke(
            pixelX = 540f,
            pixelY = 1200f,
            downX = 0f,
            downY = 0f,
            downTime = 0L,
            currentTime = 1730940000000L
        )

        // Must produce an in-place tap at (540, 1200), NOT a diagonal drag from (0, 0)
        assertEquals(540f, stroke.startX, 0.001f)
        assertEquals(1200f, stroke.startY, 0.001f)
        assertEquals(540f, stroke.endX, 0.001f)
        assertEquals(1200f, stroke.endY, 0.001f)
        assertEquals(50L, stroke.durationMs)
    }

    @Test
    fun testResolveUpStrokeDurationClamping() {
        // Long drag held for 2000ms should clamp to 400ms max
        val stroke = RemoteInputMapper.resolveUpStroke(
            pixelX = 300f,
            pixelY = 400f,
            downX = 100f,
            downY = 200f,
            downTime = 1000L,
            currentTime = 3000L
        )
        assertEquals(400L, stroke.durationMs)

        // Ultra-short tap (< 20ms) should clamp to 20ms min
        val quickStroke = RemoteInputMapper.resolveUpStroke(
            pixelX = 300f,
            pixelY = 400f,
            downX = 300f,
            downY = 400f,
            downTime = 1000L,
            currentTime = 1005L
        )
        assertEquals(20L, quickStroke.durationMs)
    }
}
