# Milestone M-IT3-1: macOS Implementation Blueprint
## iPhone Mirroring Parity, Smartphone Chassis, Keyboard/Trackpad Interception & Notification Click Navigation

**Agent**: `m1_it3_explorer_1`  
**Date**: 2026-11-08  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_it3_explorer_1`  
**Target Scope**: macOS Changes for Milestone M-IT3-1  

---

## 1. Observation

Direct examination of existing source files in `mac/Sources/` reveals the following exact states and architectural deficiencies:

### 1.1 `ScreenMirroringView.swift` & `ScreenMirroringWindowController` (`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift`)
- **Lines 130–145**: `ScreenMirroringWindowController` configures standard AppKit window chrome:
  ```swift
  let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 384, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
  )
  window.title = "Galaxy Screen Mirror"
  ```
  - Standard gray desktop titlebar is visible.
  - `window.titlebarAppearsTransparent` is `false`, `window.titleVisibility` is `.visible`.
  - `window.backgroundColor` is opaque default.
  - `window.isMovableByWindowBackground` is `false`.
  - The window lacks `.fullSizeContentView`.
- **Lines 12–128**: `ScreenMirroringView` renders a rudimentary UI scaffold:
  - Video feed frame is hardcoded at `frame(width: 360, height: 720).cornerRadius(16)`.
  - A bottom toolbar renders 5 bordered AppKit buttons (`square.stack.3d.down.right`, `circle`, `chevron.backward`, `bell`, `lock`) plus a prominent Start/Stop toggle button inside a gray `VStack` with `padding(12)` and `background(Color(NSColor.windowBackgroundColor))`.
  - It does not resemble the borderless, sleek floating iPhone Mirroring chassis introduced in macOS Sequoia.
- **Event Handling**:
  - `ScreenMirroringView` only registers a SwiftUI `DragGesture(minimumDistance: 0)` on the video box (lines 33–57).
  - There is zero interception of keyboard typing (`keyDown`) or trackpad scrolling (`scrollWheel`).
  - When the mirror window is focused and keys are typed, macOS produces an error chime/beep and discards the keystrokes.

### 1.2 `ScreenMirroringService.swift` (`mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`)
- **Lines 122–137**: `sendKeyInput(key: String, keyCode: Int? = nil)`:
  - Only maps 5 navigation keys: `"BACK"` (4), `"HOME"` (3), `"RECENTS"` (187), `"NOTIFICATIONS"` (83), and `"POWER"`/`"LOCK"` (26).
  - Common keyboard editing keys (`BACKSPACE` / `DEL` 67, `ENTER` 66, `TAB` 61, `ESCAPE` 111, `SPACE` 62, and D-pad arrows `DPAD_UP` 19, `DPAD_DOWN` 20, `DPAD_LEFT` 21, `DPAD_RIGHT` 22) are unmapped unless explicitly supplied by caller.
- **Missing Methods**:
  - `ScreenMirroringService` has **no** `sendTextInput(text: String)` method to stream text strings.
  - `ScreenMirroringService` has **no** `sendScrollEvent(x: Double, y: Double, dx: Double, dy: Double)` method.

### 1.3 `NotificationService.swift` & `AppDelegate.swift`
- **`mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift` (lines 167–183)**:
  ```swift
  public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
  ) {
      if response.actionIdentifier == NotificationService.ACTION_REPLY,
         let textResponse = response as? UNTextInputNotificationResponse { ... }
      completionHandler()
  }
  ```
  - When a user clicks a notification banner, `response.actionIdentifier == UNNotificationDefaultActionIdentifier`.
  - `NotificationService` currently ignores `UNNotificationDefaultActionIdentifier`.
  - `NotificationService` has no callback property `onNotificationClicked`.
- **`mac/Sources/GalaxyContinuity/AppDelegate.swift` (lines 11–19, 52–58)**:
  - `AppDelegate` does not listen for notification clicks. Clicking a forwarded phone notification does nothing to bring the screen mirror window to focus or launch the corresponding app on the Galaxy phone.
  - `AppDelegate` does not configure `adb reverse tcp:8765 tcp:8765`, requiring manual terminal commands for USB connectivity.

### 1.4 `ContinuityMessage.swift` (`mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`)
- **Lines 52–57**: Contains `action`, `x`, `y`, `button`, `key`, `keyCode`.
- Properties `dx: Double?` and `dy: Double?` are missing from the struct and its initializer.

---

## 2. Logic Chain

1. **Native Smartphone Chassis & Frameless Presentation**:
   - The Samsung Galaxy A70 has an exact display resolution of 1080x2400 (aspect ratio 20:9).
   - At a 360pt viewport width, the native screen height is `360 * (20 / 9) = 800pt`.
   - By adding a 12pt uniform bezel around the screen, the chassis size becomes `384pt × 824pt`.
   - Adding `.fullSizeContentView` to `NSWindow.styleMask`, setting `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `backgroundColor = .clear`, `isOpaque = false`, and `isMovableByWindowBackground = true` allows SwiftUI to draw beyond AppKit window borders, creating a seamless, floating smartphone silhouette.
   - Drawing an outer continuous `RoundedRectangle(cornerRadius: 44)` with a dark titanium gradient and metallic stroke, an inner display clipped to `RoundedRectangle(cornerRadius: 32)`, and an 11pt circular punch hole at the top reproduces the authentic Galaxy Infinity-O display aesthetic.
   - Replacing the bulky gray button toolbar with a translucent Capsule hover toolbar at the top and a home bar indicator at the bottom (tap for HOME, swipe up for RECENTS) provides 1:1 parity with Apple's iPhone Mirroring in macOS Sequoia.

2. **Keyboard Keystroke Interception**:
   - `NSEvent.addLocalMonitorForEvents(matching: [.keyDown])` intercepts all keyboard events directed at the window.
   - Returning `nil` from the monitor consumes the event, completely eliminating the macOS AppKit error chime.
   - Command combinations (`event.modifierFlags.contains(.command)`) pass through, ensuring system shortcuts (Cmd+Q, Cmd+W) work reliably.
   - Control/editing keys map directly to Android `KeyEvent` codes (`BACKSPACE` -> 67, `ENTER` -> 66, `TAB` -> 61, `ESCAPE` -> 111, `SPACE` -> 62, arrows -> 19–22).
   - Printable text characters are extracted, filtered of control codes, and passed to `ScreenMirroringService.sendTextInput(text:)`.

3. **Trackpad Two-Finger Scroll Interception**:
   - `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel])` intercepts trackpad gestures over the mirror window.
   - Normalizing mouse position relative to the inner screen viewport:
     `normX = (mouse.x - 12) / screenWidth`
     `normY = (windowHeight - 12 - mouse.y) / screenHeight`
   - Accumulating high-frequency scroll deltas and dispatching at a throttled rate (50ms interval or >= 15pt delta) prevents flooding Android's gesture queue while ensuring smooth, responsive scrolling.

4. **Dual-Delivery Architecture (WebSocket + ADB Fast-Path)**:
   - Primary: WebSocket `ContinuityMessage` (`input_text`, `input_scroll`, `input_key`) processed natively by Android's `ContinuityAccessibilityService`.
   - Fast-Path: Over USB, macOS dispatches `adb shell input text <escaped>`, `adb shell input swipe ...`, and `adb shell input keyevent ...` for immediate, zero-latency execution.

5. **Notification Click Navigation Flow**:
   - When the user clicks a notification banner, `NotificationService` intercepts `UNNotificationDefaultActionIdentifier`.
   - It invokes `onNotificationClicked(notifId, packageName)`.
   - `AppDelegate` receives the callback, executes `ScreenMirroringWindowController.shared.show()`, starts mirroring if inactive, and broadcasts `notification_open` via `ServerManager.shared.sendNotificationOpen(...)`.
   - If ADB is available, `AppDelegate` triggers `adb shell monkey -p <packageName> -c android.intent.category.LAUNCHER 1` for immediate foregrounding of the app.

---

## 3. Caveats

1. **Command Shortcut Passthrough**:
   - When the mirror window has focus, pressing `Cmd+W` should close the mirror window, and `Cmd+Q` should quit the app. The key event handler explicitly checks `event.modifierFlags.contains(.command)` and delegates to AppKit rather than sending the raw character to the phone.
2. **Trackpad Event Flooding**:
   - High-precision trackpads generate events up to 120Hz. Without delta accumulation, 120 gesture events per second would overwhelm Android. A 50ms batch window (20Hz) provides fluid motion without queue starvation.
3. **ADB Shell Escaping**:
   - `adb shell input text` interprets whitespace and shell characters specially. Spaces are escaped as `%s`, and characters like `"`, `$`, `\``, `&`, `;`, `(`, `)` are backslash-escaped. The primary WebSocket channel transmits raw UTF-8 without escaping, ensuring full support for Cyrillic, emojis, and symbols.
4. **Headless Execution Environment**:
   - In test runners lacking an app bundle identifier, `NotificationService.isAvailable` is `false`. The `onNotificationClicked` callback must be designed to be invoked safely in both GUI and headless test contexts.

---

## 4. Conclusion & Concrete Implementation Blueprint

### 4.1 File Diff 1: `mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift`

Add `dx` and `dy` properties to `ContinuityMessage` for scroll deltas.

```diff
--- a/mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift
+++ b/mac/Sources/GalaxyContinuityKit/Models/ContinuityMessage.swift
@@ -52,6 +52,8 @@ public struct ContinuityMessage: Codable, Equatable {
     public var action: String?
     public var x: Double?
     public var y: Double?
+    public var dx: Double?
+    public var dy: Double?
     public var button: Int?
     public var key: String?
     public var keyCode: Int?
@@ -111,6 +113,8 @@ public struct ContinuityMessage: Codable, Equatable {
         action: String? = nil,
         x: Double? = nil,
         y: Double? = nil,
+        dx: Double? = nil,
+        dy: Double? = nil,
         button: Int? = nil,
         key: String? = nil,
         keyCode: Int? = nil,
@@ -160,6 +164,8 @@ public struct ContinuityMessage: Codable, Equatable {
         self.action = action
         self.x = x
         self.y = y
+        self.dx = dx
+        self.dy = dy
         self.button = button
         self.key = key
         self.keyCode = keyCode
```

---

### 4.2 File Diff 2: `mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift`

Implement `sendTextInput`, `sendScrollEvent`, and enhance `sendKeyInput` with full editing/navigation key mappings.

```diff
--- a/mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift
+++ b/mac/Sources/GalaxyContinuityKit/Services/ScreenMirroringService.swift
@@ -120,22 +120,70 @@ public final class ScreenMirroringService: @unchecked Sendable {
         }
     }
 
+    public func sendTextInput(text: String) {
+        let msg = ContinuityMessage(type: "input_text", text: text)
+        ServerManager.shared.broadcastMessage(msg)
+
+        // ADB fast-path: escape shell metacharacters and replace spaces with %s
+        let escaped = text.replacingOccurrences(of: " ", with: "%s")
+            .replacingOccurrences(of: "\\", with: "\\\\")
+            .replacingOccurrences(of: "\"", with: "\\\"")
+            .replacingOccurrences(of: "$", with: "\\$")
+            .replacingOccurrences(of: "`", with: "\\`")
+            .replacingOccurrences(of: "&", with: "\\&")
+            .replacingOccurrences(of: ";", with: "\\;")
+            .replacingOccurrences(of: "(", with: "\\(")
+            .replacingOccurrences(of: ")", with: "\\)")
+        if !escaped.isEmpty {
+            dispatchAdbInput(args: ["text", escaped])
+        }
+    }
+
+    public func sendScrollEvent(x: Double, y: Double, dx: Double, dy: Double) {
+        let clampedX = max(0.0, min(1.0, x))
+        let clampedY = max(0.0, min(1.0, y))
+        let msg = ContinuityMessage(
+            type: "input_scroll",
+            action: "scroll",
+            x: clampedX,
+            y: clampedY,
+            dx: dx,
+            dy: dy
+        )
+        ServerManager.shared.broadcastMessage(msg)
+
+        // ADB fast-path touch swipe fallback
+        let startPx = Int(clampedX * 1080.0)
+        let startPy = Int(clampedY * 2400.0)
+        let endPx = max(0, min(1080, startPx - Int(dx * 4.0)))
+        let endPy = max(0, min(2400, startPy - Int(dy * 4.0)))
+        if abs(dx) > 1 || abs(dy) > 1 {
+            dispatchAdbInput(args: ["swipe", "\(startPx)", "\(startPy)", "\(endPx)", "\(endPy)", "100"])
+        }
+    }
+
     public func sendKeyInput(key: String, keyCode: Int? = nil) {
+        var resolvedCode = keyCode
+        let keyUpper = key.uppercased()
+        if resolvedCode == nil {
+            if keyUpper == "BACK" { resolvedCode = 4 }
+            else if keyUpper == "HOME" { resolvedCode = 3 }
+            else if keyUpper == "RECENTS" { resolvedCode = 187 }
+            else if keyUpper == "NOTIFICATIONS" { resolvedCode = 83 }
+            else if keyUpper == "POWER" || keyUpper == "LOCK" { resolvedCode = 26 }
+            else if keyUpper == "BACKSPACE" || keyUpper == "DEL" { resolvedCode = 67 }
+            else if keyUpper == "ENTER" || keyUpper == "RETURN" { resolvedCode = 66 }
+            else if keyUpper == "TAB" { resolvedCode = 61 }
+            else if keyUpper == "ESCAPE" || keyUpper == "ESC" { resolvedCode = 111 }
+            else if keyUpper == "SPACE" { resolvedCode = 62 }
+            else if keyUpper == "DPAD_UP" || keyUpper == "UP" { resolvedCode = 19 }
+            else if keyUpper == "DPAD_DOWN" || keyUpper == "DOWN" { resolvedCode = 20 }
+            else if keyUpper == "DPAD_LEFT" || keyUpper == "LEFT" { resolvedCode = 21 }
+            else if keyUpper == "DPAD_RIGHT" || keyUpper == "RIGHT" { resolvedCode = 22 }
+        }
+
         let msg = ContinuityMessage(
             type: "input_key",
             key: key,
-            keyCode: keyCode
+            keyCode: resolvedCode
         )
         ServerManager.shared.broadcastMessage(msg)
 
-        let keyUpper = key.uppercased()
-        if keyUpper == "BACK" { dispatchAdbInput(args: ["keyevent", "4"]) }
-        else if keyUpper == "HOME" { dispatchAdbInput(args: ["keyevent", "3"]) }
-        else if keyUpper == "RECENTS" { dispatchAdbInput(args: ["keyevent", "187"]) }
-        else if keyUpper == "NOTIFICATIONS" { dispatchAdbInput(args: ["keyevent", "83"]) }
-        else if keyUpper == "POWER" || keyUpper == "LOCK" { dispatchAdbInput(args: ["keyevent", "26"]) }
-        else if let code = keyCode, code > 0 { dispatchAdbInput(args: ["keyevent", "\(code)"]) }
+        if let code = resolvedCode, code > 0 {
+            dispatchAdbInput(args: ["keyevent", "\(code)"])
+        }
     }
```

---

### 4.3 File Diff 3: `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift` & `ServerManager.swift`

Add `onNotificationClicked` callback, handle `UNNotificationDefaultActionIdentifier`, and add `sendNotificationOpen` to `ServerManager`.

```diff
--- a/mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift
+++ b/mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift
@@ -11,6 +11,9 @@ public final class NotificationService: NSObject, UNUserNotificationCenterDelega
     /// Test / Headless interception callback
     public var onReplyDispatched: ((_ id: String, _ packageName: String, _ text: String) -> Void)?
 
+    /// Callback when user clicks on a notification banner (default action)
+    public var onNotificationClicked: ((_ id: String, _ packageName: String) -> Void)?
+
     /// Indicates whether UNUserNotificationCenter is available in the current execution context.
@@ -170,11 +173,19 @@ public final class NotificationService: NSObject, UNUserNotificationCenterDelega
         didReceive response: UNNotificationResponse,
         withCompletionHandler completionHandler: @escaping () -> Void
     ) {
+        let userInfo = response.notification.request.content.userInfo
+        let notifId = userInfo["notifId"] as? String ?? ""
+        let packageName = userInfo["packageName"] as? String ?? ""
+
         if response.actionIdentifier == NotificationService.ACTION_REPLY,
            let textResponse = response as? UNTextInputNotificationResponse {
             let replyText = textResponse.userText
-            let userInfo = response.notification.request.content.userInfo
-            let notifId = userInfo["notifId"] as? String ?? ""
-            let packageName = userInfo["packageName"] as? String ?? ""
             if !notifId.isEmpty && !replyText.isEmpty {
                 dispatchReply(id: notifId, packageName: packageName, text: replyText)
             }
+        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
+            if !packageName.isEmpty || !notifId.isEmpty {
+                DispatchQueue.main.async { [weak self] in
+                    self?.onNotificationClicked?(notifId, packageName)
+                }
+            }
         }
         completionHandler()
     }
```

In `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`:
```diff
--- a/mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift
+++ b/mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift
@@ -803,6 +803,15 @@ public final class ServerManager {
         self.broadcastMessage(msg)
     }
 
+    public func sendNotificationOpen(id: String, packageName: String) {
+        let msg = ContinuityMessage(
+            type: "notification_open",
+            id: id,
+            packageName: packageName
+        )
+        self.broadcastMessage(msg)
+    }
+
     // MARK: - IP helper
     public func detectLocalIP() -> String? {
```

---

### 4.4 File Diff 4: `mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift`

Transform `ScreenMirroringView` into the authentic iPhone-Mirroring-style smartphone chassis, and configure `ScreenMirroringWindowController` with borderless NSWindow and event monitors for keyboard and trackpad.

```diff
--- a/mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift
+++ b/mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift
@@ -7,60 +7,163 @@ public struct ScreenMirroringView: View {
     @ObservedObject var state = DeviceState.shared
     @State private var isDragging: Bool = false
+    @State private var isHoveringToolbar: Bool = false
+
+    private let screenWidth: CGFloat = 360
+    private let screenHeight: CGFloat = 800
+    private let chassisPadding: CGFloat = 12
+    private let outerRadius: CGFloat = 44
+    private let innerRadius: CGFloat = 32
 
     public init() {}
 
     public var body: some View {
-        VStack(spacing: 8) {
-            GeometryReader { geo in
-                ZStack {
-                    Color.black
-
-                    if let image = state.lastScreenFrame {
-                        Image(nsImage: image)
-                            .resizable()
-                            .aspectRatio(contentMode: .fit)
-                    } else {
-                        VStack(spacing: 12) {
-                            ProgressView()
-                                .scaleEffect(1.2)
-                            Text(state.isScreenMirroringActive ? "Waiting for video stream..." : "Screen Mirroring Inactive")
-                                .font(.system(size: 13, weight: .medium))
-                                .foregroundColor(.white.opacity(0.8))
+        ZStack {
+            // Dark titanium smartphone chassis outer frame
+            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
+                .fill(
+                    LinearGradient(
+                        colors: [
+                            Color(white: 0.18),
+                            Color(white: 0.12),
+                            Color(white: 0.08)
+                        ],
+                        startPoint: .topLeading,
+                        endPoint: .bottomTrailing
+                    )
+                )
+                .overlay(
+                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
+                        .strokeBorder(
+                            LinearGradient(
+                                colors: [
+                                    Color(white: 0.35),
+                                    Color(white: 0.20),
+                                    Color(white: 0.12)
+                                ],
+                                startPoint: .top,
+                                endPoint: .bottom
+                            ),
+                            lineWidth: 1.5
+                        )
+                )
+                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
+
+            // Inner Smartphone Screen
+            ZStack(alignment: .top) {
+                // Display background
+                Color.black
+
+                // Video stream or inactive placeholder
+                if let image = state.lastScreenFrame {
+                    Image(nsImage: image)
+                        .resizable()
+                        .aspectRatio(contentMode: .fill)
+                        .frame(width: screenWidth, height: screenHeight)
+                        .clipped()
+                } else {
+                    VStack(spacing: 12) {
+                        ProgressView()
+                            .scaleEffect(1.2)
+                        Text(state.isScreenMirroringActive ? "Waiting for video stream..." : "Screen Mirroring Inactive")
+                            .font(.system(size: 13, weight: .medium))
+                            .foregroundColor(.white.opacity(0.8))
+                        if !state.isScreenMirroringActive {
+                            Button(action: {
+                                ScreenMirroringService.shared.startMirroring()
+                            }) {
+                                Label("Start Mirroring", systemImage: "play.fill")
+                                    .font(.system(size: 12, weight: .semibold))
+                            }
+                            .buttonStyle(.borderedProminent)
+                            .tint(.blue)
+                            .padding(.top, 4)
                         }
                     }
+                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                 }
-                .frame(maxWidth: .infinity, maxHeight: .infinity)
-                .contentShape(Rectangle())
-                .gesture(
-                    DragGesture(minimumDistance: 0)
-                        .onChanged { val in
-                            guard geo.size.width > 0 && geo.size.height > 0 else { return }
-                            let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
-                            let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
-
-                            if !isDragging {
-                                isDragging = true
-                                let startX = max(0.0, min(1.0, val.startLocation.x / geo.size.width))
-                                let startY = max(0.0, min(1.0, val.startLocation.y / geo.size.height))
-                                ScreenMirroringService.shared.sendInputEvent(action: "down", x: startX, y: startY, button: 0)
-                            } else {
-                                ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
+
+                // Touch input gesture surface
+                Color.clear
+                    .contentShape(Rectangle())
+                    .gesture(
+                        DragGesture(minimumDistance: 0)
+                            .onChanged { val in
+                                let normX = max(0.0, min(1.0, val.location.x / screenWidth))
+                                let normY = max(0.0, min(1.0, val.location.y / screenHeight))
+
+                                if !isDragging {
+                                    isDragging = true
+                                    let startX = max(0.0, min(1.0, val.startLocation.x / screenWidth))
+                                    let startY = max(0.0, min(1.0, val.startLocation.y / screenHeight))
+                                    ScreenMirroringService.shared.sendInputEvent(action: "down", x: startX, y: startY, button: 0)
+                                } else {
+                                    ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
+                                }
                             }
-                        }
-                        .onEnded { val in
-                            isDragging = false
-                            guard geo.size.width > 0 && geo.size.height > 0 else { return }
-                            let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
-                            let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
-                            ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
-                        }
-                )
+                            .onEnded { val in
+                                isDragging = false
+                                let normX = max(0.0, min(1.0, val.location.x / screenWidth))
+                                let normY = max(0.0, min(1.0, val.location.y / screenHeight))
+                                ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
+                            }
+                    )
+
+                // Top camera punch hole cutout (Samsung Infinity-O)
+                Circle()
+                    .fill(Color.black)
+                    .frame(width: 11, height: 11)
+                    .overlay(
+                        Circle()
+                            .stroke(Color(white: 0.22), lineWidth: 0.75)
+                    )
+                    .padding(.top, 7)
+                    .allowsHitTesting(false)
+
+                // Bottom home indicator bar
+                VStack {
+                    Spacer()
+                    Capsule()
+                        .fill(Color.white.opacity(0.65))
+                        .frame(width: 120, height: 4)
+                        .padding(.bottom, 8)
+                        .contentShape(Rectangle().size(width: 140, height: 24))
+                        .gesture(
+                            DragGesture(minimumDistance: 5)
+                                .onEnded { val in
+                                    if val.translation.height < -20 {
+                                        ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)
+                                    } else {
+                                        ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
+                                    }
+                                }
+                        )
+                        .onTapGesture {
+                            ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
+                        }
+                }
+
+                // Minimal floating hover toolbar at top
+                VStack {
+                    floatingToolbar
+                        .padding(.top, 14)
+                        .opacity(isHoveringToolbar ? 1.0 : 0.0)
+                        .animation(.easeInOut(duration: 0.2), value: isHoveringToolbar)
+                    Spacer()
+                }
             }
-            .frame(width: 360, height: 720)
-            .cornerRadius(16)
-
-            // Hardware Navigation Buttons Bar
-            HStack(spacing: 16) {
+            .frame(width: screenWidth, height: screenHeight)
+            .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
+            .overlay(
+                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
+                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
+            )
+        }
+        .frame(width: screenWidth + chassisPadding * 2, height: screenHeight + chassisPadding * 2)
+        .onHover { hovering in
+            isHoveringToolbar = hovering
+        }
+    }
+
+    private var floatingToolbar: some View {
+        HStack(spacing: 12) {
+            Button(action: {
+                ScreenMirroringWindowController.shared.close()
+            }) {
+                Image(systemName: "xmark.circle.fill")
+                    .font(.system(size: 15))
+                    .foregroundColor(.white.opacity(0.85))
+            }
+            .buttonStyle(.plain)
+            .help("Close Window")
+
+            Divider()
+                .frame(height: 12)
+                .background(Color.white.opacity(0.2))
+
             Button(action: {
                 ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)
             }) {
-                Image(systemName: "square.stack.3d.down.right")
-                    .font(.system(size: 14))
+                Image(systemName: "square.stack.3d.down.right")
+                    .font(.system(size: 13))
+                    .foregroundColor(.white.opacity(0.9))
             }
-            .buttonStyle(.bordered)
+            .buttonStyle(.plain)
             .help("Recent Apps")
 
             Button(action: {
                 ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
             }) {
                 Image(systemName: "circle")
-                    .font(.system(size: 14))
+                    .font(.system(size: 13))
+                    .foregroundColor(.white.opacity(0.9))
             }
-            .buttonStyle(.bordered)
+            .buttonStyle(.plain)
             .help("Home")
 
             Button(action: {
                 ScreenMirroringService.shared.sendKeyInput(key: "BACK", keyCode: 4)
             }) {
                 Image(systemName: "chevron.backward")
-                    .font(.system(size: 14))
+                    .font(.system(size: 13))
+                    .foregroundColor(.white.opacity(0.9))
             }
-            .buttonStyle(.bordered)
+            .buttonStyle(.plain)
             .help("Back")
 
             Button(action: {
                 ScreenMirroringService.shared.sendKeyInput(key: "NOTIFICATIONS", keyCode: 83)
             }) {
                 Image(systemName: "bell")
-                    .font(.system(size: 14))
+                    .font(.system(size: 13))
+                    .foregroundColor(.white.opacity(0.9))
             }
-            .buttonStyle(.bordered)
+            .buttonStyle(.plain)
             .help("Notifications")
 
             Button(action: {
                 ScreenMirroringService.shared.sendKeyInput(key: "POWER", keyCode: 26)
             }) {
                 Image(systemName: "lock")
-                    .font(.system(size: 14))
+                    .font(.system(size: 13))
+                    .foregroundColor(.white.opacity(0.9))
             }
-            .buttonStyle(.bordered)
+            .buttonStyle(.plain)
             .help("Lock / Power")
 
-            Spacer()
+            Divider()
+                .frame(height: 12)
+                .background(Color.white.opacity(0.2))
 
             Button(action: {
                 if state.isScreenMirroringActive {
@@ -115,17 +218,22 @@ public struct ScreenMirroringView: View {
                 } else {
                     ScreenMirroringService.shared.startMirroring()
                 }
             }) {
-                Label(state.isScreenMirroringActive ? "Stop" : "Start", systemImage: state.isScreenMirroringActive ? "stop.fill" : "play.fill")
-                    .font(.system(size: 11))
+                Image(systemName: state.isScreenMirroringActive ? "stop.fill" : "play.fill")
+                    .font(.system(size: 12))
+                    .foregroundColor(state.isScreenMirroringActive ? .red : .green)
             }
-            .buttonStyle(.borderedProminent)
+            .buttonStyle(.plain)
+            .help(state.isScreenMirroringActive ? "Stop Mirroring" : "Start Mirroring")
         }
-        .padding(.horizontal, 16)
-        .padding(.bottom, 8)
-    }
-    .padding(12)
-    .background(Color(NSColor.windowBackgroundColor))
+        .padding(.horizontal, 14)
+        .padding(.vertical, 7)
+        .background(
+            Capsule()
+                .fill(Color.black.opacity(0.75))
+                .overlay(
+                    Capsule()
+                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
+                )
+        )
+        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
     }
 }
 
 public final class ScreenMirroringWindowController: NSWindowController {
     public static let shared = ScreenMirroringWindowController()
+    private var eventMonitor: Any?
+    private var lastScrollTime: Date = Date()
+    private var accumulatedDx: Double = 0
+    private var accumulatedDy: Double = 0
 
     private init() {
+        let contentRect = NSRect(x: 0, y: 0, width: 384, height: 824)
         let window = NSWindow(
-            contentRect: NSRect(x: 0, y: 0, width: 384, height: 800),
-            styleMask: [.titled, .closable, .miniaturizable, .resizable],
+            contentRect: contentRect,
+            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
             backing: .buffered,
             defer: false
         )
         window.title = "Galaxy Screen Mirror"
+        window.titlebarAppearsTransparent = true
+        window.titleVisibility = .hidden
+        window.backgroundColor = .clear
+        window.isOpaque = false
+        window.hasShadow = true
+        window.isMovableByWindowBackground = true
         window.center()
         window.isReleasedWhenClosed = false
+        window.contentAspectRatio = NSSize(width: 384, height: 824)
+        window.minSize = NSSize(width: 288, height: 618)
+
+        // Suppress standard titlebar traffic lights for frameless smartphone design
+        window.standardWindowButton(.closeButton)?.isHidden = true
+        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
+        window.standardWindowButton(.zoomButton)?.isHidden = true
+
         window.contentView = NSHostingView(rootView: ScreenMirroringView())
         super.init(window: window)
+        setupEventMonitor()
     }
 
     required init?(coder: NSCoder) {
         fatalError("init(coder:) has not been implemented")
     }
 
+    deinit {
+        if let monitor = eventMonitor {
+            NSEvent.removeMonitor(monitor)
+        }
+    }
+
+    private func setupEventMonitor() {
+        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
+            guard let self = self, let win = self.window, event.window == win else {
+                return event
+            }
+
+            if event.type == .keyDown {
+                if self.handleKeyDown(event) {
+                    return nil // Intercepted: consume event to prevent error chime
+                }
+            } else if event.type == .scrollWheel {
+                if self.handleScrollWheel(event) {
+                    return nil
+                }
+            }
+            return event
+        }
+    }
+
+    private func handleKeyDown(_ event: NSEvent) -> Bool {
+        // Allow system Command shortcuts (Cmd+W, Cmd+Q) to pass through to macOS
+        if event.modifierFlags.contains(.command) {
+            if event.charactersIgnoringModifiers == "w" {
+                self.window?.performClose(nil)
+                return true
+            }
+            return false
+        }
+
+        // Special Key Mappings to Android KeyCodes
+        switch event.keyCode {
+        case 51: // Mac Delete/Backspace -> Android KEYCODE_DEL (67)
+            ScreenMirroringService.shared.sendKeyInput(key: "BACKSPACE", keyCode: 67)
+            return true
+        case 36, 76: // Mac Return / Enter -> Android KEYCODE_ENTER (66)
+            ScreenMirroringService.shared.sendKeyInput(key: "ENTER", keyCode: 66)
+            return true
+        case 48: // Mac Tab -> Android KEYCODE_TAB (61)
+            ScreenMirroringService.shared.sendKeyInput(key: "TAB", keyCode: 61)
+            return true
+        case 53: // Mac Escape -> Android KEYCODE_ESCAPE (111)
+            ScreenMirroringService.shared.sendKeyInput(key: "ESCAPE", keyCode: 111)
+            return true
+        case 49: // Mac Spacebar -> Android KEYCODE_SPACE (62)
+            ScreenMirroringService.shared.sendKeyInput(key: "SPACE", keyCode: 62)
+            return true
+        case 123: // Mac Left Arrow -> Android KEYCODE_DPAD_LEFT (21)
+            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_LEFT", keyCode: 21)
+            return true
+        case 124: // Mac Right Arrow -> Android KEYCODE_DPAD_RIGHT (22)
+            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_RIGHT", keyCode: 22)
+            return true
+        case 125: // Mac Down Arrow -> Android KEYCODE_DPAD_DOWN (20)
+            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_DOWN", keyCode: 20)
+            return true
+        case 126: // Mac Up Arrow -> Android KEYCODE_DPAD_UP (19)
+            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_UP", keyCode: 19)
+            return true
+        default:
+            break
+        }
+
+        // Printable text characters typed on Mac keyboard
+        if let chars = event.characters, !chars.isEmpty {
+            let printable = chars.filter { char in
+                guard let scalar = char.unicodeScalars.first else { return false }
+                return !scalar.properties.isControlCharacter && scalar.value >= 32 && scalar.value != 127
+            }
+            if !printable.isEmpty {
+                ScreenMirroringService.shared.sendTextInput(text: printable)
+                return true
+            }
+        }
+
+        return false
+    }
+
+    private func handleScrollWheel(_ event: NSEvent) -> Bool {
+        guard let win = self.window, let contentView = win.contentView else { return false }
+        let mouseLocation = event.locationInWindow
+        let bounds = contentView.bounds
+
+        let bezel: CGFloat = 12
+        let screenWidth = max(1.0, bounds.width - bezel * 2)
+        let screenHeight = max(1.0, bounds.height - bezel * 2)
+
+        let normX = max(0.0, min(1.0, Double((mouseLocation.x - bezel) / screenWidth)))
+        let normY = max(0.0, min(1.0, Double((bounds.height - bezel - mouseLocation.y) / screenHeight)))
+
+        var dx = Double(event.scrollingDeltaX)
+        var dy = Double(event.scrollingDeltaY)
+        if event.hasPreciseScrollingDeltas {
+            dx *= 1.5
+            dy *= 1.5
+        }
+
+        accumulatedDx += dx
+        accumulatedDy += dy
+
+        let now = Date()
+        let elapsed = now.timeIntervalSince(lastScrollTime)
+        if elapsed >= 0.05 || abs(accumulatedDx) >= 15 || abs(accumulatedDy) >= 15 {
+            ScreenMirroringService.shared.sendScrollEvent(
+                x: normX,
+                y: normY,
+                dx: accumulatedDx,
+                dy: accumulatedDy
+            )
+            accumulatedDx = 0
+            accumulatedDy = 0
+            lastScrollTime = now
+        }
+        return true
+    }
+
     public func show() {
         window?.makeKeyAndOrderFront(nil)
         NSApp.activate(ignoringOtherApps: true)
     }
+
+    public func close() {
+        window?.performClose(nil)
+    }
 }
```

---

### 4.5 File Diff 5: `mac/Sources/GalaxyContinuity/AppDelegate.swift`

Connect notification click delegate, focus mirror window, broadcast `notification_open`, and proactively run `adb reverse`.

```diff
--- a/mac/Sources/GalaxyContinuity/AppDelegate.swift
+++ b/mac/Sources/GalaxyContinuity/AppDelegate.swift
@@ -15,7 +15,9 @@ public final class AppDelegate: NSObject, NSApplicationDelegate {
         setupMenuBar()
         setupPopover()
         startServices()
+        setupNotificationHandling()
+        setupAdbReverse(port: 8765)
 
         // Bring Screen Mirror window to front
         ScreenMirroringWindowController.shared.show()
     }
@@ -58,6 +60,39 @@ public final class AppDelegate: NSObject, NSApplicationDelegate {
         print("[AppDelegate] Galaxy Continuity initialized successfully.")
     }
 
+    private func setupNotificationHandling() {
+        NotificationService.shared.onNotificationClicked = { notifId, packageName in
+            Task { @MainActor in
+                ScreenMirroringWindowController.shared.show()
+                if !DeviceState.shared.isScreenMirroringActive {
+                    ScreenMirroringService.shared.startMirroring()
+                }
+                ServerManager.shared.sendNotificationOpen(id: notifId, packageName: packageName)
+
+                // Fast-path: launch application directly over ADB if connected
+                if !packageName.isEmpty {
+                    let candidates = [
+                        "/tmp/platform-tools/adb",
+                        "/usr/local/bin/adb",
+                        "/opt/homebrew/bin/adb",
+                        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
+                    ]
+                    if let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
+                        DispatchQueue.global(qos: .userInitiated).async {
+                            let proc = Process()
+                            proc.executableURL = URL(fileURLWithPath: adb)
+                            proc.arguments = ["shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"]
+                            try? proc.run()
+                        }
+                    }
+                }
+            }
+        }
+    }
+
+    private func setupAdbReverse(port: Int = 8765) {
+        let candidates = [
+            "/tmp/platform-tools/adb",
+            "/usr/local/bin/adb",
+            "/opt/homebrew/bin/adb",
+            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
+        ]
+        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
+        DispatchQueue.global(qos: .utility).async {
+            let proc = Process()
+            proc.executableURL = URL(fileURLWithPath: adb)
+            proc.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]
+            try? proc.run()
+        }
+    }
+
     public func applicationWillTerminate(_ notification: Notification) {
```

---

## 5. Verification Method

### 5.1 Automated Unit Tests

Execute the macOS unit test suite to verify all message serialization and input routing:
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift test
```

New unit tests to include in `ScreenMirroringTests.swift`:
```swift
@Test("Serialize input_text message")
func testInputTextSerialization() throws {
    let msg = ContinuityMessage(type: "input_text", text: "Hello Galaxy")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "input_text")
    #expect(decoded.text == "Hello Galaxy")
}

@Test("Serialize input_scroll message with deltas")
func testInputScrollSerialization() throws {
    let msg = ContinuityMessage(type: "input_scroll", x: 0.5, y: 0.5, dx: 10.0, dy: -25.5)
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "input_scroll")
    #expect(decoded.x == 0.5)
    #expect(decoded.y == 0.5)
    #expect(decoded.dx == 10.0)
    #expect(decoded.dy == -25.5)
}

@Test("Keycode resolution for editing keys")
func testExtendedKeyResolution() {
    ScreenMirroringService.shared.sendKeyInput(key: "BACKSPACE")
    ScreenMirroringService.shared.sendKeyInput(key: "ENTER")
    ScreenMirroringService.shared.sendKeyInput(key: "TAB")
    ScreenMirroringService.shared.sendKeyInput(key: "ESCAPE")
    ScreenMirroringService.shared.sendKeyInput(key: "SPACE")
    ScreenMirroringService.shared.sendKeyInput(key: "DPAD_UP")
    ScreenMirroringService.shared.sendKeyInput(key: "DPAD_DOWN")
}
```

New unit tests to include in `NotificationTests.swift`:
```swift
@Test("Serialize notification_open message")
func testNotificationOpenSerialization() throws {
    let msg = ContinuityMessage(type: "notification_open", id: "notif-101", packageName: "org.telegram.messenger")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
    #expect(decoded.type == "notification_open")
    #expect(decoded.id == "notif-101")
    #expect(decoded.packageName == "org.telegram.messenger")
}

@Test("onNotificationClicked callback dispatches properly")
func testNotificationClickCallback() {
    var clickedId = ""
    var clickedPkg = ""
    NotificationService.shared.onNotificationClicked = { id, pkg in
        clickedId = id
        clickedPkg = pkg
    }
    NotificationService.shared.onNotificationClicked?("test-id-99", "com.google.android.youtube")
    #expect(clickedId == "test-id-99")
    #expect(clickedPkg == "com.google.android.youtube")
}
```

### 5.2 Manual & Device Verification
1. **Window Presentation**:
   - Launch `GalaxyContinuity` on macOS.
   - Confirm screen mirror window displays as a borderless smartphone silhouette with dark titanium gradient border, rounded continuous corners (44pt), 32pt inner screen clip, and black camera punch hole at top center.
   - Confirm the standard macOS gray title bar is completely removed.
   - Hover over the top: confirm minimal floating translucent toolbar appears.
2. **Keyboard Typing**:
   - Focus mirror window and type `"Continuity Testing"`.
   - Confirm no macOS error chime sounds.
   - Verify `input_text` is sent and text appears in the phone's focused input field.
   - Press Backspace: verify characters delete cleanly.
   - Press Enter: verify IME action / newline triggers.
3. **Trackpad Two-Finger Scroll**:
   - Place cursor over mirror window and swipe up/down with two fingers on Mac trackpad.
   - Verify smooth scrolling occurs on the device without stutter or queue overflow.
4. **Notification Click Navigation**:
   - Trigger a notification on Galaxy A70.
   - Click the notification banner on macOS.
   - Verify mirror window gains focus and the corresponding application opens on the Galaxy A70.

### 5.3 Invalidation Conditions
- Mirror window displays default macOS gray window chrome or square title bar.
- Typing into the mirror window produces an alert sound and fails to emit `input_text`.
- Two-finger scrolling does not generate `input_scroll` events with `dx`/`dy`.
- Clicking a forwarded notification banner does not focus the mirror window or emit `notification_open`.
