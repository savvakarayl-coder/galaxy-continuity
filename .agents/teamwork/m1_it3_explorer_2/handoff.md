# Implementation Blueprint: Android Components for Milestone M-IT3-1

**Agent**: `m1_it3_explorer_2`  
**Mission**: Develop the exact implementation blueprint for all Android changes in Milestone M-IT3-1 (iPhone Mirroring Parity & Presentation)  
**Parent**: `orchestrator_it3` / `sub_orch_m1` (`19504c92-7b9c-4a7e-8fac-89d677c3dfc7`)  
**Date**: 2026-11-08  

---

## 1. Observation

Direct examination of the Android source tree (`android/app/src/main/...`) revealed the exact gaps preventing Mac keyboard direct typing, trackpad smooth scrolling, notification click navigation, and automatic background reconnection:

### 1.1 `accessibility_service_config.xml`
- **Path**: `android/app/src/main/res/xml/accessibility_service_config.xml` (lines 1–9):
  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
      android:accessibilityEventTypes="typeAllMask"
      android:accessibilityFeedbackType="feedbackGeneric"
      android:accessibilityFlags="flagDefault"
      android:canPerformGestures="true"
      android:description="@string/accessibility_service_description"
      android:notificationTimeout="100" />
  ```
  - `android:canRetrieveWindowContent="true"` is **missing**. Without this attribute, `AccessibilityService.rootInActiveWindow`, `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)`, and `windows` return `null`, rendering all active input inspection and text manipulation impossible.
  - `android:accessibilityFlags` is set strictly to `"flagDefault"`. It lacks `flagRetrieveInteractiveWindows`, preventing window traversal when popups, dialogs, or multi-window inputs are focused.

### 1.2 `ContinuityAccessibilityService.kt` & `RemoteInputMapper.kt`
- **Path**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt` (lines 106–127):
  ```kotlin
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
  ...
  fun handleKeyInput(key: String, keyCode: Int) {
      val globalAction = RemoteInputMapper.mapToGlobalAction(key, keyCode)
      if (globalAction != null) {
          val result = performGlobalAction(globalAction)
          Log.d(TAG, "Injected global action $globalAction for key $key (result: $result)")
      } else {
          Log.d(TAG, "No global action mapping for key: $key, keyCode: $keyCode")
      }
  }
  ```
  - **No text injection**: There is no `findActiveInputNode()` and no `handleTextInput(text: String)` method.
  - **Hardcoded downward scroll**: `"scroll"` hardcodes `pixelY + 300` over a static 150ms duration. It has no awareness of scroll deltas (`dx`, `dy`), velocity, or reverse directions.
  - **Dropped keystrokes**: `handleKeyInput` only maps 6 navigation keys (`BACK`, `HOME`, `RECENTS`, `NOTIFICATIONS`, `QUICK_SETTINGS`, `POWER`). Keystrokes such as Backspace (67), Enter (66), Tab (61), Space (62), Escape (111), and DPAD arrows (19–22) are logged as `"No global action mapping for key..."` and discarded.
- **Path**: `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt` (lines 10–94):
  - Contains `mapCoordinates`, `resolveUpStroke`, and `mapToGlobalAction`.
  - Lacks scroll stroke resolution logic (`resolveScrollStroke`) to convert Mac trackpad deltas into scaled touch gestures with bounded durations.

### 1.3 `WebSocketClient.kt`
- **Path**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` (lines 19–39, 120–158):
  - `ContinuityListener` interface lacks callbacks for `onRemoteText(text: String)`, `onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double)`, and `onNotificationOpen(id: String, packageName: String)`.
  - `onMessage` ignores messages with `"type": "input_text"`, `"type": "input_scroll"`, and `"type": "notification_open"` (or `"notification_click"`), falling through to `Log.d(tag, "Ignoring unhandled message type: $type")`.
  - `input_event` does not parse optional `dx` and `dy` attributes when `action == "scroll"`.

### 1.4 `ContinuityService.kt`
- **Path**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` (lines 82–88, 121–127, 204–211):
  ```kotlin
  // Proactively probe local USB loopback (via adb reverse) and default Mac IP
  serviceScope.launch {
      try {
          webSocketClient?.connect("127.0.0.1", 8765)
      } catch (_: Exception) {}
  }
  ...
  override fun onDisconnected() {
      lastStatus = "Disconnected. Searching..."
      connectionStatus.value = "Disconnected. Searching..."
      isSocketConnected.value = false
      updateNotification("Disconnected. Searching for Mac...")
      nsdDiscovery?.startDiscovery()
  }
  ```
  - Probing `127.0.0.1:8765` only occurs once inside `onCreate()`.
  - When disconnected (`onDisconnected()`), it only starts `nsdDiscovery`. It never retries `127.0.0.1:8765`.
  - It does not persist or probe the last-known Wi-Fi host.
  - If mDNS is disabled or blocked on the local network router, the service never reconnects unless the user manually types an IP in `MainActivity`.
  - Missing listener overrides for `onRemoteText`, `onRemoteScroll`, and `onNotificationOpen`.

### 1.5 `NotificationForwarderService.kt`
- **Path**: `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt` (lines 25–45, 105–129):
  - In `onNotificationPosted`, it parses `sbn.notification?.actions` to populate `replyCache` (`ReplyActionHolder`).
  - It **does not store** `sbn.notification.contentIntent`.
  - Companion object exposes `replyToNotification(id, packageName, replyText)` but provides no `openNotification(id, packageName)` method to trigger the notification's target intent or launch its package.

---

## 2. Logic Chain

1. **Window Content Retrieval & Input Node Access**:
   - Adding `android:canRetrieveWindowContent="true"` and `android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows"` to `accessibility_service_config.xml` enables the accessibility service to query the active window hierarchy and interactive windows.
   - Programmatically adding `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` in `onServiceConnected()` guarantees runtime capability even if system configuration caching delays XML reload.
   - `findActiveInputNode(): AccessibilityNodeInfo?` implements a 4-tier fallback:
     1. `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)`
     2. `rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)`
     3. Scan `windows` for focused application/input windows and query `window.root?.findFocus(...)`
     4. Recursive depth-first search for `node.isFocused && (node.isEditable || className.contains("EditText"))`

2. **Direct Text & Editing Keystroke Injection**:
   - `handleTextInput(text: String)`:
     - Locates active input node. If found, reads `currentText = node.text` and selection bounds `(selStart, selEnd)`.
     - Replaces selected range (or inserts at cursor) and calls `node.performAction(ACTION_SET_TEXT, bundle)`.
     - Sets updated selection cursor via `ACTION_SET_SELECTION`.
     - If `ACTION_SET_TEXT` returns `false` or node is null, copies text to `ClipboardManager` and invokes `node.performAction(ACTION_PASTE)` as an immediate fallback.
   - `handleKeyInput(key: String, keyCode: Int)`:
     - Prioritizes global navigation keys (`BACK`, `HOME`, `RECENTS`, `NOTIFICATIONS`, etc.) via `RemoteInputMapper.mapToGlobalAction`.
     - Escape (`111`) dispatches `GLOBAL_ACTION_BACK` (dismissing dialogs/menus).
     - Space (`62`) delegates to `handleTextInput(" ")`.
     - Backspace / DEL (`67`): Deletes selected range, or single character preceding cursor, or trailing character via `ACTION_SET_TEXT` + `ACTION_SET_SELECTION`.
     - Enter (`66`): Attempts API 30+ `ACTION_IME_ENTER`. If unhandled or unsupported, inserts newline `\n` via `handleTextInput("\n")`.
     - Tab (`61`): Attempts `node.focusSearch(View.FOCUS_FORWARD)`. If found, performs `ACTION_FOCUS`; otherwise inserts `\t`.
     - Arrow keys (`19..22`): Updates cursor position in editable nodes; otherwise invokes `focusSearch(FOCUS_UP/DOWN/LEFT/RIGHT)` for list and focus navigation.

3. **Trackpad Smooth Scrolling**:
   - `RemoteInputMapper.resolveScrollStroke(normalizedX, normalizedY, dx, dy, displayWidth, displayHeight, scaleMultiplier = 3.0f)` converts trackpad deltas into touch swipe coordinates.
   - Under macOS natural scrolling:
     - Scrolling down produces negative `dy` (fingers swiping up) -> touch swipe goes upwards (`endY < startY`), causing the phone view to scroll down.
     - Positive `dy` produces downward touch swipe (`endY > startY`), causing the phone view to scroll up.
   - Clamps swipe coordinates to `[0, displayWidth]` and `[0, displayHeight]`.
   - Scales swipe gesture duration between 60ms and 150ms based on delta magnitude.
   - `ContinuityAccessibilityService.handleScroll` builds `GestureDescription` with a single stroke path and dispatches via `dispatchGesture`.

4. **Protocol & Routing Extension**:
   - `WebSocketClient.kt`:
     - Adds `onRemoteText(text: String)`, `onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double)`, and `onNotificationOpen(id: String, packageName: String)` to `ContinuityListener` with default no-op implementations.
     - Extends `onMessage` parser to handle `"input_text"`, `"input_scroll"`, and `"notification_open"` (or `"notification_click"`).
     - Enhances `"input_event"` to parse `dx`/`dy` when `action == "scroll"`.
   - `ContinuityService.kt`:
     - Routes `onRemoteText` -> `ContinuityAccessibilityService.instance?.handleTextInput(text)`.
     - Routes `onRemoteScroll` -> `ContinuityAccessibilityService.instance?.handleScroll(x, y, dx, dy)`.
     - Routes `onNotificationOpen` -> `NotificationForwarderService.openNotification(this, id, packageName)`.

5. **Automatic Background Reconnection Loop**:
   - `ContinuityService.kt` replaces the one-shot probe with an asynchronous reconnection state machine:
     - Maintains `reconnectAttempt` counter and exponential backoff intervals: `0ms -> 1000ms -> 2000ms -> 4000ms -> 10000ms (clamped max)`.
     - In each iteration:
       1. Probes USB loopback `127.0.0.1:8765` (succeeds instantly when USB cable is connected with `adb reverse`).
       2. Probes cached last-known host from `SharedPreferences` (succeeds instantly on known Wi-Fi without waiting for mDNS).
       3. Triggers `nsdDiscovery.startDiscovery()`.
     - When connected: resets attempt counter to 0, cancels active reconnection loop job, and updates `SharedPreferences` with the successful host/port.
     - When disconnected: triggers `startReconnectionLoop()`.

6. **Notification Click Navigation**:
   - `NotificationForwarderService.kt`:
     - Adds `contentIntentCache = ConcurrentHashMap<String, PendingIntent>()` and `packageCache = ConcurrentHashMap<String, String>()`.
     - In `onNotificationPosted`: stores `sbn.notification.contentIntent` and `packageName` keyed by `notifId`.
     - In `onNotificationRemoved`: evicts entries from caches.
     - Implements `openNotification(id, packageName)`:
       1. If `contentIntentCache[id]` exists, calls `pendingIntent.send()`.
       2. If `send()` throws or pending intent is missing, queries `packageManager.getLaunchIntentForPackage(packageName)` and starts the activity with `FLAG_ACTIVITY_NEW_TASK`.

---

## 3. Caveats

1. **Accessibility Text Replacement vs. Custom Canvas Apps**:
   - `AccessibilityNodeInfo.ACTION_SET_TEXT` works for standard Android views (`EditText`, `TextView`, Material Design, Jetpack Compose `TextField`).
   - For custom OpenGL/Flutter game canvases that do not expose accessibility nodes, `findActiveInputNode()` returns null. The fallback clipboard copy (`ACTION_PASTE`) is invoked, and if USB is attached, macOS ADB fast-path (`adb shell input text`) provides zero-latency hardware-level fallback.
2. **Trackpad Event Flooding**:
   - High-speed trackpad gestures generate rapid scroll deltas. The Android gesture queue is protected by delta scaling, duration bounding (60–150ms), and ignoring zero-movement strokes in `RemoteInputMapper.resolveScrollStroke`.
3. **Android Background Activity Starts**:
   - On Android 10+ (API 29+), starting an activity from the background is restricted. However, invoking `pendingIntent.send()` from an active notification is explicitly exempt from background restrictions. As a backup, `ContinuityService` runs as a foreground service with type `connectedDevice`, which has system permission to launch activities.

---

## 4. Conclusion & Concrete Implementation Blueprint

Below are the exact file diffs and complete code blueprints for all target Android files.

---

### 4.1 `accessibility_service_config.xml`
**Target File**: `android/app/src/main/res/xml/accessibility_service_config.xml`

#### Proposed Full Content:
```xml
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows"
    android:canPerformGestures="true"
    android:canRetrieveWindowContent="true"
    android:description="@string/accessibility_service_description"
    android:notificationTimeout="100" />
```

---

### 4.2 `RemoteInputMapper.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`

#### Implementation Blueprint:
Add `ScrollStroke` data class and `resolveScrollStroke` helper function:

```kotlin
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
```

---

### 4.3 `ContinuityAccessibilityService.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt`

#### Implementation Blueprint:
Replace full file with active node retrieval, cursor-aware text manipulation, full keystroke dispatching, and smooth scrolling:

```kotlin
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
}
```

---

### 4.4 `WebSocketClient.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`

#### Implementation Blueprint:
1. Extend `ContinuityListener` (lines 19–39):
```kotlin
    interface ContinuityListener {
        fun onConnected(macName: String)
        fun onDisconnected()
        fun onClipboardReceived(content: String, contentType: String = "text/plain", hash: String? = null)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String)
        fun onFileComplete(fileId: String, status: String, message: String)
        fun onPingReceived(message: String)

        // Milestone 3: Screen Mirroring & Continuity Camera
        fun onScreenStart(width: Int, height: Int, fps: Int, bitrate: Int)
        fun onScreenStop(reason: String?)
        fun onRemoteInput(action: String, x: Double, y: Double, button: Int)
        fun onRemoteKey(key: String, keyCode: Int)
        fun onCameraStart(lens: String, quality: String, fps: Int)
        fun onCameraStop()
        fun onCameraControl(action: String, lens: String?, zoom: Double?, torch: Boolean?)

        // Milestone 4: Notification Relay & Quick Reply
        fun onNotificationReply(id: String, packageName: String, replyText: String)

        // Milestone M-IT3-1: Keyboard text, trackpad scrolling, notification opening
        fun onRemoteText(text: String) {}
        fun onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double) {}
        fun onNotificationOpen(id: String, packageName: String) {}
    }
```

2. Extend `onMessage` parsing (lines 120–132, 151–158):
```kotlin
                        "input_event" -> {
                            val action = json.optString("action", "down")
                            val x = json.optDouble("x", 0.5)
                            val y = json.optDouble("y", 0.5)
                            val button = json.optInt("button", 0)
                            if (action.lowercase().trim() == "scroll" && (json.has("dx") || json.has("dy"))) {
                                val dx = json.optDouble("dx", 0.0)
                                val dy = json.optDouble("dy", 0.0)
                                mainHandler.post { listener.onRemoteScroll(x, y, dx, dy) }
                            } else {
                                mainHandler.post { listener.onRemoteInput(action, x, y, button) }
                            }
                        }
                        "input_key" -> {
                            val key = json.optString("key", "")
                            val keyCode = json.optInt("keyCode", 0)
                            mainHandler.post { listener.onRemoteKey(key, keyCode) }
                        }
                        "input_text" -> {
                            val text = if (json.has("text")) json.getString("text") else json.optString("content", "")
                            mainHandler.post { listener.onRemoteText(text) }
                        }
                        "input_scroll" -> {
                            val x = json.optDouble("x", 0.5)
                            val y = json.optDouble("y", 0.5)
                            val dx = json.optDouble("dx", 0.0)
                            val dy = json.optDouble("dy", 0.0)
                            mainHandler.post { listener.onRemoteScroll(x, y, dx, dy) }
                        }
...
                        // Milestone 4 & M-IT3-1: Notification Relay & Navigation
                        "notification_reply" -> {
                            val id = json.optString("id")
                            val pkg = json.optString("packageName")
                            val replyText = json.optString("replyText")
                            mainHandler.post { listener.onNotificationReply(id, pkg, replyText) }
                        }
                        "notification_open", "notification_click" -> {
                            val id = json.optString("id")
                            val pkg = json.optString("packageName")
                            mainHandler.post { listener.onNotificationOpen(id, pkg) }
                        }
```

---

### 4.5 `ContinuityService.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`

#### Implementation Blueprint:
1. Implement persistent last-known host caching:
```kotlin
    private fun saveLastKnownHost(host: String, port: Int) {
        if (host.isEmpty() || host == "127.0.0.1") return
        try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .edit()
                .putString("last_known_host", host)
                .putInt("last_known_port", port)
                .apply()
            android.util.Log.d("ContinuityService", "Persisted last-known Wi-Fi host: $host:$port")
        } catch (e: Exception) {
            android.util.Log.w("ContinuityService", "Failed to persist last-known host: ${e.message}")
        }
    }

    private fun getLastKnownHost(): String? {
        return try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .getString("last_known_host", null)
        } catch (e: Exception) {
            null
        }
    }

    private fun getLastKnownPort(): Int {
        return try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .getInt("last_known_port", 8765)
        } catch (e: Exception) {
            8765
        }
    }
```

2. Implement exponential backoff reconnection loop:
```kotlin
    private var reconnectionJob: Job? = null
    private var reconnectAttempt = 0

    private fun startReconnectionLoop() {
        if (reconnectionJob?.isActive == true) return
        reconnectionJob = serviceScope.launch {
            while (isRunning && !isSocketConnected.value) {
                val delayMs = when (reconnectAttempt) {
                    0 -> 0L
                    1 -> 1000L
                    2 -> 2000L
                    3 -> 4000L
                    else -> 10000L
                }
                reconnectAttempt++
                if (delayMs > 0) {
                    android.util.Log.d("ContinuityService", "Reconnection loop waiting ${delayMs}ms (attempt #$reconnectAttempt)")
                    kotlinx.coroutines.delay(delayMs)
                }
                if (!isRunning || isSocketConnected.value) break

                // Probe 1: USB Loopback (via adb reverse)
                android.util.Log.d("ContinuityService", "Reconnection attempt #$reconnectAttempt: probing USB loopback 127.0.0.1:8765...")
                updateNotification("Reconnecting to Mac (USB)...")
                try {
                    webSocketClient?.connect("127.0.0.1", 8765)
                } catch (e: Exception) {
                    android.util.Log.d("ContinuityService", "USB loopback connect error: ${e.message}")
                }

                kotlinx.coroutines.delay(600L)
                if (!isRunning || isSocketConnected.value) break

                // Probe 2: Cached last-known Wi-Fi host
                val cachedHost = getLastKnownHost()
                val cachedPort = getLastKnownPort()
                if (!cachedHost.isNullOrEmpty() && cachedHost != "127.0.0.1") {
                    android.util.Log.d("ContinuityService", "Reconnection attempt #$reconnectAttempt: probing cached Wi-Fi host $cachedHost:$cachedPort...")
                    updateNotification("Reconnecting to $cachedHost...")
                    try {
                        webSocketClient?.connect(cachedHost, cachedPort)
                    } catch (e: Exception) {
                        android.util.Log.d("ContinuityService", "Cached host connect error: ${e.message}")
                    }
                    kotlinx.coroutines.delay(600L)
                    if (!isRunning || isSocketConnected.value) break
                }

                // Probe 3: Trigger mDNS scan
                android.util.Log.d("ContinuityService", "Reconnection attempt #$reconnectAttempt: triggering mDNS scan...")
                updateNotification("Searching for Mac on Wi-Fi...")
                nsdDiscovery?.startDiscovery()
            }
        }
    }
```

3. Update `onCreate()`, `onConnected()`, and `onDisconnected()`:
```kotlin
    override fun onCreate() {
        ...
        nsdDiscovery = NsdDiscovery(this) { host, port, name ->
            lastStatus = "Connecting to $name..."
            connectionStatus.value = "Connecting to $name..."
            updateNotification("Connecting to $name...")
            saveLastKnownHost(host, port)
            webSocketClient?.connect(host, port)
        }
        nsdDiscovery?.startDiscovery()

        // Kick off background reconnection loop immediately (attempt 0 runs 0ms delay)
        startReconnectionLoop()
    }

    override fun onConnected(macName: String) {
        reconnectionJob?.cancel()
        reconnectionJob = null
        reconnectAttempt = 0
        val host = webSocketClient?.currentHost ?: ""
        val port = webSocketClient?.currentPort ?: 8765
        if (host.isNotEmpty() && host != "127.0.0.1") {
            saveLastKnownHost(host, port)
        }
        lastStatus = "Connected to $macName"
        connectionStatus.value = "Connected to $macName"
        isSocketConnected.value = true
        updateNotification("Connected to $macName")
    }

    override fun onDisconnected() {
        lastStatus = "Disconnected. Searching..."
        connectionStatus.value = "Disconnected. Searching..."
        isSocketConnected.value = false
        updateNotification("Disconnected. Searching for Mac...")
        nsdDiscovery?.startDiscovery()
        startReconnectionLoop()
    }
```

4. Route input and notification callbacks:
```kotlin
    override fun onRemoteText(text: String) {
        ContinuityAccessibilityService.instance?.handleTextInput(text)
    }

    override fun onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double) {
        ContinuityAccessibilityService.instance?.handleScroll(x, y, dx, dy)
    }

    override fun onNotificationOpen(id: String, packageName: String) {
        android.util.Log.d("ContinuityService", "Received notification_open for id=$id pkg=$packageName")
        NotificationForwarderService.openNotification(this, id, packageName)
    }
```

---

### 4.6 `NotificationForwarderService.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt`

#### Implementation Blueprint:
Replace full file to cache content intents and provide `openNotification`:

```kotlin
package com.galaxycontinuity.app.service

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class NotificationForwarderService : NotificationListenerService() {
    private val tag = "NotifForwarder"

    data class ReplyActionHolder(
        val pendingIntent: PendingIntent,
        val remoteInput: RemoteInput
    )

    companion object {
        var instance: NotificationForwarderService? = null
            private set

        private val replyCache = ConcurrentHashMap<String, ReplyActionHolder>()
        private val contentIntentCache = ConcurrentHashMap<String, PendingIntent>()
        private val packageCache = ConcurrentHashMap<String, String>()

        fun replyToNotification(id: String, packageName: String, replyText: String): Boolean {
            val service = instance
            if (service != null) {
                return service.reply(id, packageName, replyText)
            }
            val holder = replyCache[id] ?: return false
            return try {
                val intent = Intent()
                val bundle = Bundle()
                bundle.putCharSequence(holder.remoteInput.resultKey, replyText)
                RemoteInput.addResultsToIntent(arrayOf(holder.remoteInput), intent, bundle)
                holder.pendingIntent.send(null, 0, intent)
                true
            } catch (e: Exception) {
                Log.e("NotifForwarder", "Fallback reply failed: ${e.message}")
                false
            }
        }

        fun openNotification(id: String, packageName: String): Boolean {
            val service = instance
            if (service != null) {
                return service.open(id, packageName)
            }
            val pendingIntent = contentIntentCache[id]
            if (pendingIntent != null) {
                return try {
                    pendingIntent.send()
                    Log.d("NotifForwarder", "Executed cached contentIntent for $id ($packageName)")
                    true
                } catch (e: Exception) {
                    Log.e("NotifForwarder", "Fallback contentIntent send failed: ${e.message}")
                    false
                }
            }
            return false
        }

        fun openNotification(context: Context, id: String, packageName: String): Boolean {
            val service = instance
            if (service != null) {
                return service.open(id, packageName)
            }
            val pendingIntent = contentIntentCache[id]
            if (pendingIntent != null) {
                return try {
                    pendingIntent.send()
                    Log.d("NotifForwarder", "Executed cached contentIntent for $id ($packageName)")
                    true
                } catch (e: Exception) {
                    Log.w("NotifForwarder", "Fallback contentIntent send failed, launching package: ${e.message}")
                    launchPackage(context, packageName)
                }
            }
            return launchPackage(context, packageName)
        }

        private fun launchPackage(context: Context, packageName: String): Boolean {
            if (packageName.isEmpty()) return false
            return try {
                val pm = context.packageManager
                val intent = pm.getLaunchIntentForPackage(packageName)
                if (intent != null) {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                    context.startActivity(intent)
                    Log.d("NotifForwarder", "Successfully launched package activity for $packageName")
                    true
                } else {
                    Log.w("NotifForwarder", "No launch intent found for package $packageName")
                    false
                }
            } catch (e: Exception) {
                Log.e("NotifForwarder", "Failed to launch package $packageName: ${e.message}", e)
                false
            }
        }

        fun registerTestReplyAction(id: String, holder: ReplyActionHolder) {
            replyCache[id] = holder
        }

        fun hasReplyAction(id: String): Boolean {
            return replyCache.containsKey(id)
        }

        fun registerTestContentIntent(id: String, pendingIntent: PendingIntent) {
            contentIntentCache[id] = pendingIntent
        }

        fun hasContentIntent(id: String): Boolean {
            return contentIntentCache.containsKey(id)
        }

        fun clearCaches() {
            replyCache.clear()
            contentIntentCache.clear()
            packageCache.clear()
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.d(tag, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
        Log.d(tag, "Notification listener disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null || sbn.isOngoing) return

        val pkg = sbn.packageName ?: ""
        if (pkg.contains("galaxycontinuity") || pkg.contains("android.systemui")) return

        val extras = sbn.notification?.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        if (title.isEmpty() && text.isEmpty()) return

        val appName = try {
            val pm = applicationContext.packageManager
            val ai = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(ai).toString()
        } catch (e: Exception) {
            pkg
        }

        val notifId = sbn.key ?: UUID.randomUUID().toString()

        // Cache contentIntent for notification open action
        sbn.notification?.contentIntent?.let {
            contentIntentCache[notifId] = it
        }
        if (pkg.isNotEmpty()) {
            packageCache[notifId] = pkg
        }

        // Inspect notification actions for RemoteInput (quick reply)
        var canReply = false
        val actions = sbn.notification?.actions
        if (actions != null) {
            for (action in actions) {
                val remoteInputs = action.remoteInputs
                if (remoteInputs != null && remoteInputs.isNotEmpty() && action.actionIntent != null) {
                    val targetRemoteInput = remoteInputs.first()
                    replyCache[notifId] = ReplyActionHolder(action.actionIntent, targetRemoteInput)
                    canReply = true
                    break
                }
            }
        }

        Log.d(tag, "Forwarding notification from $appName: $title - $text (canReply: $canReply, id: $notifId)")
        ContinuityService.activeClient?.sendNotification(
            id = notifId,
            packageName = pkg,
            app = appName,
            title = title,
            text = text,
            canReply = canReply
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        sbn?.key?.let {
            replyCache.remove(it)
            contentIntentCache.remove(it)
            packageCache.remove(it)
        }
    }

    fun reply(id: String, packageName: String, replyText: String): Boolean {
        val holder = replyCache[id]
        if (holder == null) {
            Log.w(tag, "No active reply intent cached for notification ID $id")
            return false
        }

        return try {
            val intent = Intent()
            val bundle = Bundle()
            bundle.putCharSequence(holder.remoteInput.resultKey, replyText)
            RemoteInput.addResultsToIntent(arrayOf(holder.remoteInput), intent, bundle)
            holder.pendingIntent.send(this, 0, intent)
            Log.d(tag, "Sent reply for notification ID $id: $replyText")
            true
        } catch (e: Exception) {
            Log.e(tag, "Failed to send notification reply: ${e.message}", e)
            false
        }
    }

    fun open(id: String, packageName: String): Boolean {
        val pendingIntent = contentIntentCache[id]
        if (pendingIntent != null) {
            return try {
                pendingIntent.send()
                Log.d(tag, "Fired contentIntent for notification $id ($packageName)")
                true
            } catch (e: Exception) {
                Log.w(tag, "contentIntent.send() failed for $id, falling back to package launch", e)
                launchPackage(this, packageName)
            }
        }
        val fallbackPkg = if (packageName.isNotEmpty()) packageName else packageCache[id] ?: ""
        return launchPackage(this, fallbackPkg)
    }
}
```

---

### 4.7 Android Unit Test Extensions
**Target File 1**: `android/app/src/test/java/com/galaxycontinuity/app/ScreenMirroringUnitTest.kt`
Add tests for scroll stroke calculations:
```kotlin
    @Test
    fun testResolveScrollStrokeDownwardNatural() {
        // macOS natural scrolling downward produces negative dy (swiping up)
        val stroke = RemoteInputMapper.resolveScrollStroke(
            normalizedX = 0.5,
            normalizedY = 0.5,
            dx = 0.0,
            dy = -40.0,
            displayWidth = 1080,
            displayHeight = 2400,
            scaleMultiplier = 3.0f
        )

        assertEquals(540f, stroke.startX, 0.001f)
        assertEquals(1200f, stroke.startY, 0.001f)
        assertEquals(540f, stroke.endX, 0.001f)
        // endY should be 1200 - 120 = 1080
        assertEquals(1080f, stroke.endY, 0.001f)
        assertTrue(stroke.endY < stroke.startY)
        assertTrue(stroke.durationMs in 60L..150L)
    }

    @Test
    fun testResolveScrollStrokeUpwardNatural() {
        val stroke = RemoteInputMapper.resolveScrollStroke(
            normalizedX = 0.5,
            normalizedY = 0.5,
            dx = 0.0,
            dy = 50.0,
            displayWidth = 1080,
            displayHeight = 2400,
            scaleMultiplier = 3.0f
        )

        assertEquals(540f, stroke.startX, 0.001f)
        assertEquals(1200f, stroke.startY, 0.001f)
        assertEquals(540f, stroke.endX, 0.001f)
        // endY should be 1200 + 150 = 1350
        assertEquals(1350f, stroke.endY, 0.001f)
        assertTrue(stroke.endY > stroke.startY)
    }

    @Test
    fun testResolveScrollStrokeDisplayBoundaryClamping() {
        // Extreme negative delta clamped to top of screen (0)
        val stroke = RemoteInputMapper.resolveScrollStroke(
            normalizedX = 0.5,
            normalizedY = 0.05,
            dx = 0.0,
            dy = -200.0,
            displayWidth = 1080,
            displayHeight = 2400,
            scaleMultiplier = 3.0f
        )

        assertEquals(0f, stroke.endY, 0.001f)
    }
```

**Target File 2**: `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt`
Add tests for `input_text`, `input_scroll`, and `notification_open`:
```kotlin
    @Test
    fun testInputTextMessageSerialization() {
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", "Hello Galaxy from Mac")
        }

        val parsed = JSONObject(json.toString())
        assertEquals("input_text", parsed.getString("type"))
        assertEquals("Hello Galaxy from Mac", parsed.getString("text"))
    }

    @Test
    fun testInputScrollMessageSerialization() {
        val json = JSONObject().apply {
            put("type", "input_scroll")
            put("x", 0.5234)
            put("y", 0.7412)
            put("dx", 0.0)
            put("dy", -35.0)
        }

        val parsed = JSONObject(json.toString())
        assertEquals("input_scroll", parsed.getString("type"))
        assertEquals(0.5234, parsed.getDouble("x"), 0.0001)
        assertEquals(0.7412, parsed.getDouble("y"), 0.0001)
        assertEquals(0.0, parsed.getDouble("dx"), 0.0001)
        assertEquals(-35.0, parsed.getDouble("dy"), 0.0001)
    }

    @Test
    fun testNotificationOpenMessageSerialization() {
        val json = JSONObject().apply {
            put("type", "notification_open")
            put("id", "notif-uuid-10492")
            put("packageName", "org.telegram.messenger")
        }

        val parsed = JSONObject(json.toString())
        assertEquals("notification_open", parsed.getString("type"))
        assertEquals("notif-uuid-10492", parsed.getString("id"))
        assertEquals("org.telegram.messenger", parsed.getString("packageName"))
    }
```

---

## 5. Verification Method

### 5.1 Verification Commands
1. **JVM Unit Tests**:
   ```bash
   export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android
   ./gradlew testDebugUnitTest
   ```
   *Expected Outcome*: All tests pass with code `0`. Tests confirm coordinate mapping, scroll stroke translation, protocol JSON serialization for `input_text`, `input_scroll`, and `notification_open`.

2. **Android APK Compilation & Installation**:
   ```bash
   export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android
   ./gradlew assembleDebug
   /tmp/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
   *Expected Outcome*: Successful build and installation on Samsung Galaxy A70 (`R58M5763N2Y`).

3. **Runtime Accessibility Verification**:
   - Check service running state:
     ```bash
     /tmp/platform-tools/adb shell dumpsys accessibility
     ```
   - Verify `ContinuityAccessibilityService` lists `canRetrieveWindowContent: true` and `flagRetrieveInteractiveWindows`.

4. **Functional Input & Reconnection Verification on Physical Device**:
   - Focus a text field in Samsung Notes or Chrome. Type characters on Mac: characters appear in real time.
   - Press Backspace on Mac: character preceding cursor is deleted.
   - Press Enter on Mac: IME action executes or newline is added.
   - Swipe two fingers on trackpad over mirror view: screen scrolls naturally matching trackpad direction.
   - Click a notification banner on Mac: mirror window focuses and the corresponding app opens immediately on the Galaxy phone.
   - Unplug USB / toggle Wi-Fi: notification updates to `"Reconnecting to Mac..."` and automatically reconnects without manual IP input once the link is restored.

### 5.2 Invalidation Conditions
- `findActiveInputNode()` returns null when an `EditText` has active keyboard focus -> Verify `accessibility_service_config.xml` has `android:canRetrieveWindowContent="true"`.
- DEL key deletes characters at start of field or crashes -> Check bounds checking in `handleKeyInput` `selStart in 0..currentText.length`.
- Reconnection loop attempts hang or spawn unbound coroutines -> Verify `reconnectionJob?.isActive` check in `startReconnectionLoop()` and cancellation in `onConnected()`.
