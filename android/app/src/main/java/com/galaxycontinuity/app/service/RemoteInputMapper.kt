package com.galaxycontinuity.app.service

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent

/**
 * Pure Kotlin input coordinate clamping, gesture mapping, and keycode translation logic.
 * Decoupled from Android OS runtime to facilitate JVM testing.
 */
object RemoteInputMapper {

    data class StrokeCoordinates(
        val startX: Float,
        val startY: Float,
        val endX: Float,
        val endY: Float,
        val durationMs: Long
    )

    /**
     * Clamps normalized coordinates to [0.0, 1.0] and maps to display pixels.
     */
    fun mapCoordinates(
        rawX: Double,
        rawY: Double,
        displayWidth: Int,
        displayHeight: Int
    ): Pair<Float, Float> {
        val clampedX = rawX.coerceIn(0.0, 1.0)
        val clampedY = rawY.coerceIn(0.0, 1.0)
        val pixelX = (clampedX * displayWidth).toFloat()
        val pixelY = (clampedY * displayHeight).toFloat()
        return Pair(pixelX, pixelY)
    }

    /**
     * Defensively calculates gesture stroke coordinates and duration for an "up" event.
     * If downTime == 0L (missed or dropped "down" event), returns an in-place tap at (pixelX, pixelY)
     * with a safe 50ms duration, completely preventing diagonal drag gestures from (0, 0).
     */
    fun resolveUpStroke(
        pixelX: Float,
        pixelY: Float,
        downX: Float?,
        downY: Float?,
        downTime: Long,
        currentTime: Long = System.currentTimeMillis()
    ): StrokeCoordinates {
        val isMissedDown = downTime == 0L || downX == null || downY == null
        val startX = if (isMissedDown) pixelX else downX!!
        val startY = if (isMissedDown) pixelY else downY!!
        val duration = if (isMissedDown) 50L else (currentTime - downTime).coerceIn(20L, 400L)
        return StrokeCoordinates(startX, startY, pixelX, pixelY, duration)
    }

    /**
     * Resolves an incoming key name or integer keyCode to an AccessibilityService global action
     * (e.g. GLOBAL_ACTION_BACK, GLOBAL_ACTION_HOME, GLOBAL_ACTION_RECENTS).
     * Returns null if the key is not mapped to an accessibility global action.
     */
    fun mapToGlobalAction(keyName: String?, keyCode: Int?): Int? {
        val nameUpper = keyName?.uppercase()?.trim()

        if (nameUpper == "BACK" || keyCode == KeyEvent.KEYCODE_BACK) {
            return AccessibilityService.GLOBAL_ACTION_BACK
        }
        if (nameUpper == "HOME" || keyCode == KeyEvent.KEYCODE_HOME) {
            return AccessibilityService.GLOBAL_ACTION_HOME
        }
        if (nameUpper == "RECENTS" || nameUpper == "APP_SWITCH" || keyCode == KeyEvent.KEYCODE_APP_SWITCH) {
            return AccessibilityService.GLOBAL_ACTION_RECENTS
        }
        if (nameUpper == "NOTIFICATIONS") {
            return AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
        }
        if (nameUpper == "QUICK_SETTINGS") {
            return AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS
        }
        if (nameUpper == "POWER" || nameUpper == "LOCK") {
            return AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
        }
        return null
    }

    /**
     * Validates whether an action string is a recognized input gesture.
     */
    fun isValidAction(action: String): Boolean {
        return when (action.lowercase().trim()) {
            "down", "move", "up", "scroll" -> true
            else -> false
        }
    }
}
