package com.galaxycontinuity.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ContinuityCameraUnitTest {

    @Test
    fun testCameraStartMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_start")
            put("lens", "front")
            put("quality", "1080p")
            put("fps", 30)
        }

        assertEquals("camera_start", json.getString("type"))
        assertEquals("front", json.optString("lens"))
        assertEquals("1080p", json.optString("quality"))
        assertEquals(30, json.optInt("fps"))
    }

    @Test
    fun testCameraStartFacingResolutionAliases() {
        val json = JSONObject().apply {
            put("type", "camera_start")
            put("facing", "back")
            put("resolution", "720p")
        }

        val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")
        val quality = if (json.has("quality")) json.getString("quality") else json.optString("resolution", "1080p")

        assertEquals("back", lens)
        assertEquals("720p", quality)
    }

    @Test
    fun testCameraControlMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_control")
            put("action", "set_zoom")
            put("zoom", 2.5)
            put("torch", true)
        }

        assertEquals("camera_control", json.getString("type"))
        assertEquals("set_zoom", json.getString("action"))
        assertEquals(2.5, json.getDouble("zoom"), 0.01)
        assertTrue(json.getBoolean("torch"))
    }

    @Test
    fun testCameraSwitchLensAliasParsing() {
        val json = JSONObject().apply {
            put("type", "camera_switch_lens")
            put("facing", "front")
        }

        val action = json.optString("action", if (json.getString("type") == "camera_switch_lens") "switch_lens" else "")
        val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")

        assertEquals("switch_lens", action)
        assertEquals("front", lens)
    }

    @Test
    fun testCameraStopMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_stop")
        }
        assertEquals("camera_stop", json.getString("type"))
    }
}
