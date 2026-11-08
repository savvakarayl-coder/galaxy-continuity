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

    data class ScrollStroke(
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
     * Translates trackpad scroll deltas (dx, dy) into touch drag swipe coordinates.
     * macOS natural scrolling:
     * - scrolling down produces negative scrollingDeltaY -> swipes upwards (endY < startY).
     * - scrolling up produces positive scrollingDeltaY -> swipes downwards (endY > startY).
     */
    fun resolveScrollStroke(
        normalizedX: Double,
        normalizedY: Double,
        dx: Double,
        dy: Double,
        displayWidth: Int,
        displayHeight: Int,
        scaleMultiplier: Float = 3.0f
    ): ScrollStroke {
        val (startX, startY) = mapCoordinates(normalizedX, normalizedY, displayWidth, displayHeight)

        val moveX = (dx * scaleMultiplier).toFloat()
        val moveY = (dy * scaleMultiplier).toFloat()

        val endX = (startX + moveX).coerceIn(0f, displayWidth.toFloat())
        val endY = (startY + moveY).coerceIn(0f, displayHeight.toFloat())

        val magnitude = kotlin.math.hypot(moveX.toDouble(), moveY.toDouble())
        val duration = (60L + (magnitude / 5.0).toLong()).coerceIn(60L, 150L)

        return ScrollStroke(startX, startY, endX, endY, duration)
    }

    /**
     * Calculates scroll stroke with deadband suppression for microscopic trackpad jitter.
     */
    fun calculateScrollStroke(
        rawX: Double,
        rawY: Double,
        dx: Double,
        dy: Double,
        displayWidth: Int,
        displayHeight: Int,
        scaleFactor: Float = 3.0f
    ): ScrollStroke? {
        if (kotlin.math.hypot(dx, dy) < 1.0) {
            return null
        }
        return resolveScrollStroke(rawX, rawY, dx, dy, displayWidth, displayHeight, scaleFactor)
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
     * Maps key string name to Android KeyEvent integer keycode.
     */
    fun mapToKeyCode(keyName: String): Int {
        return when (keyName.uppercase().trim()) {
            "DEL", "BACKSPACE" -> KeyEvent.KEYCODE_DEL
            "ENTER", "RETURN" -> KeyEvent.KEYCODE_ENTER
            "TAB" -> KeyEvent.KEYCODE_TAB
            "ESCAPE", "ESC" -> KeyEvent.KEYCODE_ESCAPE
            "SPACE" -> KeyEvent.KEYCODE_SPACE
            "DPAD_UP", "UP" -> KeyEvent.KEYCODE_DPAD_UP
            "DPAD_DOWN", "DOWN" -> KeyEvent.KEYCODE_DPAD_DOWN
            "DPAD_LEFT", "LEFT" -> KeyEvent.KEYCODE_DPAD_LEFT
            "DPAD_RIGHT", "RIGHT" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "BACK" -> KeyEvent.KEYCODE_BACK
            "HOME" -> KeyEvent.KEYCODE_HOME
            "RECENTS", "APP_SWITCH" -> KeyEvent.KEYCODE_APP_SWITCH
            "NOTIFICATIONS" -> KeyEvent.KEYCODE_NOTIFICATION
            "POWER", "LOCK" -> KeyEvent.KEYCODE_POWER
            "VOLUME_UP" -> KeyEvent.KEYCODE_VOLUME_UP
            "VOLUME_DOWN" -> KeyEvent.KEYCODE_VOLUME_DOWN
            else -> KeyEvent.KEYCODE_UNKNOWN
        }
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
