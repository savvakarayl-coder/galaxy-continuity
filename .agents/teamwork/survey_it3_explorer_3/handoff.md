# Survey Report: Requirement R3 — Build Environment, Device Deployment & Lean Verification Workflow

**Author**: `survey_it3_explorer_3` (Exploration Agent)  
**Parent**: `orchestrator_it3` (`19504c92-7b9c-4a7e-8fac-89d677c3dfc7`)  
**Date**: 2026-11-08  
**Scope**: Build environments (macOS Swift & Android Gradle), physical Samsung Galaxy A70 deployment over ADB reverse, and lean end-to-end verification strategy for Iteration 3.

---

## 1. Observation

### 1.1 Physical Device Status & Hardware Details
Direct execution of `/tmp/platform-tools/adb devices -l` and device property checks yielded:

```
$ /tmp/platform-tools/adb devices -l
List of devices attached
R58M5763N2Y            device usb:1048576X product:a70qser model:SM_A705FN device:a70q transport_id:1

$ /tmp/platform-tools/adb shell getprop ro.build.version.release
11

$ /tmp/platform-tools/adb shell getprop ro.build.version.sdk
30

$ /tmp/platform-tools/adb shell wm size
Physical size: 1080x2400

$ /tmp/platform-tools/adb shell wm density
Physical density: 420

$ /tmp/platform-tools/adb shell dumpsys power | grep -E 'mWakefulness|Display Power'
Display Power: state=ON
```

- **Device identification**: Physical Samsung Galaxy A70 (`SM-A705FN`), serial `R58M5763N2Y`, connected via USB Type-C (`usb:1048576X`).
- **Android OS**: Android 11 (API 30).
- **Display properties**: 1080x2400 pixels (aspect ratio `20:9`), 420 dpi, display power state is `ON`.
- **System permissions & services state on device**:
  - `pm list packages | grep galaxycontinuity`: `package:com.galaxycontinuity.app` is installed.
  - `settings get secure enabled_accessibility_services`: `com.galaxycontinuity.app/com.galaxycontinuity.app.service.ContinuityAccessibilityService` is enabled.
  - `settings get secure enabled_notification_listeners`: `...:com.galaxycontinuity.app/com.galaxycontinuity.app.service.NotificationForwarderService:...` is enabled.
  - `dumpsys activity services com.galaxycontinuity.app`:
    - `ContinuityService` is active as a foreground service (ID 1001).
    - `ContinuityAccessibilityService` is bound by `system` (flags `0x2101001`, `FGSA CAPS`).
    - `NotificationForwarderService` is bound by `system` (`BIND_NOTIFICATION_LISTENER_SERVICE`).

---

### 1.2 ADB Reverse Port Mapping
Testing `/tmp/platform-tools/adb reverse` commands:

```
$ /tmp/platform-tools/adb reverse --list
UsbFfs tcp:8765 tcp:8765
UsbFfs tcp:8766 tcp:8766

$ /tmp/platform-tools/adb reverse tcp:8765 tcp:8765 && /tmp/platform-tools/adb reverse tcp:8766 tcp:8766
(Exit code 0)

$ /tmp/platform-tools/adb shell curl -s http://127.0.0.1:8765/ | head -n 5
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
```

- ADB reverse port mapping forwards both port 8765 (primary WebSocket/HTTP server) and port 8766 (secondary/media) across USB.
- The phone can immediately connect to `http://127.0.0.1:8765` and `ws://127.0.0.1:8765/ws` to communicate directly with the macOS host application over USB with zero configuration and zero Wi-Fi dependencies.

---

### 1.3 Android Build Environment & Deployment
- **Java SDK**:
  `export JAVA_HOME="$HOME/.jdk/jdk-17.0.10+7/Contents/Home"`
  `$JAVA_HOME/bin/java -version`:
  `openjdk version "17.0.10" 2024-01-16`
  `OpenJDK Runtime Environment Temurin-17.0.10+7 (build 17.0.10+7)`
- **Android SDK**:
  `export ANDROID_HOME="$HOME/Library/Android/sdk"`
  Contains `build-tools`, `cmdline-tools`, `platform-tools`, `platforms` (android-34 installed).
- **Gradle compilation**:
  `cd android && ./gradlew assembleDebug --no-daemon`
  Execution time: 6 seconds.
  Result: `BUILD SUCCESSFUL in 6s (33 actionable tasks: 1 executed, 32 up-to-date)`.
- **Output APK**:
  File location: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android/app/build/outputs/apk/debug/app-debug.apk`
  File size: 16,216,250 bytes (~16.2 MB).
- **Device Installation**:
  `/tmp/platform-tools/adb install -r /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android/app/build/outputs/apk/debug/app-debug.apk`
  Output:
  `Performing Streamed Install`
  `Success`
  Install duration: ~12 seconds.
- **Application Startup**:
  `/tmp/platform-tools/adb shell am start -n com.galaxycontinuity.app/.MainActivity`
  Logcat verification:
  ```
  D GalaxyWS: Connecting to ws://127.0.0.1:8765/ws
  D GalaxyWS: WebSocket opened!
  D ClipboardSync: Updated Galaxy clipboard from Mac: https://t.me/ThemesBest...
  ```
  Immediately connects and bidirectional sync activates.

---

### 1.4 macOS Build Environment & Host Process
- **Swift version and build**:
  `cd mac && swift build`
  Execution time: 0.17 seconds incremental.
  Target executable: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac/.build/debug/GalaxyContinuity`
- **Host Process Inspection**:
  `lsof -i :8765` revealed:
  ```
  COMMAND  PID        USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
  Galaxy  2616 frogs_hyles    3u  IPv4 0x291aa07c71075ad3      0t0  TCP *:ultraseek-http (LISTEN)
  ```
  Process 2616 is `/Applications/Galaxy Continuity.app/Contents/MacOS/Galaxy Continuity`, which was launched earlier and occupies port 8765.
  **Critical constraint**: When building and running `mac/.build/debug/GalaxyContinuity`, developers or test runners must terminate previous instances (`pkill -f "Galaxy Continuity" || true`) before starting the new binary, otherwise port 8765 will fail with `EADDRINUSE`.

---

## 2. Logic Chain

1. **Physical Pipeline Viability**:
   - The Samsung Galaxy A70 is physically attached over USB (`transport_id:1`), authorized in ADB (`device`), screen is active, and both accessibility and notification listener permissions are granted.
   - Reversing port 8765 via `adb reverse tcp:8765 tcp:8765` creates a local TCP bridge between phone loopback `127.0.0.1:8765` and macOS port 8765.
   - When the Android app connects to `127.0.0.1:8765`, connection succeeds instantly without multicast discovery or Wi-Fi configuration.

2. **Rapid Build & Deployment Feedback Loop**:
   - Android Gradle compile takes only 6 seconds.
   - APK install over ADB takes only 12 seconds.
   - Swift compilation on macOS takes < 1 second.
   - Total turnaround time from code modification to running on real device + real Mac is under 20 seconds.

3. **Lean Verification Directives**:
   - The user request explicitly demands:
     *"Conserve execution limits and steps by avoiding excessive or redundant test suites, verifying changes through direct deployment and focused functional checks on the physical device and running Mac app."*
   - Redundant end-to-end multi-tier mock suites consume hundreds of seconds and risk context overflow.
   - Instead, every requirement can be directly and objectively verified via real-device assertions:
     - **Keystroke typing**: Direct text injection into active input field on phone; verified via `adb shell uiautomator dump` asserting string content in UI hierarchy.
     - **Trackpad scrolling**: Two-finger scroll on Mac; verified via logcat `Gesture completed` or change in list scroll position.
     - **Window presentation**: Borderless floating window with custom smartphone bezel chassis, transparent titlebar, punch hole; verified via AppKit window properties and compilation.
     - **Notification click navigation**: Notification click on Mac; verified via `ScreenMirroringWindowController.shared.show()` and `adb shell dumpsys window | grep mCurrentFocus` showing target app brought to foreground.
     - **Auto-reconnection**: Force-stopping Android app or restarting Mac server; verified via logcat `WebSocket opened!` within 2 seconds without user action.

---

## 3. Caveats

1. **Port 8765 Contention**:
   - `/Applications/Galaxy Continuity.app` (PID 2616) was running in the background. If workers launch `mac/.build/debug/GalaxyContinuity` without stopping PID 2616, bind to port 8765 will fail. The verification workflow must include `pkill -f "Galaxy Continuity" || true`.
2. **Headless Limitations on macOS UI Window**:
   - The subagents execute in a non-GUI terminal shell. `swift test` builds the test bundle, but running `xcrun xctest` requires full Xcode Developer Tools (`xcrun: error: unable to find utility "xctest"`).
   - Swift code and AppKit UI structures can be built cleanly via `swift build`, and mock-socket integration / model tests can be validated either via unit tests or focused functional test scripts.
3. **No Caveats Regarding Physical Device**:
   - Physical device deployment is completely verified, working, and 100% accessible via `/tmp/platform-tools/adb`.

---

## 4. Conclusion & Lean Verification Workflow

The environment is fully configured and ready for rapid implementation and deployment. Below is the authoritative lean verification workflow for Iteration 3.

### Lean Verification Workflow Matrix

| Step | Action | Exact Command | Success Criterion |
|---|---|---|---|
| **1. Build Mac** | Compile macOS Host | `cd mac && swift build` | `Build complete!` with 0 errors |
| **2. Build Android** | Compile Debug APK | `export JAVA_HOME=~/.jdk/jdk-17.0.10+7/Contents/Home`<br>`export ANDROID_HOME=~/Library/Android/sdk`<br>`cd android && ./gradlew assembleDebug --no-daemon` | `BUILD SUCCESSFUL in <10s`<br>`app-debug.apk` generated |
| **3. Port Reverse** | Setup ADB Reverse | `/tmp/platform-tools/adb reverse tcp:8765 tcp:8765`<br>`/tmp/platform-tools/adb reverse tcp:8766 tcp:8766` | Returns exit code 0 |
| **4. Deploy APK** | Install to Galaxy A70 | `/tmp/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk` | `Performing Streamed Install` -> `Success` |
| **5. Restart Host** | Restart Mac Host Binary | `pkill -f "Galaxy Continuity" \|\| true`<br>`sleep 1`<br>`mac/.build/debug/GalaxyContinuity &` | `lsof -i :8765` shows listening socket |
| **6. Launch App** | Start Android App | `/tmp/platform-tools/adb shell am start -n com.galaxycontinuity.app/.MainActivity` | `Starting: Intent...` |
| **7. Verify Reconnect** | Automatic USB Connect | `/tmp/platform-tools/adb logcat -d -t 30 --pid=$(/tmp/platform-tools/adb shell pidof com.galaxycontinuity.app) \| grep -E 'GalaxyWS\|Connected'` | `WebSocket opened!` without manual IP entry |
| **8. Verify Typing** | Keyboard input into field | Focus field on device via ADB, send typing from Mac / ADB input text, dump UI hierarchy: `/tmp/platform-tools/adb shell uiautomator dump /data/local/tmp/ui.xml` | String present in UI XML node |
| **9. Verify Scroll** | Two-finger scroll | Open scrollable view, trigger scroll event: `/tmp/platform-tools/adb shell input swipe 540 1600 540 800 200` | Logcat confirms gesture completion |
| **10. Verify Notification** | Click forwarded notif | Trigger test notification, click on Mac, verify mirror window focuses and target app foregrounds | `dumpsys window \| grep mCurrentFocus` shows target package |

---

## 5. Verification Method

### 5.1 Independent Reproduction Commands

To independently reproduce the entire build, deploy, and verify pipeline:

```bash
# 1. Verify Device
/tmp/platform-tools/adb devices -l
/tmp/platform-tools/adb reverse tcp:8765 tcp:8765
/tmp/platform-tools/adb reverse --list

# 2. Build Android
export JAVA_HOME="$HOME/.jdk/jdk-17.0.10+7/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android
./gradlew assembleDebug --no-daemon

# 3. Deploy to Device
/tmp/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
/tmp/platform-tools/adb shell am start -n com.galaxycontinuity.app/.MainActivity

# 4. Build macOS Host
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/mac
swift build

# 5. Verify Active Socket Connection
/tmp/platform-tools/adb logcat -d -t 30 --pid=$(/tmp/platform-tools/adb shell pidof com.galaxycontinuity.app) | grep -E "GalaxyWS|WebSocket"
```

### 5.2 Invalidation Conditions
- `/tmp/platform-tools/adb devices -l` fails to find `R58M5763N2Y`.
- Gradle build fails or `assembleDebug` fails to produce `app-debug.apk`.
- `adb install -r` fails with signature mismatch or installation error.
- Port 8765 reverse is rejected or not accepted by Android USB daemon.
- macOS app fails to compile with `swift build`.
