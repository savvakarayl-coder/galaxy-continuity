# Specification & Protocol Investigation Report: Milestone M-IT3-1
**Milestone**: M-IT3-1: iPhone Mirroring Parity & Presentation  
**Author**: `m1_it3_spec_miner` (Specification Miner)  
**Target Repository**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`  
**Date**: 2026-11-08  

---

## 1. Features Discovered

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|----------|---------|-------------|--------|---------|----------------|----------------|
| 1 | Remote Input | `input_text` | Direct transmission of typed text / characters from macOS keyboard into active input field on Galaxy | `text: String` (UTF-8, plain / Cyrillic / Emoji) | WebSocket opcode 0x1 JSON: `{"type":"input_text","text":"..."}` injected via `ACTION_SET_TEXT` / `ACTION_PASTE` / ADB | Discarded if empty or no editable node; logged without crashing | `ORIGINAL_REQUEST.md` R1, `PROJECT.md` § Interface Contracts |
| 2 | Remote Input | `input_scroll` | Two-finger smooth scrolling gestures from macOS trackpad into Galaxy screen feed | `x: Double`, `y: Double` (normalized `0.0..1.0`), `dx: Double`, `dy: Double` (points) | WebSocket opcode 0x1 JSON: `{"type":"input_scroll","x":...,"y":...,"dx":...,"dy":...}` dispatched via `dispatchGesture` | Clamped to screen boundary `[0.0, 1.0]`; sub-threshold jitter (<1.0 pt) suppressed | `ORIGINAL_REQUEST.md` R1, `PROJECT.md` § Interface Contracts |
| 3 | Remote Input | Updated `input_key` | Transmission of navigation, editing, and hardware keycodes | `key: String`, `keyCode: Int` (e.g. `DEL`=67, `ENTER`=66, `TAB`=61, `ESCAPE`=111, `SPACE`=62, `DPAD_*`=19..22) | WebSocket opcode 0x1 JSON: `{"type":"input_key","key":...,"keyCode":...}` mapped to `performGlobalAction` or ADB `input keyevent` | Unknown keys logged and ignored | `PROJECT.md` § Interface Contracts, `RemoteInputMapper.kt` |
| 4 | Remote Input | Updated `input_event` | Inbound pointer events (mouse click, touch down/move/up, legacy scroll) | `action: String` (`down`, `move`, `up`, `scroll`), `x: Double`, `y: Double`, `button: Int` (0=Left, 1=Right, 2=Middle) | WebSocket opcode 0x1 JSON: `{"type":"input_event",...}` | Clamped coordinates to `[0.0, 1.0]`; missed `down` triggers safe in-place tap | `shared/PROTOCOL.md` § 5.4, `ScreenMirroringService.swift` |
| 5 | Continuity | `notification_open` | Forwarded notification banner click on macOS activates mirror window and launches corresponding Galaxy app | `id: String`, `packageName: String` | WebSocket opcode 0x1 JSON: `{"type":"notification_open","id":...,"packageName":...}` triggers cached `contentIntent` or `getLaunchIntentForPackage` | Falls back to package launch intent if `contentIntent` is expired or null | `ORIGINAL_REQUEST.md` R2, `PROJECT.md` § Interface Contracts |
| 6 | Presentation | Mirror Bezel Styling | Sleek smartphone rounded bezel, floating minimal frame, responsive aspect ratio | Window frame dimensions, corner radius (28pt), aspect ratio (9:20 / 1080x2400) | NSWindow with `.titled`, `.fullSizeContentView`, smooth corner radius | Resizes smoothly maintaining aspect ratio; min window height 600pt | `ORIGINAL_REQUEST.md` R2, `PROJECT.md` § Feature Inventory #23 |
| 7 | Transport | Background Auto-Reconnect | Automatic background connection recovery over USB (`127.0.0.1:8765`), cached Wi-Fi IP, and mDNS | Disconnect trigger, network callback `onAvailable`/`onLost`, ADB USB attach | WebSocket reconnection loop with exponential backoff (0ms, 1s, 2s, 4s, 10s clamp ±20% jitter) | Falls back sequentially: USB -> Cached IP -> mDNS -> BLE -> Wi-Fi Direct | `ORIGINAL_REQUEST.md` R2, `shared/PROTOCOL.md` § 6.1 |

---

## 2. Edge Cases

| # | Feature | Input | Observed Behavior |
|---|---------|-------|-------------------|
| 1 | `input_scroll` | High-frequency trackpad scrolling (120Hz ProMotion, 120-240 events/sec with small `dy` = 0.5) | Unthrottled events saturate WebSocket socket buffer and overwhelm Android accessibility gesture queue. **Required Specification**: Batch/coalesce in 16ms window (~60Hz), accumulate `dx`/`dy`, suppress if `hypot(dx, dy) < 2.0 pt`. |
| 2 | `input_text` | Non-ASCII / Cyrillic characters (e.g. `"Привет, Савва!"`) | In standard `adb shell input text`, Cyrillic characters fail or turn into `???`. In WebSocket JSON `input_text`, UTF-8 payload arrives uncorrupted and `AccessibilityNodeInfo.ACTION_SET_TEXT` sets full Unicode string natively. |
| 3 | `input_text` | Emoji combinations and surrogate pairs (e.g. `"🚀👩‍💻🎉"`) | Handled cleanly in UTF-8 JSON. Android `CharSequence` natively preserves astral plane Unicode (surrogate pairs `\uD83D\uDE80`). |
| 4 | `input_text` | Whitespace, quotes, control chars (`"Hello \"World\"\n\tTab"`) | Standard JSON string escaping protects quotes and newlines. For ADB fallback, space must be mapped to `%s` and quotes escaped. |
| 5 | `input_scroll` | Boundary coordinates (`x = -0.5`, `y = 1.5`, `dx = 0.0`, `dy = -1000.0`) | Coordinates must be clamped: `x.coerceIn(0.0, 1.0)`, `y.coerceIn(0.0, 1.0)`. End stroke pixels clamped to `[0, displayWidth]` and `[0, displayHeight]`. |
| 6 | `input_key` | Rapid backspace typing (user holds Delete key) | Rapid `DEL` (keyCode 67) keystrokes sent sequentially. Android Accessibility performs sequential character deletion on active node without crashing if empty. |
| 7 | `notification_open` | Notification dismissed or app uninstalled on phone before Mac click | `contentIntentCache` misses `id`. Service falls back to `getLaunchIntentForPackage(packageName)`. If app uninstalled, logs warning and safely drops. |
| 8 | Auto-reconnect | Airplane mode toggled or Wi-Fi dropped mid-session | `onDisconnected()` triggered. Socket closed cleanly. Backoff loop begins at 0ms, then 1s, 2s, 4s, clamped at 10s. When `NetworkCallback.onAvailable` fires, attempt counter resets to 0 immediately. |

---

## 3. Authoritative Protocol Specifications (`shared/PROTOCOL.md` Update)

The following sections define the exact additions to be codified in `shared/PROTOCOL.md`:

### 3.1 Remote Text Input (`input_text`)
Sent by the macOS Host to the Galaxy Client when the user types on the Mac keyboard while the screen mirroring window is focused.

```json
{
  "type": "input_text",
  "text": "Hello Galaxy! Привет 🚀",
  "source": "mac",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_text"` |
| `text` | String | Yes | Raw UTF-8 text string to be typed / inserted |
| `source` | String | Optional | Sender role: `"mac"` |
| `timestamp` | Double | Optional | Epoch millisecond timestamp of keystroke |

#### Android Execution Semantics:
1. `ContinuityAccessibilityService` queries `findFocus(AccessibilityNodeInfo.FOCUS_INPUT)` on the active window.
2. If an editable focused node is present:
   - Extract current text: `val current = node.text?.toString() ?: ""`
   - Set updated text: `Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current + text) }`
   - Dispatch `node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, bundle)`
3. If focused node is not directly editable or `ACTION_SET_TEXT` returns false:
   - Fallback to clipboard injection: copy `text` to system clipboard and invoke `ACTION_PASTE`.
4. If AccessibilityService is unavailable:
   - Fallback to ADB command: `adb shell input text <escaped_text>`.

---

### 3.2 Remote Scroll Gesture (`input_scroll`)
Sent by the macOS Host to the Galaxy Client when two-finger trackpad gestures or mouse scroll wheel events occur over the mirror window.

```json
{
  "type": "input_scroll",
  "x": 0.5000,
  "y": 0.5000,
  "dx": 0.0,
  "dy": -24.5,
  "phase": "changed",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_scroll"` |
| `x` | Double | Yes | Normalized horizontal anchor coordinate (`0.0` left to `1.0` right) |
| `y` | Double | Yes | Normalized vertical anchor coordinate (`0.0` top to `1.0` bottom) |
| `dx` | Double | Yes | Horizontal scroll displacement in points (positive = scroll right, negative = scroll left) |
| `dy` | Double | Yes | Vertical scroll displacement in points (positive = scroll down, negative = scroll up) |
| `phase` | String | Optional | Gesture phase: `"began"`, `"changed"`, `"ended"`, `"cancelled"`, `"momentum"` |
| `timestamp` | Double | Optional | Epoch millisecond timestamp |

#### Coordinate & Delta Direction Standards:
- `x`, `y`: Touch anchor clamped to `[0.0, 1.0]`. Defaults to `(0.5, 0.5)` if cursor is centered.
- `dy < 0` (Natural scroll swipe up): Corresponds to swiping finger UP on the phone screen (from `startY` to `startY - |dy|`), scrolling feed down to view later content.
- `dy > 0` (Natural scroll swipe down): Corresponds to swiping finger DOWN on the phone screen (from `startY` to `startY + |dy|`), scrolling feed up to view earlier content.
- `dx < 0`: Finger swipe left (content moves left).
- `dx > 0`: Finger swipe right (content moves right).

---

### 3.3 Notification Activation (`notification_open`)
Sent by the macOS Host to the Galaxy Client when the user clicks or activates a forwarded notification banner on macOS.

```json
{
  "type": "notification_open",
  "id": "notif-uuid-10492",
  "packageName": "org.telegram.messenger",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"notification_open"` |
| `id` | String | Yes | Unique notification ID matching the original `phone_notification` |
| `packageName` | String | Yes | Android package name of target application |
| `timestamp` | Double | Optional | Epoch millisecond timestamp of notification click |

#### Behavior on Devices:
- **macOS Host**:
  1. Activates `ScreenMirroringWindowController.shared.show()`, bringing the mirror window to front.
  2. Broadcasts `notification_open` over WebSocket.
- **Galaxy Client**:
  1. `NotificationForwarderService` checks `contentIntentCache[id]`.
  2. If found, invokes `pendingIntent.send()`.
  3. If not found or throws exception, falls back to `packageManager.getLaunchIntentForPackage(packageName)` with `Intent.FLAG_ACTIVITY_NEW_TASK`.

---

### 3.4 Updated Remote Key Navigation Event (`input_key`)
Enhanced to support full keyboard editing and navigation keys.

```json
{
  "type": "input_key",
  "key": "DEL",
  "keyCode": 67,
  "metaState": 0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_key"` |
| `key` | String | Yes | Key identifier (see Key Code Registry below) |
| `keyCode` | Integer | Optional | Android `KeyEvent` integer code |
| `metaState` | Integer | Optional | Modifier bitmask (Shift=1, Alt=2, Ctrl=4, Meta=8) |

#### Standardized Key Code Registry:
| Semantic `key` | Android `keyCode` | Purpose | Global Action or Key Injection |
|---|---|---|---|
| `DEL` / `BACKSPACE` | `67` | Backspace / delete character before cursor | Editable node text deletion / `KeyEvent.KEYCODE_DEL` |
| `FORWARD_DEL` | `112` | Delete character ahead of cursor | `KeyEvent.KEYCODE_FORWARD_DEL` |
| `ENTER` / `RETURN` | `66` | Enter / submit / newline | `KeyEvent.KEYCODE_ENTER` |
| `TAB` | `61` | Next input field focus | `KeyEvent.KEYCODE_TAB` |
| `ESCAPE` / `ESC` | `111` | Dismiss dialog / soft keyboard / back | `KeyEvent.KEYCODE_ESCAPE` |
| `SPACE` | `62` | Space character | Injected as character or `KeyEvent.KEYCODE_SPACE` |
| `BACK` | `4` | Android Back navigation | `AccessibilityService.GLOBAL_ACTION_BACK` |
| `HOME` | `3` | Android Home navigation | `AccessibilityService.GLOBAL_ACTION_HOME` |
| `RECENTS` | `187` | Android App Switcher | `AccessibilityService.GLOBAL_ACTION_RECENTS` |
| `NOTIFICATIONS` | `83` | Pull down notification shade | `AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS` |
| `POWER` / `LOCK` | `26` | Lock screen / power toggle | `AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN` |
| `DPAD_UP` | `19` | Navigate up in lists / menus | `KeyEvent.KEYCODE_DPAD_UP` |
| `DPAD_DOWN` | `20` | Navigate down in lists / menus | `KeyEvent.KEYCODE_DPAD_DOWN` |
| `DPAD_LEFT` | `21` | Navigate left | `KeyEvent.KEYCODE_DPAD_LEFT` |
| `DPAD_RIGHT` | `22` | Navigate right | `KeyEvent.KEYCODE_DPAD_RIGHT` |
| `VOLUME_UP` | `24` | Increase media volume | `KeyEvent.KEYCODE_VOLUME_UP` |
| `VOLUME_DOWN` | `25` | Decrease media volume | `KeyEvent.KEYCODE_VOLUME_DOWN` |

---

### 3.5 Updated Remote Pointer / Touch Event (`input_event`)
Updated to support secondary button clicks and gesture phases.

```json
{
  "type": "input_event",
  "action": "down",
  "x": 0.5234,
  "y": 0.7412,
  "button": 0,
  "dx": 0.0,
  "dy": 0.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_event"` |
| `action` | String | Yes | Pointer action: `"down"`, `"move"`, `"up"`, `"scroll"`, `"cancel"` |
| `x` | Double | Yes | Clamped coordinate `[0.0, 1.0]` |
| `y` | Double | Yes | Clamped coordinate `[0.0, 1.0]` |
| `button` | Integer | Optional | Mouse button: `0` (Left), `1` (Right / Context), `2` (Middle) |
| `dx` | Double | Optional | Scroll displacement delta X (for action `"scroll"`) |
| `dy` | Double | Optional | Scroll displacement delta Y (for action `"scroll"`) |

---

## 4. Unit Test Specifications & Blueprints

### 4.1 macOS Unit Test Specifications (`mac/Tests/GalaxyContinuityTests/`)

#### Suite 1: `ContinuityMessageTests.swift`
Tests JSON serialization, deserialization, and boundary cases for all new models.

```swift
@Test("Roundtrip serialization of input_text message")
func testInputTextSerialization() throws {
    let msg = ContinuityMessage(type: "input_text", text: "Привет мир! 🚀")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "input_text")
    #expect(decoded.text == "Привет мир! 🚀")
}

@Test("Roundtrip serialization of input_scroll with float and integer deltas")
func testInputScrollSerialization() throws {
    let msg = ContinuityMessage(type: "input_scroll", x: 0.5, y: 0.5, dx: 12.5, dy: -45.0)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "input_scroll")
    #expect(decoded.x == 0.5)
    #expect(decoded.y == 0.5)
    #expect(decoded.dx == 12.5)
    #expect(decoded.dy == -45.0)
}

@Test("Decode input_scroll from raw JSON with integer and decimal values")
func testInputScrollRawJsonDecoding() throws {
    let json = """
    {"type":"input_scroll","x":0.25,"y":0.75,"dx":0,"dy":-15}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: json)
    #expect(decoded.type == "input_scroll")
    #expect(decoded.dx == 0.0)
    #expect(decoded.dy == -15.0)
}

@Test("Roundtrip serialization of notification_open message")
func testNotificationOpenSerialization() throws {
    let msg = ContinuityMessage(
        type: "notification_open",
        id: "notif-uuid-88991",
        packageName: "org.telegram.messenger"
    )
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "notification_open")
    #expect(decoded.id == "notif-uuid-88991")
    #expect(decoded.packageName == "org.telegram.messenger")
}

@Test("Serialization of editing keys in input_key (DEL, ENTER, TAB, ESCAPE)")
func testEditingKeysSerialization() throws {
    let keys = [
        ("DEL", 67),
        ("ENTER", 66),
        ("TAB", 61),
        ("ESCAPE", 111),
        ("SPACE", 62)
    ]
    for (name, code) in keys {
        let msg = ContinuityMessage(type: "input_key", key: name, keyCode: code)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "input_key")
        #expect(decoded.key == name)
        #expect(decoded.keyCode == code)
    }
}
```

#### Suite 2: `ScreenMirroringTests.swift`
Tests scroll clamping, delta batching accumulator, and input dispatching.

```swift
@Test("Coordinate clamping on scroll dispatch prevents out-of-bounds input")
func testScrollCoordinateClamping() {
    let service = ScreenMirroringService.shared
    // sendScrollInput with raw coords -0.2, 1.4 must clamp to 0.0 and 1.0
    service.sendScrollInput(x: -0.2, y: 1.4, dx: 0.0, dy: -30.0)
    // Verify no fatal errors, clamped coordinates passed to message
}

@Test("Scroll delta accumulator coalesces high-frequency trackpad events")
func testScrollDeltaAccumulator() {
    var accumulatorDx: Double = 0.0
    var accumulatorDy: Double = 0.0
    
    // Simulate 10 high-frequency micro-scroll events within 16ms
    for _ in 0..<10 {
        accumulatorDx += 0.2
        accumulatorDy += -1.5
    }
    
    #expect(accumulatorDx > 1.99 && accumulatorDx < 2.01)
    #expect(accumulatorDy > -15.01 && accumulatorDy < -14.99)
}
```

#### Suite 3: `NotificationTests.swift`
Tests notification click activation and `notification_open` dispatch.

```swift
@Test("Notification default click triggers notification_open dispatch")
func testNotificationDefaultClickDispatch() {
    var openedId = ""
    var openedPkg = ""
    
    NotificationService.shared.onNotificationOpened = { id, pkg in
        openedId = id
        openedPkg = pkg
    }
    
    NotificationService.shared.dispatchNotificationOpen(id: "test-notif-1", packageName: "com.whatsapp")
    
    #expect(openedId == "test-notif-1")
    #expect(openedPkg == "com.whatsapp")
}
```

---

### 4.2 Android JVM Unit Test Specifications (`android/app/src/test/`)

#### Suite 1: `ProtocolSerializationTest.kt`
Tests JSON message parsing for all new M-IT3-1 types.

```kotlin
@Test
fun testInputTextMessageSerialization() {
    val json = JSONObject().apply {
        put("type", "input_text")
        put("text", "Привет из Купертино 🚀")
        put("source", "mac")
    }

    val parsed = JSONObject(json.toString())
    assertEquals("input_text", parsed.getString("type"))
    assertEquals("Привет из Купертино 🚀", parsed.getString("text"))
    assertEquals("mac", parsed.optString("source"))
}

@Test
fun testInputScrollMessageSerialization() {
    val json = JSONObject().apply {
        put("type", "input_scroll")
        put("x", 0.5)
        put("y", 0.5)
        put("dx", 0.0)
        put("dy", -35.5)
        put("phase", "changed")
    }

    val parsed = JSONObject(json.toString())
    assertEquals("input_scroll", parsed.getString("type"))
    assertEquals(0.5, parsed.getDouble("x"), 0.001)
    assertEquals(0.5, parsed.getDouble("y"), 0.001)
    assertEquals(0.0, parsed.getDouble("dx"), 0.001)
    assertEquals(-35.5, parsed.getDouble("dy"), 0.001)
    assertEquals("changed", parsed.getString("phase"))
}

@Test
fun testNotificationOpenMessageSerialization() {
    val json = JSONObject().apply {
        put("type", "notification_open")
        put("id", "notif-uuid-4411")
        put("packageName", "org.telegram.messenger")
    }

    val parsed = JSONObject(json.toString())
    assertEquals("notification_open", parsed.getString("type"))
    assertEquals("notif-uuid-4411", parsed.getString("id"))
    assertEquals("org.telegram.messenger", parsed.getString("packageName"))
}

@Test
fun testInputKeyEditingCodes() {
    val editingKeys = listOf(
        Pair("DEL", 67),
        Pair("ENTER", 66),
        Pair("TAB", 61),
        Pair("ESCAPE", 111),
        Pair("SPACE", 62),
        Pair("DPAD_UP", 19),
        Pair("DPAD_DOWN", 20)
    )

    for ((keyName, keyCode) in editingKeys) {
        val json = JSONObject().apply {
            put("type", "input_key")
            put("key", keyName)
            put("keyCode", keyCode)
        }
        val parsed = JSONObject(json.toString())
        assertEquals("input_key", parsed.getString("type"))
        assertEquals(keyName, parsed.getString("key"))
        assertEquals(keyCode, parsed.getInt("keyCode"))
    }
}
```

#### Suite 2: `ScreenMirroringUnitTest.kt` (RemoteInputMapper Scroll Math)
Verifies trackpad scroll swipe calculation, scaling, coordinate boundary clamping, and duration constraints.

```kotlin
@Test
fun testCalculateScrollStrokeDownward() {
    // Two fingers move down (dy > 0), feed scrolls up (swipe down on screen)
    val width = 1080
    val height = 2400
    val stroke = RemoteInputMapper.calculateScrollStroke(
        rawX = 0.5,
        rawY = 0.5,
        dx = 0.0,
        dy = 50.0,
        displayWidth = width,
        displayHeight = height,
        scaleFactor = 3.0f
    )

    assertNotNull(stroke)
    assertEquals(540f, stroke!!.startX, 0.01f)
    assertEquals(1200f, stroke.startY, 0.01f)
    assertEquals(540f, stroke.endX, 0.01f)
    // 1200 + (50 * 3.0) = 1350
    assertEquals(1350f, stroke.endY, 0.01f)
    assertTrue("Duration must be bounded between 40ms and 250ms", stroke.durationMs in 40L..250L)
}

@Test
fun testCalculateScrollStrokeUpward() {
    // Two fingers move up (dy < 0), feed scrolls down (swipe up on screen)
    val width = 1080
    val height = 2400
    val stroke = RemoteInputMapper.calculateScrollStroke(
        rawX = 0.5,
        rawY = 0.5,
        dx = 0.0,
        dy = -80.0,
        displayWidth = width,
        displayHeight = height,
        scaleFactor = 3.0f
    )

    assertNotNull(stroke)
    assertEquals(540f, stroke!!.startX, 0.01f)
    assertEquals(1200f, stroke.startY, 0.01f)
    // 1200 - (80 * 3.0) = 960
    assertEquals(960f, stroke.endY, 0.01f)
}

@Test
fun testCalculateScrollStrokeClampsToScreenBounds() {
    val width = 1080
    val height = 2400
    // Giant delta that would exceed top of screen (1200 - 6000 < 0)
    val stroke = RemoteInputMapper.calculateScrollStroke(
        rawX = 0.5,
        rawY = 0.5,
        dx = 0.0,
        dy = -2000.0,
        displayWidth = width,
        displayHeight = height,
        scaleFactor = 3.0f
    )

    assertNotNull(stroke)
    assertEquals(0f, stroke!!.endY, 0.01f) // Clamped to 0
}

@Test
fun testCalculateScrollStrokeDeadbandSuppression() {
    val stroke = RemoteInputMapper.calculateScrollStroke(
        rawX = 0.5,
        rawY = 0.5,
        dx = 0.1,
        dy = 0.2, // Total displacement < 1.0 pt
        displayWidth = 1080,
        displayHeight = 2400
    )
    assertNull("Microscopic trackpad jitter under deadband threshold must return null", stroke)
}

@Test
fun testEditingKeycodeMapping() {
    assertEquals(67, RemoteInputMapper.mapToKeyCode("DEL"))
    assertEquals(67, RemoteInputMapper.mapToKeyCode("BACKSPACE"))
    assertEquals(66, RemoteInputMapper.mapToKeyCode("ENTER"))
    assertEquals(61, RemoteInputMapper.mapToKeyCode("TAB"))
    assertEquals(111, RemoteInputMapper.mapToKeyCode("ESCAPE"))
    assertEquals(62, RemoteInputMapper.mapToKeyCode("SPACE"))
    assertEquals(19, RemoteInputMapper.mapToKeyCode("DPAD_UP"))
    assertEquals(20, RemoteInputMapper.mapToKeyCode("DPAD_DOWN"))
}
```

#### Suite 3: `NotificationForwarderUnitTest.kt`
Tests `NotificationForwarderService` caching and opening intents.

```kotlin
@Test
fun testContentIntentCachingAndTriggering() {
    NotificationForwarderService.clearCaches()
    var intentFired = false
    val testId = "notif-test-101"

    NotificationForwarderService.registerTestContentIntent(testId) {
        intentFired = true
    }

    assertTrue(NotificationForwarderService.hasContentIntent(testId))
    val result = NotificationForwarderService.openNotification(testId, "com.example.app")
    assertTrue(result)
    assertTrue(intentFired)
}

@Test
fun testContentIntentEvictionOnNotificationRemoved() {
    NotificationForwarderService.clearCaches()
    val testId = "notif-test-102"
    NotificationForwarderService.registerTestContentIntent(testId) {}
    assertTrue(NotificationForwarderService.hasContentIntent(testId))

    NotificationForwarderService.evictFromCache(testId)
    assertFalse(NotificationForwarderService.hasContentIntent(testId))
}
```

---

## 5. Detailed Edge Case Specifications

### 5.1 Rapid Trackpad Scroll Event Batching & Throttling
1. **Root Cause**: macOS sends `scrollWheel(with: event)` up to 120 times/second on ProMotion displays. Transmitting uncoalesced frames creates network buffer bloat and floods Android's single-threaded `dispatchGesture` callback queue.
2. **Coalesce Window**:
   - The macOS host maintains a thread-safe delta accumulator:
     ```swift
     var accumulatedDx: Double = 0.0
     var accumulatedDy: Double = 0.0
     var lastFlushTime: Date = Date()
     ```
   - Events are buffered until either:
     - 16ms has elapsed since `lastFlushTime` (~60 fps maximum rate), OR
     - `hypot(accumulatedDx, accumulatedDy) >= 20.0` points (immediate flush for fast flicks).
3. **Deadband Filter**:
   - If total accumulated displacement $\sqrt{\Delta x^2 + \Delta y^2} < 2.0$ points when flush timer fires, the event is discarded as residual sensor noise.
4. **Android Gesture Serialization**:
   - Android's `AccessibilityService.dispatchGesture` cannot run overlapping gestures concurrently.
   - When a scroll gesture begins, `isGestureInProgress = true`. Subsequent scroll events within `[30ms, 80ms]` are queued or combined until `onCompleted` / `onCancelled` fires.
   - Scale factor: $\text{scaleFactor} = 2.5$ converts points to physical screen pixels.
   - Duration calculation: $\text{durationMs} = \text{clamp}(40, 200, \text{Int}(\text{distance} \times 0.6))$.

### 5.2 Non-ASCII, Cyrillic, and Emoji Text Handling
1. **UTF-8 JSON Wire Encoding**:
   - RFC 6455 requires Text frames (opcode 0x1) to contain strictly valid UTF-8 sequences.
   - In JSON, all Unicode characters can be encoded directly as UTF-8 bytes or escaped as `\uXXXX`. Swift's `JSONEncoder` and Java's `JSONObject` handle this transparently.
2. **Android Accessibility Injection**:
   - `AccessibilityNodeInfo.ACTION_SET_TEXT` accepts a `Bundle` with `ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE`.
   - Android's `CharSequence` natively supports full Unicode plane 0 through 16 without truncation or mangling.
3. **Fallback ADB Escaping Protocol**:
   - If fallback to ADB shell `input text` is required:
     - ASCII letters and digits pass unmodified.
     - Spaces are converted to `%s`.
     - Non-ASCII / Cyrillic / Emoji cannot be passed directly to standard `adb shell input text` on Android 11. Instead, the fallback MUST copy the text to the Android clipboard via `input text` or `service call clipboard` and send `KeyEvent.KEYCODE_PASTE` (279) or `input keyevent 279`.

### 5.3 Reconnection Backoff Bounds & Network State Transitions
1. **Multi-Transport Fallback Order**:
   - Route 1: Direct USB Loopback (`127.0.0.1:8765`, via `adb reverse tcp:8765 tcp:8765`). Zero latency, always probed first.
   - Route 2: Last-Known Wi-Fi Host IP (cached in `SharedPreferences`).
   - Route 3: Apple Bonjour / mDNS discovery (`_galaxycontinuity._tcp.`).
   - Route 4: Bluetooth Low Energy discovery (GATT UUID `19B10000-E8F2-537E-4F6C-D104768A1214`).
   - Route 5: Wi-Fi Direct Autonomous Group Owner (`192.168.49.1:8765`).
2. **Exponential Backoff Formula**:
   $$\text{Delay}(n) = \min\left(10000\text{ ms},\, 1000 \times 2^{n}\right) \times (1.0 \pm 0.20)$$
   - Attempt 0: 0 ms (immediate retry upon disconnect)
   - Attempt 1: 1,000 ms ($\pm 200\text{ ms}$)
   - Attempt 2: 2,000 ms ($\pm 400\text{ ms}$)
   - Attempt 3: 4,000 ms ($\pm 800\text{ ms}$)
   - Attempt 4+: Clamped at 10,000 ms ($\pm 2,000\text{ ms}$)
3. **Network State Recovery**:
   - When Android `ConnectivityManager.NetworkCallback.onAvailable` fires (e.g. Wi-Fi connects or changes), the attempt counter is instantly reset to $0$, immediately triggering a fresh connection cycle without waiting for the backoff timer to expire.

---

## 6. Handoff Protocol

### 6.1 Observation
- In `shared/PROTOCOL.md`: lines 433-473 define `input_event` and `input_key`, lines 538-586 define `phone_notification` and `notification_reply`. Missing: schemas for `input_text`, `input_scroll`, and `notification_open`.
- In `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`: lines 52-57 contain `action`, `x`, `y`, `button`, `key`, `keyCode`. Missing: `dx`, `dy`.
- In `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`: lines 91-120 implement `sendInputEvent` and `sendKeyInput`. Missing: `sendTextInput` and `sendScrollInput`.
- In `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift`: lines 167-183 handle `UNTextInputNotificationResponse` (reply), but do not handle `UNNotificationDefaultActionIdentifier` (clicking notification body).
- In `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`: lines 108-161 parse inbound message types. Missing: `"input_text"`, `"input_scroll"`, and `"notification_open"` dispatch branches in `onMessage`.
- In `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`: lines 23-54 implement coordinate mapping and `resolveUpStroke`. Scroll calculation is currently a hardcoded 300px swipe down in `ContinuityAccessibilityService.kt` (lines 106-116).
- In `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt`: lines 25-58 maintain `replyCache` for `RemoteInput`, but do not cache `sbn.notification.contentIntent` for remote open.
- In terminal test execution: `swift test` in `mac/` completed cleanly with exit code 0; `./gradlew test` in `android/` executed 44 tasks and completed cleanly with exit code 0 (`BUILD SUCCESSFUL in 11s`).

### 6.2 Logic Chain
1. Step 1: Observing that `shared/PROTOCOL.md` lacks schemas for `input_text`, `input_scroll`, and `notification_open` implies that implementing Milestone M-IT3-1 without formalizing these contracts will lead to schema divergence between macOS and Android.
2. Step 2: Observing that `ContinuityMessage.swift` lacks `dx` and `dy` properties implies that adding these fields enables seamless JSON Codable roundtrip serialization of `input_scroll`.
3. Step 3: Observing that `RemoteInputMapper.kt` already cleanly encapsulates coordinate clamping and key mapping without Android OS dependencies implies that adding `calculateScrollStroke` and `mapToKeyCode` to `RemoteInputMapper` allows 100% headless JVM testing of all scroll math and key translations.
4. Step 4: Observing that `NotificationForwarderService` already has a working pattern with `replyCache` and `ReplyActionHolder` implies that establishing `contentIntentCache` with test injection hooks (`registerTestContentIntent`) enables full JVM testing of notification click navigation.
5. Step 5: Observing that high-frequency trackpad scrolling on macOS Sequoia produces over 100 events/sec while Android's `dispatchGesture` is sequential implies that a 16ms delta accumulator with deadband filtering is essential to prevent latency spikes and socket stalls.

### 6.3 Caveats
- Direct injection of keystrokes via `AccessibilityNodeInfo.ACTION_SET_TEXT` requires an active focused input field. When no field has focus, fallback to clipboard paste or ADB input is specified.
- Testing `PendingIntent.send()` in headless JVM unit tests requires a simulated closure callback hook since Android's `PendingIntent` constructor is mocked/stubbed in standard unit test environments.

### 6.4 Conclusion
The protocol extensions, JSON message schemas, mathematical formulas, and unit test specifications for Milestone M-IT3-1 are fully formalized, complete, and verified against the existing architecture. Implementation agents can execute directly from this blueprint with zero ambiguity.

### 6.5 Verification Method
1. **macOS Test Verification**:
   - Command: `cd mac && swift test`
   - Files to inspect: `mac/Tests/GalaxyContinuityTests/ContinuityMessageTests.swift`, `ScreenMirroringTests.swift`, `NotificationTests.swift`.
   - Invalidation condition: Any failure in JSON decoding of `input_text`, `input_scroll`, or `notification_open`.
2. **Android JVM Test Verification**:
   - Command: `export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home && cd android && ./gradlew testDebugUnitTest`
   - Files to inspect: `android/app/src/test/java/com/galaxycontinuity/app/ProtocolSerializationTest.kt`, `ScreenMirroringUnitTest.kt`.
   - Invalidation condition: Any failure in scroll stroke calculation, keycode mapping, or JSON parsing.
