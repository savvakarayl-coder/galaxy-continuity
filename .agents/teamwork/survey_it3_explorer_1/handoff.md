# Handoff Report: Requirement R1 (iPhone Mirroring Interaction & Input)

**Agent**: `survey_it3_explorer_1`  
**Date**: 2026-11-08  
**Scope**: Requirement R1 — Mac Keyboard Direct Typing into Galaxy Input Fields & Mac Trackpad Smooth Scrolling  

---

## 1. Observation

### 1.1 macOS Keyboard & Keystroke Capture
- **`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift` (lines 33–57)**:
  `ScreenMirroringView` only implements a SwiftUI `DragGesture(minimumDistance: 0)` on the mirror viewport:
  ```swift
  .gesture(
      DragGesture(minimumDistance: 0)
          .onChanged { val in ... ScreenMirroringService.shared.sendInputEvent(action: "down"|"move", ...) }
          .onEnded { val in ... ScreenMirroringService.shared.sendInputEvent(action: "up", ...) }
  )
  ```
  `ScreenMirroringWindowController` (lines 130–156) wraps this in an `NSWindow` via `NSHostingView(rootView: ScreenMirroringView())`. There is **zero** keyboard event handling (`keyDown`, `keyUp`, `NSTextInputClient`, or `NSEvent.addLocalMonitorForEvents`). When the window is focused and keys are typed, macOS produces an error chime/beep and no events are dispatched.
- **`mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift` (lines 122–137)**:
  `ScreenMirroringService` has `sendKeyInput(key: String, keyCode: Int? = nil)`:
  ```swift
  public func sendKeyInput(key: String, keyCode: Int? = nil) {
      let msg = ContinuityMessage(type: "input_key", key: key, keyCode: keyCode)
      ServerManager.shared.broadcastMessage(msg)
      let keyUpper = key.uppercased()
      if keyUpper == "BACK" { dispatchAdbInput(args: ["keyevent", "4"]) }
      else if keyUpper == "HOME" { dispatchAdbInput(args: ["keyevent", "3"]) }
      else if keyUpper == "RECENTS" { dispatchAdbInput(args: ["keyevent", "187"]) }
      else if keyUpper == "NOTIFICATIONS" { dispatchAdbInput(args: ["keyevent", "83"]) }
      else if keyUpper == "POWER" || keyUpper == "LOCK" { dispatchAdbInput(args: ["keyevent", "26"]) }
      else if let code = keyCode, code > 0 { dispatchAdbInput(args: ["keyevent", "\(code)"]) }
  }
  ```
  There is **no** method `sendTextInput(text: String)` or mechanism to send arbitrary character text strings or handle text input fields.
- **`mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift` (lines 37–64)**:
  `ContinuityMessage` defines `action`, `x`, `y`, `button`, `key`, `keyCode`, `text`. It does **not** define `dx` or `dy`.

### 1.2 Android Input Reception & Injection
- **`android/app/src/main/res/xml/accessibility_service_config.xml` (lines 1–9)**:
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
  `android:canRetrieveWindowContent="true"` is **missing**. Without this attribute, `AccessibilityService.rootInActiveWindow` and `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)` return `null`, preventing node inspection and direct text manipulation.
- **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt` (lines 119–127)**:
  ```kotlin
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
  Only global system navigation actions (`BACK`, `HOME`, `RECENTS`, `NOTIFICATIONS`, `LOCK_SCREEN`) are recognized. All regular keystrokes (alphanumeric, punctuation, Backspace `KEYCODE_DEL`, Enter `KEYCODE_ENTER`, Tab `KEYCODE_TAB`) are logged as `"No global action mapping for key..."` and discarded.
  `ContinuityAccessibilityService` contains **no** `handleTextInput` method and never touches `AccessibilityNodeInfo` or `ACTION_SET_TEXT`.
- **`android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt` (lines 61–83)**:
  `mapToGlobalAction` only maps 6 keys (`BACK`, `HOME`, `RECENTS`, `NOTIFICATIONS`, `QUICK_SETTINGS`, `POWER`), returning `null` for everything else.
- **`android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` (lines 120–131)**:
  `onMessage` only parses `"input_event"` and `"input_key"`. It has no case for `"input_text"` or `"input_scroll"`. The `ContinuityListener` interface lacks text and scroll callbacks.
- **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` (lines 204–210)**:
  Only implements `onRemoteInput` and `onRemoteKey`, delegating to `handleInputEvent` and `handleKeyInput`.

### 1.3 Mac Trackpad & Scrolling Gestures
- **`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift`**:
  No `scrollWheel(with:)` event handler or listener. Trackpad two-finger scrolls over the mirror window are ignored.
- **`mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`**:
  No `sendScrollEvent` method.
- **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt` (lines 106–115)**:
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
  ```
  The existing scroll handling hardcodes a fixed downward swipe of `+300` pixels over 150ms. It cannot scroll upwards, cannot scroll horizontally, ignores scroll delta/velocity, and cannot be triggered because macOS never sends `"scroll"`.

### 1.4 Protocol (`shared/PROTOCOL.md`)
- Section 5.4 specifies `input_event` (with fields `action`, `x`, `y`, `button`) and `input_key` (with fields `key`, `keyCode`).
- There is **no** schema for `input_text`.
- The `input_event` table lists `"scroll"` as an allowed action, but provides no parameters for delta movement (`dx`, `dy`).

---

## 2. Logic Chain

1. **Mac Keyboard Direct Typing Failure Chain**:
   - Observation 1.1: `ScreenMirroringView` and `ScreenMirroringWindowController` have no keyboard event capture; typing in the mirror window is dropped by macOS AppKit with an alert sound.
   - Observation 1.1: `ScreenMirroringService` has no `sendTextInput` method; only `sendKeyInput` exists.
   - Observation 1.2: `WebSocketClient` has no parser for `input_text`.
   - Observation 1.2: `accessibility_service_config.xml` lacks `canRetrieveWindowContent="true"`, preventing node tree traversal and active field focus retrieval.
   - Observation 1.2: `ContinuityAccessibilityService` only invokes `performGlobalAction` for navigation keys; it has no implementation for inserting text or dispatching `KEYCODE_DEL` / `KEYCODE_ENTER` into active input fields.
   - **Inference**: To enable Mac keyboard typing, changes are required at 4 levels: (a) AppKit window keyboard capture on Mac, (b) Protocol schema for text and editing keys, (c) WebSocket message parsing and forwarding in Android services, and (d) `AccessibilityNodeInfo` (`ACTION_SET_TEXT`, `ACTION_SET_SELECTION`, `ACTION_IME_ACTION`) text injection in `ContinuityAccessibilityService`, augmented by macOS ADB fast-path.

2. **Mac Trackpad Smooth Scrolling Failure Chain**:
   - Observation 1.3: macOS mirror window has no `scrollWheel` capture.
   - Observation 1.4: Protocol has no `dx`/`dy` fields in `input_event` or `input_scroll`.
   - Observation 1.3: Android's existing `"scroll"` action hardcodes `pixelY + 300`, which is direction-unaware, single-axis, and unscaled.
   - **Inference**: Smooth two-finger scrolling requires: (a) Capturing `scrollWheel` in `ScreenMirroringWindowController` with normalized `(x, y)` position and accumulated `(dx, dy)` deltas, (b) Adding `dx` and `dy` to protocol message and `ContinuityMessage`, (c) Translating `(dx, dy)` in `ContinuityAccessibilityService` into an inverted directional swipe vector using `dispatchGesture(GestureDescription...)` with duration scaled to delta (e.g. 80–120ms).

3. **Dual-Delivery Architecture (WebSocket + ADB Fast-Path)**:
   - Observation 1.1: `ScreenMirroringService.swift` already includes an ADB execution helper `dispatchAdbInput` for the connected device.
   - Command check: `/tmp/platform-tools/adb devices` confirmed `R58M5763N2Y` is connected. `adb shell input` supports `text <string>`, `keyevent <code>`, and `swipe <x1> <y1> <x2> <y2> <duration>`.
   - **Inference**: A dual-channel strategy provides maximum reliability:
     - Primary: WebSocket `ContinuityMessage` (`input_text`, `input_scroll`, `input_key`) handled natively by `ContinuityAccessibilityService` via Android accessibility APIs (works seamlessly over Wi-Fi and USB alike).
     - Auxiliary: macOS `ScreenMirroringService` invokes `dispatchAdbInput` when ADB is detected, providing zero-latency keyevent/text execution.

---

## 3. Caveats

1. **Android Accessibility Text Replacement Limitations**:
   - `AccessibilityNodeInfo.ACTION_SET_TEXT` works for standard Android `EditText`, `AutoCompleteTextView`, Compose `TextField`, and search bars.
   - In rare third-party apps with custom canvas renderers (e.g. Flutter canvas or games without accessible nodes), `findFocus(FOCUS_INPUT)` may return `null`. In such cases, the macOS ADB fast-path (`adb shell input text`) or `ACTION_PASTE` provides the fallback.
2. **Trackpad Event Flooding**:
   - macOS trackpads generate high-frequency `scrollWheel` events (up to 120Hz). Direct unthrottled transmission of 120 `dispatchGesture` calls per second will overwhelm Android's gesture queue. Throttling/batching deltas into ~40–60ms intervals (or threshold ~15–20pt) is necessary for smooth, jitter-free scrolling.
3. **Russian / Unicode Text in ADB `input text`**:
   - `adb shell input text` on older Android versions struggles with non-ASCII characters without escaping. The primary WebSocket channel via `ContinuityAccessibilityService.handleTextInput` sets UTF-8 `CharSequence` directly via `ACTION_SET_TEXT`, which fully supports Russian, Cyrillic, Greek, and emojis without issue.

---

## 4. Conclusion & Concrete Action Plan

### 4.1 Protocol Updates (`shared/PROTOCOL.md`)
1. **Add `input_text` Message Schema**:
   ```json
   {
     "type": "input_text",
     "text": "Hello world"
   }
   ```
2. **Add `input_scroll` Schema & `input_event` Scroll Deltas**:
   ```json
   {
     "type": "input_scroll",
     "x": 0.5234,
     "y": 0.7412,
     "dx": 0.0,
     "dy": -35.0
   }
   ```
   Allow `input_event` to carry optional `dx` and `dy` when `action == "scroll"`.
3. **Formalize Key Codes for Keyboard Keys in `input_key`**:
   - `BACKSPACE` / `DEL` (`keyCode`: 67)
   - `ENTER` (`keyCode`: 66)
   - `TAB` (`keyCode`: 61)
   - `ESCAPE` (`keyCode`: 111)
   - `SPACE` (`keyCode`: 62)
   - `DPAD_UP` (19), `DPAD_DOWN` (20), `DPAD_LEFT` (21), `DPAD_RIGHT` (22)

### 4.2 macOS File Changes
1. **`mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`**:
   - Add `public var dx: Double?` and `public var dy: Double?`.
   - Update `init(...)`.
2. **`mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`**:
   - Add `public func sendTextInput(text: String)`:
     - Dispatches `ContinuityMessage(type: "input_text", text: text)` via `ServerManager.shared.broadcastMessage`.
     - Calls `dispatchAdbInput(args: ["text", escapedText])` when ADB is available.
   - Add `public func sendScrollEvent(x: Double, y: Double, dx: Double, dy: Double)`:
     - Dispatches `ContinuityMessage(type: "input_scroll", x: x, y: y, dx: dx, dy: dy)`.
   - Enhance `sendKeyInput`:
     - Map `BACKSPACE`/`DEL` -> keyevent 67, `ENTER` -> keyevent 66, `TAB` -> keyevent 61, `ESCAPE` -> keyevent 111, `SPACE` -> keyevent 62, `DPAD_*` -> keyevents 19–22.
3. **`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift`**:
   - In `ScreenMirroringWindowController`:
     - Attach local event monitor:
       ```swift
       eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
           guard let self = self, event.window == self.window else { return event }
           if event.type == .keyDown {
               self.handleKeyDown(event)
               return nil // consume to prevent beep
           } else if event.type == .scrollWheel {
               self.handleScrollWheel(event)
               return nil
           }
           return event
       }
       ```
     - `handleKeyDown(event)`:
       - Special key mappings (Backspace keyCode 51, Enter keyCode 36/76, Tab keyCode 48, Escape keyCode 53, Arrows 123–126, Cmd shortcuts).
       - Printable text: `event.characters` filtered of control characters -> `ScreenMirroringService.shared.sendTextInput(chars)`.
     - `handleScrollWheel(event)`:
       - Compute normalized `(x, y)` within viewport.
       - Extract `dx = event.scrollingDeltaX`, `dy = event.scrollingDeltaY`.
       - Throttle/batch and call `ScreenMirroringService.shared.sendScrollEvent(x: normX, y: normY, dx: dx, dy: dy)`.

### 4.3 Android File Changes
1. **`android/app/src/main/res/xml/accessibility_service_config.xml`**:
   - Add `android:canRetrieveWindowContent="true"`.
   - Add `android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows"`.
2. **`android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`**:
   - Extend `ContinuityListener`:
     - `fun onRemoteText(text: String)`
     - `fun onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double)`
   - In `onMessage`:
     - Parse `"input_text"` -> `listener.onRemoteText(json.optString("text"))`.
     - Parse `"input_scroll"` -> `listener.onRemoteScroll(x, y, dx, dy)`.
     - In `"input_event"`: if `action == "scroll"`, forward `dx`, `dy`.
3. **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`**:
   - Implement `onRemoteText` -> forward to `ContinuityAccessibilityService.instance?.handleTextInput(text)`.
   - Implement `onRemoteScroll` -> forward to `ContinuityAccessibilityService.instance?.handleScroll(x, y, dx, dy)`.
4. **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt`**:
   - Add `findActiveInputNode(): AccessibilityNodeInfo?`:
     - Tries `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)`.
     - Falls back to `rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)`.
     - Falls back to recursive hierarchy search for `isFocused && isEditable`.
   - Add `handleTextInput(text: String)`:
     - Retrieves active node, gets current text and selection bounds.
     - Replaces range with `text` via `AccessibilityNodeInfo.ACTION_SET_TEXT`.
     - Updates cursor via `AccessibilityNodeInfo.ACTION_SET_SELECTION`.
     - Falls back to clipboard paste (`ACTION_PASTE`) if needed.
   - Update `handleKeyInput(key: String, keyCode: Int)`:
     - For `BACKSPACE` / `DEL` (67): Deletes character preceding cursor or selection range via `ACTION_SET_TEXT`.
     - For `ENTER` (66): Calls `ACTION_IME_ACTION` (API 30+) or inserts `"\n"`.
     - For navigation keys: Calls `performGlobalAction(...)`.
   - Add `handleScroll(normalizedX: Double, normalizedY: Double, dx: Double, dy: Double)`:
     - Maps `(normalizedX, normalizedY)` to display pixels `(startX, startY)`.
     - Translates trackpad scroll delta to touch swipe:
       `val endX = (startX - dx * 3.0f).coerceIn(0f, displayWidth.toFloat())`
       `val endY = (startY - dy * 3.0f).coerceIn(0f, displayHeight.toFloat())`
     - Builds `Path` and dispatches via `dispatchGesture` with ~100ms duration.
5. **`android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`**:
   - Add helper calculation `resolveScrollVector(...)` and unit tests in `ScreenMirroringUnitTest.kt`.

---

## 5. Verification Method

### 5.1 Automated Unit Tests
1. **macOS Unit Tests**:
   - Command: `swift test --package-path mac/`
   - Verifies: `ContinuityMessage` encoding/decoding of `input_text`, `input_scroll`, `dx`, `dy`.
2. **Android JVM Unit Tests**:
   - Command: `cd android && JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home ./gradlew testDebugUnitTest`
   - Verifies: `RemoteInputMapper` scroll calculations, `WebSocketClient` parsing of `input_text` and `input_scroll`.

### 5.2 Device Verification on Samsung Galaxy A70 (`R58M5763N2Y`)
1. **Compilation & Installation**:
   - Command: `cd android && JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home ./gradlew assembleDebug`
   - Install: `/tmp/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk`
2. **Functional Keystroke & Typing Verification**:
   - Open a text input field on phone (e.g. Chrome search bar, Notes, or Messages).
   - Click mirror window on Mac. Type `"Hello Galaxy Continuity"`.
   - Verify text appears verbatim in the phone's active input field.
   - Press Backspace: verify characters delete one by one.
   - Press Return: verify search/action executes or newline inserts.
3. **Functional Trackpad Scrolling Verification**:
   - Open Settings or a web page on phone.
   - Place cursor over mirror window and swipe two fingers up and down on Mac trackpad.
   - Verify page scrolls smoothly matching the direction and speed of the trackpad gesture.

### 5.3 Invalidation Conditions
- If `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)` returns null when an `EditText` has keyboard focus, check if `canRetrieveWindowContent` was loaded and `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` is enabled in `ContinuityAccessibilityService`.
- If trackpad gestures stutter, adjust the delta accumulation window and gesture duration (optimal: 80–120ms).
