package com.galaxycontinuity.app.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.util.DisplayMetrics
import android.util.Log
import android.view.accessibility.AccessibilityEvent

class ContinuityAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ContinuityA11y"
        var instance: ContinuityAccessibilityService? = null
            private set
        val isServiceConnected: Boolean get() = instance != null
    }

    private var downX: Float = 0f
    private var downY: Float = 0f
    private var downTime: Long = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        try {
            val info = serviceInfo ?: android.accessibilityservice.AccessibilityServiceInfo()
            info.feedbackType = android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_GENERIC
            serviceInfo = info
        } catch (_: Exception) {}
        instance = this
        Log.d(TAG, "ContinuityAccessibilityService connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Event monitoring not required for input injection
    }

    override fun onInterrupt() {
        Log.d(TAG, "ContinuityAccessibilityService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        Log.d(TAG, "ContinuityAccessibilityService destroyed")
    }

    fun handleInputEvent(action: String, normalizedX: Double, normalizedY: Double, button: Int) {
        if (!RemoteInputMapper.isValidAction(action)) {
            Log.w(TAG, "Dropping unknown input action: $action")
            return
        }

        val metrics: DisplayMetrics = resources.displayMetrics
        val (pixelX, pixelY) = RemoteInputMapper.mapCoordinates(
            normalizedX,
            normalizedY,
            metrics.widthPixels,
            metrics.heightPixels
        )

        when (action.lowercase().trim()) {
            "down" -> {
                downX = pixelX
                downY = pixelY
                downTime = System.currentTimeMillis()
            }
            "move" -> {
                // If dragging, record first move coordinate if down was missed
                if (downTime == 0L) {
                    downX = pixelX
                    downY = pixelY
                    downTime = System.currentTimeMillis()
                }
            }
            "up" -> {
                val strokeCoords = RemoteInputMapper.resolveUpStroke(
                    pixelX = pixelX,
                    pixelY = pixelY,
                    downX = downX,
                    downY = downY,
                    downTime = downTime
                )

                val path = Path().apply {
                    moveTo(strokeCoords.startX, strokeCoords.startY)
                    lineTo(strokeCoords.endX, strokeCoords.endY)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, strokeCoords.durationMs)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        Log.d(TAG, "Gesture completed: ${strokeCoords.startX},${strokeCoords.startY} -> ${strokeCoords.endX},${strokeCoords.endY} (${strokeCoords.durationMs}ms)")
                    }
                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        Log.w(TAG, "Gesture cancelled: ${strokeCoords.startX},${strokeCoords.startY} -> ${strokeCoords.endX},${strokeCoords.endY}")
                    }
                }, null)
                Log.d(TAG, "dispatchGesture invoked: result=$dispatched")

                // Defensively reset down state
                downTime = 0L
                downX = 0f
                downY = 0f
            }
            "scroll" -> {
                // Scroll gesture: swipe from touch point
                val path = Path().apply {
                    moveTo(pixelX, pixelY)
                    lineTo(pixelX, (pixelY + 300).coerceAtMost(metrics.heightPixels.toFloat()))
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, 150)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                dispatchGesture(gesture, null, null)
            }
        }
    }

    fun handleKeyInput(key: String, keyCode: Int) {
        val globalAction = RemoteInputMapper.mapToGlobalAction(key, keyCode)
        if (globalAction != null) {
            val result = performGlobalAction(globalAction)
            Log.d(TAG, "Injected global action $globalAction for key $key (result: $result)")
        } else {
            Log.d(TAG, "No global action mapping for key: $key, keyCode: $keyCode")
        }
    }
}
