package com.galaxycontinuity.app.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.DisplayMetrics
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

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
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            serviceInfo = info
        } catch (_: Exception) {}
        instance = this
        Log.d(TAG, "ContinuityAccessibilityService connected with interactive windows retrieval enabled")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Trigger clipboard synchronization on relevant user interaction events
        when (event?.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                ContinuityService.activeClipboardSync?.checkAndSyncClipboard()
            }
        }
    }

    override fun onInterrupt() {
        Log.d(TAG, "ContinuityAccessibilityService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        Log.d(TAG, "ContinuityAccessibilityService destroyed")
    }

    fun handleInputEvent(
        action: String,
        normalizedX: Double,
        normalizedY: Double,
        button: Int,
        dx: Double = 0.0,
        dy: Double = 0.0
    ) {
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

                downTime = 0L
                downX = 0f
                downY = 0f
            }
            "scroll" -> {
                handleScroll(normalizedX, normalizedY, dx, if (dy != 0.0) dy else -50.0)
            }
        }
    }

    /**
     * Locates the active focused input node in the active window or interactive window tree.
     */
    fun findActiveInputNode(): AccessibilityNodeInfo? {
        try {
            val inputFocus = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (inputFocus != null) return inputFocus
        } catch (e: Exception) {
            Log.w(TAG, "findFocus(FOCUS_INPUT) failed: ${e.message}")
        }

        try {
            val root = rootInActiveWindow
            val rootFocus = root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (rootFocus != null) return rootFocus
        } catch (e: Exception) {
            Log.w(TAG, "rootInActiveWindow.findFocus failed: ${e.message}")
        }

        try {
            val winList = windows
            for (win in winList) {
                val winRoot = win.root ?: continue
                val winFocus = winRoot.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (winFocus != null) return winFocus
                val scanned = scanForEditable(winRoot)
                if (scanned != null) return scanned
            }
        } catch (e: Exception) {
            Log.w(TAG, "windows scan failed: ${e.message}")
        }

        try {
            val root = rootInActiveWindow
            if (root != null) {
                val scanned = scanForEditable(root)
                if (scanned != null) return scanned
            }
        } catch (e: Exception) {
            Log.w(TAG, "root scan failed: ${e.message}")
        }

        return null
    }

    private fun scanForEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isFocused && (node.isEditable || node.className?.contains("EditText", ignoreCase = true) == true)) {
            return node
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = scanForEditable(child)
            if (result != null) return result
        }
        return null
    }

    /**
     * Injects text directly into the active input node via ACTION_SET_TEXT and ACTION_SET_SELECTION.
     * Falls back to clipboard paste (ACTION_PASTE) if ACTION_SET_TEXT fails or node is missing.
     */
    fun handleTextInput(text: String) {
        if (text.isEmpty()) return
        val node = findActiveInputNode()
        if (node != null) {
            val currentText = node.text?.toString() ?: ""
            val selStart = node.textSelectionStart
            val selEnd = node.textSelectionEnd

            val newText: String
            val newCursor: Int

            if (selStart in 0..currentText.length && selEnd in 0..currentText.length && selStart <= selEnd) {
                newText = currentText.substring(0, selStart) + text + currentText.substring(selEnd)
                newCursor = selStart + text.length
            } else {
                newText = currentText + text
                newCursor = newText.length
            }

            val textArgs = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
            }
            val textSet = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, textArgs)
            if (textSet) {
                val selArgs = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursor)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursor)
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
                Log.d(TAG, "Successfully injected text via ACTION_SET_TEXT: $text")
                return
            }
        }

        // Fallback: Copy to clipboard and execute ACTION_PASTE
        Log.w(TAG, "ACTION_SET_TEXT unavailable or node not found, falling back to ACTION_PASTE for: $text")
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = ClipData.newPlainText("Continuity Remote Text", text)
            clipboard?.setPrimaryClip(clip)

            val pasteNode = node ?: findActiveInputNode()
            val pasted = pasteNode?.performAction(AccessibilityNodeInfo.ACTION_PASTE) ?: false
            Log.d(TAG, "Fallback ACTION_PASTE result: $pasted")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to execute fallback paste", e)
        }
    }

    /**
     * Handles keyboard events including editing keys (DEL, Enter, Tab, Space, Escape, Arrows)
     * and system navigation global actions.
     */
    fun handleKeyInput(key: String, keyCode: Int) {
        val keyUpper = key.uppercase().trim()

        // 0. Check WAKEUP / UNLOCK action
        if (keyUpper == "WAKEUP" || keyCode == 224) {
            wakeUpAndUnlock()
            return
        }

        // 1. Check Global Actions (BACK, HOME, RECENTS, NOTIFICATIONS, QUICK_SETTINGS, POWER/LOCK)
        val globalAction = RemoteInputMapper.mapToGlobalAction(key, keyCode)
        if (globalAction != null) {
            val result = performGlobalAction(globalAction)
            Log.d(TAG, "Injected global action $globalAction for key $key (result: $result)")
            return
        }

        // 2. Escape (111) -> Back / dismiss dialogs
        if (keyUpper == "ESCAPE" || keyUpper == "ESC" || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            val result = performGlobalAction(GLOBAL_ACTION_BACK)
            Log.d(TAG, "Escape key handled via GLOBAL_ACTION_BACK (result: $result)")
            return
        }

        // 3. Space (62) -> Text insertion
        if (keyUpper == "SPACE" || key == " " || keyCode == KeyEvent.KEYCODE_SPACE) {
            handleTextInput(" ")
            return
        }

        // 4. Backspace / DEL (67)
        if (keyUpper == "BACKSPACE" || keyUpper == "DEL" || keyCode == KeyEvent.KEYCODE_DEL) {
            val node = findActiveInputNode()
            if (node != null) {
                val currentText = node.text?.toString() ?: ""
                val selStart = node.textSelectionStart
                val selEnd = node.textSelectionEnd

                val newText: String
                val newCursor: Int

                if (selStart in 0..currentText.length && selEnd in 0..currentText.length && selStart < selEnd) {
                    newText = currentText.substring(0, selStart) + currentText.substring(selEnd)
                    newCursor = selStart
                } else if (selStart > 0 && selStart <= currentText.length) {
                    newText = currentText.substring(0, selStart - 1) + currentText.substring(selStart)
                    newCursor = selStart - 1
                } else if (selStart == -1 && currentText.isNotEmpty()) {
                    newText = currentText.dropLast(1)
                    newCursor = newText.length
                } else {
                    Log.d(TAG, "DEL pressed but cursor at start or text empty")
                    return
                }

                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
                }
                if (node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                    val selArgs = Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursor)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursor)
                    }
                    node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
                    Log.d(TAG, "DEL handled, new text length: ${newText.length}")
                }
            } else {
                Log.w(TAG, "DEL ignored: no active input node")
            }
            return
        }

        // 5. Enter / IME Action (66)
        if (keyUpper == "ENTER" || keyUpper == "RETURN" || keyCode == KeyEvent.KEYCODE_ENTER) {
            val node = findActiveInputNode()
            var imeHandled = false
            if (node != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                imeHandled = node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                Log.d(TAG, "ACTION_IME_ENTER result: $imeHandled")
            }
            if (!imeHandled) {
                handleTextInput("\n")
            }
            return
        }

        // 6. Tab (61)
        if (keyUpper == "TAB" || keyCode == KeyEvent.KEYCODE_TAB) {
            val node = findActiveInputNode()
            val nextNode = node?.focusSearch(View.FOCUS_FORWARD)
            if (nextNode != null && nextNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) {
                Log.d(TAG, "Tab handled via focusSearch(FOCUS_FORWARD)")
            } else {
                handleTextInput("\t")
            }
            return
        }

        // 7. Arrow / Navigation keys (DPAD: UP=19, DOWN=20, LEFT=21, RIGHT=22)
        val isDpad = keyUpper.startsWith("DPAD_") || keyCode in 19..22
        if (isDpad) {
            val node = findActiveInputNode()
            if (node != null && node.isEditable) {
                val currentText = node.text?.toString() ?: ""
                val selStart = node.textSelectionStart.takeIf { it >= 0 } ?: currentText.length
                val newPos = when {
                    keyUpper == "DPAD_LEFT" || keyCode == KeyEvent.KEYCODE_DPAD_LEFT -> (selStart - 1).coerceAtLeast(0)
                    keyUpper == "DPAD_RIGHT" || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT -> (selStart + 1).coerceAtMost(currentText.length)
                    keyUpper == "DPAD_UP" || keyCode == KeyEvent.KEYCODE_DPAD_UP -> 0
                    keyUpper == "DPAD_DOWN" || keyCode == KeyEvent.KEYCODE_DPAD_DOWN -> currentText.length
                    else -> selStart
                }
                val selArgs = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newPos)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newPos)
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
                Log.d(TAG, "Arrow key navigated cursor to $newPos")
                return
            } else {
                val direction = when {
                    keyUpper == "DPAD_UP" || keyCode == KeyEvent.KEYCODE_DPAD_UP -> View.FOCUS_UP
                    keyUpper == "DPAD_DOWN" || keyCode == KeyEvent.KEYCODE_DPAD_DOWN -> View.FOCUS_DOWN
                    keyUpper == "DPAD_LEFT" || keyCode == KeyEvent.KEYCODE_DPAD_LEFT -> View.FOCUS_LEFT
                    keyUpper == "DPAD_RIGHT" || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT -> View.FOCUS_RIGHT
                    else -> View.FOCUS_FORWARD
                }
                val target = (node ?: rootInActiveWindow)?.focusSearch(direction)
                target?.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                Log.d(TAG, "Arrow key focus navigation direction=$direction result=${target != null}")
                return
            }
        }

        Log.d(TAG, "No specific handler for key: $key, keyCode: $keyCode")
    }

    /**
     * Translates normalized position and trackpad scroll deltas into directional swipe gestures.
     */
    fun handleScroll(normalizedX: Double, normalizedY: Double, dx: Double, dy: Double) {
        val metrics = resources.displayMetrics
        val stroke = RemoteInputMapper.resolveScrollStroke(
            normalizedX = normalizedX,
            normalizedY = normalizedY,
            dx = dx,
            dy = dy,
            displayWidth = metrics.widthPixels,
            displayHeight = metrics.heightPixels
        )

        if (stroke.startX == stroke.endX && stroke.startY == stroke.endY) {
            return
        }

        val path = Path().apply {
            moveTo(stroke.startX, stroke.startY)
            lineTo(stroke.endX, stroke.endY)
        }
        val gestureStroke = GestureDescription.StrokeDescription(path, 0, stroke.durationMs)
        val gesture = GestureDescription.Builder().addStroke(gestureStroke).build()
        val dispatched = dispatchGesture(gesture, null, null)
        Log.d(TAG, "Dispatched scroll gesture (${stroke.startX},${stroke.startY} -> ${stroke.endX},${stroke.endY}, ${stroke.durationMs}ms): result=$dispatched")
    }

    /**
     * Wakes up the screen if asleep/dozing and performs an upward swipe gesture to dismiss the lock screen.
     */
    fun wakeUpAndUnlock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            val wakeLock = powerManager?.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "galaxycontinuity:RemoteWakeup"
            )
            wakeLock?.acquire(3000L) // Hold wake lock for 3 seconds
            Log.d(TAG, "Acquired remote wakeup SCREEN_BRIGHT_WAKE_LOCK")
        } catch (e: Exception) {
            Log.w(TAG, "Error acquiring wake lock: ${e.message}")
        }

        // Perform unlock swipe gesture after short delay to let display turn on
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                val metrics = resources.displayMetrics
                val midX = (metrics.widthPixels / 2).toFloat()
                val startY = (metrics.heightPixels * 0.75f)
                val endY = (metrics.heightPixels * 0.15f)

                val path = Path().apply {
                    moveTo(midX, startY)
                    lineTo(midX, endY)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, 200L)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                dispatchGesture(gesture, object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        Log.d(TAG, "Remote unlock swipe gesture completed successfully")
                    }
                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        Log.w(TAG, "Remote unlock swipe gesture cancelled")
                    }
                }, null)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to dispatch unlock swipe gesture", e)
            }
        }, 300L)
    }
}
