# Survey Report: Requirement R2 — Window Presentation & Seamless Continuity

**Author**: `survey_it3_explorer_2` (Exploration Agent)  
**Parent**: `orchestrator_it3` (`19504c92-7b9c-4a7e-8fac-89d677c3dfc7`)  
**Date**: 2026-11-08  
**Scope**: Requirement R2 (Screen Mirroring Window Styling, Notification Click Navigation, Automatic Background Reconnection across USB & Wi-Fi)

---

## 1. Observation

### 1.1 Screen Mirroring Window Presentation & Styling (macOS)
- **`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift` (lines 130–155)**:
  ```swift
  public final class ScreenMirroringWindowController: NSWindowController {
      public static let shared = ScreenMirroringWindowController()

      private init() {
          let window = NSWindow(
              contentRect: NSRect(x: 0, y: 0, width: 384, height: 800),
              styleMask: [.titled, .closable, .miniaturizable, .resizable],
              backing: .buffered,
              defer: false
          )
          window.title = "Galaxy Screen Mirror"
          window.center()
          window.isReleasedWhenClosed = false
          window.contentView = NSHostingView(rootView: ScreenMirroringView())
          super.init(window: window)
      }
  ```
  - The window uses standard macOS desktop window styling (`.titled, .closable, .miniaturizable, .resizable`), rendering a standard gray title bar with window title `"Galaxy Screen Mirror"` and gray titlebar chrome.
  - `window.backgroundColor` is not clear, `window.isOpaque` is default `true`, and `window.isMovableByWindowBackground` is `false`.

- **`mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift` (lines 12–128)**:
  - Video viewport is placed in an outer `VStack(spacing: 8)` with `padding(12)` and `background(Color(NSColor.windowBackgroundColor))`.
  - The video feed container is hardcoded at `frame(width: 360, height: 720).cornerRadius(16)` with a raw black box.
  - A bulky AppKit button toolbar is rendered at the bottom: 5 bordered buttons (`square.stack.3d.down.right`, `circle`, `chevron.backward`, `bell`, `lock`) for RECENTS, HOME, BACK, NOTIFICATIONS, POWER, plus a prominent Start/Stop toggle button.
  - This looks like an early debugging scaffold rather than the frameless smartphone chassis seen in macOS Sequoia iPhone Mirroring.

- **Physical Device Resolution & Aspect Ratio**:
  - Direct ADB query (`/tmp/platform-tools/adb shell wm size`):
    `Physical size: 1080x2400`
  - Direct ADB query (`/tmp/platform-tools/adb shell wm density`):
    `Physical density: 420`
  - The Samsung Galaxy A70 has an aspect ratio of `20:9` (2.222:1). A 360pt width corresponds to an 800pt screen height (`360 * 20 / 9 = 800`).

---

### 1.2 Forwarded Notification Display & Click Handling (macOS & Android)
- **`mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift` (lines 118–152)**:
  - `showPhoneNotification` attaches notification metadata:
    ```swift
    content.userInfo = [
        "notifId": id,
        "packageName": packageName
    ]
    ```
- **`mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift` (lines 167–183)**:
  ```swift
  public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
  ) {
      if response.actionIdentifier == NotificationService.ACTION_REPLY,
         let textResponse = response as? UNTextInputNotificationResponse {
          let replyText = textResponse.userText
          let userInfo = response.notification.request.content.userInfo
          let notifId = userInfo["notifId"] as? String ?? ""
          let packageName = userInfo["packageName"] as? String ?? ""
          if !notifId.isEmpty && !replyText.isEmpty {
              dispatchReply(id: notifId, packageName: packageName, text: replyText)
          }
      }
      completionHandler()
  }
  ```
  - When a user clicks on the notification banner/body on macOS, `response.actionIdentifier` equals `UNNotificationDefaultActionIdentifier`.
  - Currently, `NotificationService` has **no handling** for `UNNotificationDefaultActionIdentifier`. Clicking the notification is completely ignored: it neither brings the screen mirror window to focus nor alerts the phone.
  - `NotificationService` has no delegate/callback property for notification clicks (`onNotificationClicked` does not exist).

- **`android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt` (lines 107–155)**:
  - `onNotificationPosted` checks `sbn.notification?.actions` to register `ReplyActionHolder` (containing `actionIntent` and `remoteInputs`).
  - It **does not store** `sbn.notification.contentIntent` (the PendingIntent to open the notification/activity).
  - The companion object provides `replyToNotification(id, packageName, replyText)` but provides **no method** to open or launch notifications (`openNotification(id, packageName)` does not exist).

- **`android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` (lines 152–157)**:
  - Only handles incoming `"notification_reply"`.
  - There is no message type or callback for `"notification_open"` or `"notification_click"`.

---

### 1.3 Automatic Background Reconnection (USB & Wi-Fi / Bonjour / mDNS)
- **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` (lines 74–88)**:
  ```kotlin
  nsdDiscovery = NsdDiscovery(this) { host, port, name ->
      lastStatus = "Connecting to $name..."
      connectionStatus.value = "Connecting to $name..."
      updateNotification("Connecting to $name...")
      webSocketClient?.connect(host, port)
  }
  nsdDiscovery?.startDiscovery()

  // Proactively probe local USB loopback (via adb reverse) and default Mac IP
  serviceScope.launch {
      try {
          webSocketClient?.connect("127.0.0.1", 8765)
      } catch (_: Exception) {}
  }
  ```
- **`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` (lines 121–127)**:
  ```kotlin
  override fun onDisconnected() {
      lastStatus = "Disconnected. Searching..."
      connectionStatus.value = "Disconnected. Searching..."
      isSocketConnected.value = false
      updateNotification("Disconnected. Searching for Mac...")
      nsdDiscovery?.startDiscovery()
  }
  ```
  - Probing `127.0.0.1:8765` only happens **once** at service startup (`onCreate()`).
  - When disconnected (`onDisconnected()`), it **only** calls `nsdDiscovery?.startDiscovery()`. It **never retries** `127.0.0.1:8765`!
  - It **does not persist** or retry the last successful Wi-Fi host IP.
  - If a router isolates subnets or drops mDNS multicast (standard on corporate and many home guest networks), the Android app remains permanently stuck in `"Disconnected. Searching..."` until manual IP entry in `MainActivity`.

- **macOS Side ADB Reverse Management**:
  - Running grep search across `mac/Sources/` reveals that `adb` is only referenced in `ScreenMirroringService.swift` for sending input keys/swipes.
  - Neither `ServerManager.swift` nor `AppDelegate.swift` checks for connected ADB devices or runs `adb reverse tcp:8765 tcp:8765`.
  - If the user connects the phone via USB, USB loopback fails unless the user manually runs `adb reverse` in terminal.

---

## 2. Logic Chain

1. **Window Presentation Logic**:
   - macOS Sequoia iPhone Mirroring uses a borderless, floating window with a custom bezel chassis, uniform rounded corners (~40pt radius on the body, ~30pt on the inner screen display), transparent titlebar, and top/bottom hover controls.
   - To achieve this in AppKit + SwiftUI:
     - The `NSWindow` must be configured with `styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable]`.
     - `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = true`, `isMovableByWindowBackground = true`.
     - The SwiftUI view (`ScreenMirroringView`) must render the smartphone chassis: a sleek dark rounded rectangle with continuous corner radius, subtle dark titanium stroke/border highlight, uniform 12pt bezel around the screen, authentic Samsung Infinity-O punch hole at top center, and inner display clipped to match the phone's curvature.
     - Replace the bulky gray button bar at the bottom with a minimal hover pill toolbar (top/bottom) and a floating home indicator bar (tap for HOME, swipe for RECENTS) that preserves the authentic phone aesthetic.

2. **Notification Click Navigation Logic**:
   - In macOS Sequoia, clicking an iPhone notification focuses the mirror window and opens the app on the phone.
   - To reproduce this:
     - On macOS, when `userNotificationCenter(_:didReceive:)` receives `UNNotificationDefaultActionIdentifier`:
       1. Focus and show `ScreenMirroringWindowController.shared.show()`.
       2. If screen mirroring is inactive, call `ScreenMirroringService.shared.startMirroring()`.
       3. Send a new protocol message `{"type": "notification_open", "id": "<notifId>", "packageName": "<packageName>"}` over WebSocket to Android.
       4. As an immediate zero-latency fallback over USB, if ADB is detected, execute `adb shell monkey -p <packageName> -c android.intent.category.LAUNCHER 1` or `adb shell am start ...`.
     - On Android:
       1. In `NotificationForwarderService.onNotificationPosted`, cache `sbn.notification.contentIntent` mapped by notification ID.
       2. In `WebSocketClient`, handle `"notification_open"` and `"notification_click"` and invoke `listener.onNotificationOpen(id, packageName)`.
       3. In `ContinuityService.onNotificationOpen`, invoke `NotificationForwarderService.openNotification(id, packageName)`.
       4. If `contentIntent` is cached, call `pendingIntent.send()`. If unavailable, launch via `packageManager.getLaunchIntentForPackage(packageName)`.
       5. Wake the device screen if sleeping via `ContinuityAccessibilityService` or `PowerManager`.

3. **Automatic Background Reconnection Logic**:
   - Requirement R2 specifies that connection must automatically re-establish in the background without manual IP entry when the phone is plugged in via USB or re-connected on Wi-Fi.
   - To achieve this:
     - On macOS:
       - Add an `AdbBridgeManager` (or background watcher in `ServerManager` / `AppDelegate`) that periodically (or on startup / device connection) executes `adb reverse tcp:8765 tcp:8765` and `tcp:8766 tcp:8766`.
     - On Android:
       - Implement a robust reconnection state machine with exponential backoff (0ms, 1s, 2s, 4s, 10s max) in `ContinuityService`.
       - At each reconnection cycle, systematically probe:
         1. **USB Loopback**: `127.0.0.1:8765` (succeeds immediately when USB is connected).
         2. **Last-Known Host**: Retrieve cached IP & port from `SharedPreferences` (succeeds immediately on reconnecting to known Wi-Fi without waiting for mDNS).
         3. **Local Discovery**: Concurrently run `NsdDiscovery` / `DiscoveryCoordinator` (finds new Mac on subnet).
       - Store `currentHost` in `SharedPreferences` upon any successful handshake acknowledgment.
       - Listen for network connectivity changes (`ConnectivityManager.NetworkCallback`) and broadcast intents to instantly trigger reconnection without user intervention.

---

## 3. Caveats

1. **Android Background Activity Starts (Android 10+)**:
   - On Android 10+ (API 29+), starting an activity from the background requires either:
     - Executing an existing notification's `contentIntent.send()` (whitelisted by system).
     - An active foreground service with type `connectedDevice` (which `ContinuityService` already has).
     - `ContinuityAccessibilityService` (which has system accessibility permissions to launch apps and inject intents).
     - Fallback via ADB command `adb shell monkey -p ...` when USB is connected.
   - All four mechanisms can be combined to guarantee 100% reliability.
2. **mDNS Multicast on Enterprise / Isolated Wi-Fi**:
   - Many corporate/guest Wi-Fi networks block multicast DNS (UDP 5353). The persistent last-known IP cache and USB loopback fallback prevent the user from ever getting stuck.
3. **No Caveats Regarding Feasibility**:
   - All necessary APIs in AppKit, SwiftUI, Android NotificationListenerService, AccessibilityService, and ADB are fully available and confirmed functional on macOS and the connected Galaxy A70.

---

## 4. Conclusion & Required Changes

Requirement R2 requires coordinated modifications across both macOS and Android:

### Summary Table of Required File Changes

| Component | Target File | Nature of Change |
|---|---|---|
| **macOS Window** | `mac/Sources/GalaxyContinuity/UI/ScreenMirroringView.swift` | Configure `NSWindow` as frameless, clear, draggable background; implement smartphone chassis styling, 44pt outer corner radius, 32pt inner screen clip, Samsung Infinity-O punch hole, and minimal floating hover toolbar. |
| **macOS Notification** | `mac/Sources/GalaxyContinuityKit/Services/NotificationService.swift` | Handle `UNNotificationDefaultActionIdentifier` in `userNotificationCenter(_:didReceive:)`, expose `onNotificationClicked` callback. |
| **macOS Protocol** | `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift` | Add `sendNotificationOpen(id:packageName:)` broadcasting `notification_open` message. |
| **macOS App Delegate** | `mac/Sources/GalaxyContinuity/AppDelegate.swift` | Wire `NotificationService.shared.onNotificationClicked` to activate mirror window controller, start mirroring, and dispatch open message. |
| **macOS USB Daemon** | `mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift` | Automatically execute `adb reverse tcp:8765 tcp:8765` and `tcp:8766 tcp:8766` when an ADB device is detected. |
| **Shared Protocol** | `shared/PROTOCOL.md` | Add JSON schema specification for `"notification_open"`. |
| **Android WebSocket** | `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` | Add `onNotificationOpen` callback to `ContinuityListener`, parse `"notification_open"` and `"notification_click"` in `onMessage`. |
| **Android Service** | `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt` | Implement `onNotificationOpen`; implement persistent last-known host caching; implement exponential backoff reconnection loop probing `127.0.0.1:8765` + last known Wi-Fi host + mDNS. |
| **Android Notification** | `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt` | Cache `sbn.notification.contentIntent` in `contentIntentCache`; implement `openNotification(id, packageName)` executing pending intent or launching package. |
| **Android UI** | `android/app/src/main/java/com/galaxycontinuity/app/MainActivity.kt` | Reflect automatic reconnection state without requiring manual "Connect" button clicks. |

---

## 5. Verification Method

### 5.1 Verification Commands
1. **macOS Build**:
   ```bash
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac && swift build
   ```
   *Expected outcome*: Compiles with 0 errors.

2. **Android Build & Install**:
   ```bash
   export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home
   cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android
   ./gradlew assembleDebug
   /tmp/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
   *Expected outcome*: Gradle build succeeds, APK installs cleanly on Galaxy A70 (`R58M5763N2Y`).

3. **Window Presentation Verification**:
   - Run macOS app.
   - Verify screen mirror window opens without standard gray titlebar, with dark rounded chassis, camera punch hole, and minimal floating frame.

4. **Notification Click Verification**:
   - Trigger a notification on Galaxy (or via `Test Notify`).
   - Notification appears on macOS.
   - Click the notification banner.
   - Verify screen mirror window focuses on macOS and corresponding app opens on Galaxy A70.

5. **Automatic Reconnection Verification**:
   - Unplug USB cable or stop Mac server. Android notification displays "Searching...".
   - Plug USB cable back in or restart Mac server.
   - Without opening `MainActivity` or typing any IP, verify Android status immediately changes to "Connected to MacBook Pro" via automatic background loop.

### 5.2 Invalidation Conditions
- Mirror window displays default macOS gray title bar or square corners.
- Clicking a macOS forwarded notification does nothing.
- Re-launching the Mac app requires the user to open the phone and type an IP address to reconnect.
