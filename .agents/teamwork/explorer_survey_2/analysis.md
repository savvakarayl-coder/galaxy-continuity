# Android Application Codebase Analysis — Galaxy Continuity

## Executive Summary

This report provides an in-depth survey of the Android application codebase (`android/`) in the **Galaxy Continuity** repository. The Android app is designed as a native Kotlin Jetpack Compose client that pairs with the macOS companion app (`mac/`) over local network mDNS/Bonjour, WebSocket, and HTTP to deliver Apple Continuity-like capabilities for Samsung Galaxy devices.

Currently, the Android application is in an early prototype state:
- **Universal Clipboard**: Plain text synchronization is implemented with loop prevention; **image clipboard transfer is completely absent**, and Android 10+ background clipboard restrictions are unaddressed.
- **Quick Drop**: WebSocket message parsing for `file_available` exists, but the download handler is an **empty stub**; file sending (HTTP POST `/api/upload`), file picking, and system share intents (`ACTION_SEND`) are **completely absent**.
- **Screen Mirroring**: **Completely absent** on both Android and macOS sides (no `MediaProjection`, no `MediaCodec` streamer, no `AccessibilityService` input injection).
- **Continuity Camera**: **Completely absent** (no Camera2/CameraX capture, no camera streaming, no `CAMERA` permission).
- **Notification Synchronization**: Outbound notification forwarding (`NotificationListenerService`) is implemented for title and body; **interactive quick reply is completely absent** (no `RemoteInput` extraction, no reply action routing).
- **Peer Discovery**: Local Wi-Fi mDNS discovery (`NsdDiscovery`) is implemented; **offline BLE advertising/scanning and Wi-Fi Direct (P2P) are completely absent**.
- **Build & Test Infrastructure**: The repository is missing `gradlew` wrapper binaries (`gradlew`, `gradle/wrapper/gradle-wrapper.jar`); the host macOS environment lacks a local JDK and Android SDK; GitHub Actions CI workflow (`.github/workflows/build-apk.yml`) is currently failing during Gradle compilation; and **zero unit or integration tests exist in `android/`**.

---

## 1. Project Architecture & Codebase Structure

### 1.1 Directory Structure
```
android/
├── build.gradle.kts                   # Root Gradle build script (AGP 8.2.2, Kotlin 1.9.22)
├── settings.gradle.kts                # Subproject inclusion (:app), repo management
├── gradle/
│   └── wrapper/
│       └── gradle-wrapper.properties  # Gradle 8.2 distribution URL (wrapper JAR & script MISSING)
└── app/
    ├── build.gradle.kts               # App module build script (dependencies, SDK versions)
    ├── proguard-rules.pro             # ProGuard keep rules
    └── src/
        └── main/
            ├── AndroidManifest.xml    # App manifest, permissions, service declarations
            ├── java/com/galaxycontinuity/app/
            │   ├── MainActivity.kt    # Jetpack Compose UI (ContinuityScreen)
            │   ├── network/
            │   │   ├── NsdDiscovery.kt    # Android NsdManager mDNS client
            │   │   └── WebSocketClient.kt # OkHttp WebSocket client & protocol serializer
            │   ├── service/
            │   │   ├── ContinuityService.kt           # Foreground Service coordinating sync
            │   │   ├── ClipboardSync.kt               # Android ClipboardManager listener/writer
            │   │   └── NotificationForwarderService.kt# NotificationListenerService
            │   └── ui/
            │       └── theme/         # (Empty directory)
            └── res/
                ├── drawable/          # (Empty directory)
                └── values/
                    ├── colors.xml     # Theme color constants
                    └── strings.xml    # App name ("Galaxy Continuity")
```

### 1.2 Gradle Configuration & Build Variants
- **Android Gradle Plugin (AGP)**: `8.2.2`
- **Kotlin Android Plugin**: `1.9.22`
- **Gradle Version Target**: `8.2` (configured in `gradle-wrapper.properties`), `8.5` (configured in `.github/workflows/build-apk.yml`)
- **SDK Targets**:
  - `compileSdk`: `34` (Android 14)
  - `minSdk`: `26` (Android 8.0 Oreo)
  - `targetSdk`: `34` (Android 14 UpsideDownCake)
  - `jvmTarget`: `JavaVersion.VERSION_17`
- **Compose Compiler Extension**: `1.5.8`
- **Compose BOM**: `2024.02.00`
- **Build Variants**:
  - `debug`: Standard debug build using Android default debug keystore.
  - `release`: `isMinifyEnabled = false`, ProGuard rules configured. **Crucial gap**: No `signingConfig` is defined in `release`. Running `./gradlew assembleRelease` creates an unsigned APK (`app-release-unsigned.apk`) unless a signing config or debug fallback is configured.

### 1.3 Key Dependencies
| Dependency | Version | Purpose |
|---|---|---|
| `androidx.core:core-ktx` | `1.12.0` | Core Kotlin extensions |
| `androidx.lifecycle:lifecycle-runtime-ktx` | `2.7.0` | Android lifecycle coroutine scopes |
| `androidx.activity:activity-compose` | `1.8.2` | ComponentActivity Compose integration |
| `androidx.compose:compose-bom` | `2024.02.00` | UI, UI Graphics, Tooling Preview, Material3 |
| `androidx.compose.material:material-icons-extended` | (BOM) | Extended material icons |
| `com.squareup.okhttp3:okhttp` | `4.12.0` | WebSocket client, HTTP networking |
| `org.jetbrains.kotlinx:kotlinx-coroutines-android`| `1.7.3` | Background asynchronous processing |

---

## 2. Feature Implementation Status & Gaps

### 2.1 Universal Clipboard
- **Current State**:
  - `ClipboardSync.kt` listens to `ClipboardManager.OnPrimaryClipChangedListener`.
  - When clipboard text updates, it triggers `onSendClipboardToMac(text)` and sends:
    ```json
    {
      "type": "clipboard",
      "content": "<copied text>",
      "contentType": "text/plain",
      "source": "phone"
    }
    ```
  - Incoming clipboard messages from Mac trigger `updateClipboardFromMac(text)`, calling `clipboardManager.setPrimaryClip(ClipData.newPlainText(...))`.
  - Echo loop prevention uses `isUpdatingFromMac` and `lastSeenText` state variables.
- **Identified Gaps**:
  1. **Image Transfer**: Bidirectional image clipboard is completely unimplemented. The code strictly checks `clip.getItemAt(0).text?.toString()`. No extraction of image URI or bitmap, no MIME type handling for `image/png` or `image/jpeg`, and no Base64 payload or HTTP image upload/download.
  2. **Android 10+ Background Clipboard Restrictions**: Starting with Android 10 (API 29), background apps cannot access clipboard data unless they have IME (keyboard input method) focus or are active in the foreground. When the app is in the background, `clipboardManager.primaryClip` returns `null` or is blocked by Android security policy. Mitigation requires:
     - Foreground Activity / Quick Settings Tile / Notification action to paste.
     - Or an Accessibility Service that has window focus / permission.
     - Or `appops set com.galaxycontinuity.app READ_CLIPBOARD allow` for automated test environments.

### 2.2 Quick Drop (Bidirectional File Transfer)
- **Current State**:
  - `WebSocketClient.kt` decodes `file_available` JSON frames from Mac:
    ```json
    {
      "type": "file_available",
      "fileId": "<uuid>",
      "filename": "photo.jpg",
      "fileSize": 1024000,
      "mimeType": "image/jpeg",
      "sender": "MacBook Pro"
    }
    ```
  - `ContinuityService.kt` contains an **empty stub**:
    ```kotlin
    override fun onFileAvailable(fileId: String, filename: String, size: Long) {
        // Trigger download via DownloadManager or HTTP client
    }
    ```
- **Identified Gaps**:
  1. **File Receiving (Mac -> Galaxy)**: No HTTP client requesting `GET http://<macHost>:<macPort>/api/download/<fileId>`, no file stream saving to `Environment.DIRECTORY_DOWNLOADS` or MediaStore, and no user-facing download progress notification.
  2. **File Sending (Galaxy -> Mac)**: No implementation to upload files from phone to Mac. Specifically:
     - No file picker UI or file selection logic.
     - No `android.intent.action.SEND` or `SEND_MULTIPLE` intent filter in `AndroidManifest.xml` to allow sending files from Gallery or Files apps.
     - No HTTP client executing `POST /api/upload` with headers `X-Filename`, `X-Filesize` and multipart or binary body.
  3. **Storage Permissions & Scoped Storage**: No SAF (Storage Access Framework) or MediaStore integration.

### 2.3 Screen Mirroring
- **Current State**: **Completely Absent**.
- **Identified Gaps**:
  1. **Screen Capture**: Android requires `MediaProjectionManager.createScreenCaptureIntent()` and a foreground service with `android:foregroundServiceType="mediaProjection"` (mandated on Android 14+ / API 34).
  2. **Video Encoding & Streaming**: Requires `MediaCodec` (H.264 / AVC encoding) feeding off a `VirtualDisplay` from `MediaProjection`, or streaming MJPEG frames over WebSocket / HTTP, or WebRTC.
  3. **Remote Input Injection**: On Android, regular third-party applications **cannot** inject global touch events into other apps without:
     - An Android `AccessibilityService` implementing `dispatchGesture(...)` (the standard non-root method supported on Android 7.0+ / API 24).
     - Or ADB shell input (`input tap x y`, `input swipe x1 y1 x2 y2`).
     - Or root `uinput`.
  4. Protocol messages for `screen_start`, `screen_stop`, `screen_frame`, and `input_event` must be defined and implemented.

### 2.4 Continuity Camera
- **Current State**: **Completely Absent**.
- **Identified Gaps**:
  1. **Camera Permissions**: `android.permission.CAMERA` is missing in `AndroidManifest.xml`.
  2. **Capture Pipeline**: No `Camera2` (`CameraDevice`, `CameraCaptureSession`, `ImageReader`) or `CameraX` (`ImageAnalysis`) session configured.
  3. **Stream Delivery**: No MJPEG, H.264, or WebSocket stream pipeline to send camera frames to macOS.
  4. **Control Protocol**: No commands for starting/stopping the camera, lens switching (front/back), or resolution negotiation (`camera_start`, `camera_stop`, `camera_frame`).

### 2.5 Notification Synchronization
- **Current State**:
  - `NotificationForwarderService.kt` extends `NotificationListenerService`.
  - Registered in `AndroidManifest.xml` with `BIND_NOTIFICATION_LISTENER_SERVICE`.
  - Intercepts non-ongoing notifications from third-party apps, extracts `android.title` and `android.text` from `sbn.notification.extras`, resolves application name via `PackageManager`, and sends:
    ```json
    {
      "type": "phone_notification",
      "app": "WhatsApp",
      "title": "Alice",
      "text": "Hello!",
      "timestamp": 1730940000000
    }
    ```
- **Identified Gaps**:
  1. **Interactive Quick Reply**: Completely missing.
     - `NotificationForwarderService` does not inspect `sbn.notification.actions` for `RemoteInput` instances.
     - It does not store the notification key or `PendingIntent`.
     - There is no WebSocket handler for incoming reply messages from Mac (e.g. `notification_reply` with `notificationKey` and `replyText`).
     - It does not reconstruct the reply intent using `RemoteInput.addResultsToIntent(...)` and invoke `action.actionIntent.send(...)`.
  2. **Notification Dismissal**: Dismissals are not propagated bidirectionally.

### 2.6 Peer Discovery & Networking
- **Current State**:
  - `NsdDiscovery.kt` implements `NsdManager.DiscoveryListener` for `_galaxycontinuity._tcp.`.
  - Resolves host and port, invoking callback on `ContinuityService` to initiate `WebSocketClient.connect(host, port)`.
  - `WebSocketClient.kt` initiates `ws://<host>:<port>/ws` and sends initial `handshake`.
- **Identified Gaps**:
  1. **Offline BLE Discovery**: Completely missing.
     - No BLE advertiser (`BluetoothLeAdvertiser`) or scanner (`BluetoothLeScanner`).
     - No BLE GATT server or connection handover mechanism for when devices are not on the same Wi-Fi network.
     - Missing Bluetooth permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (Android 12+ / API 31).
  2. **Wi-Fi Direct (P2P)**: Completely missing.
     - No `WifiP2pManager` implementation for discovering peers or establishing a Wi-Fi P2P group when no local access point exists.
     - Missing `NEARBY_WIFI_DEVICES` permission (Android 13+ / API 33) and `ACCESS_FINE_LOCATION`.
  3. **Android mDNS Advertising**: `NsdDiscovery` only scans; it does not advertise (`registerService`), preventing Mac from discovering Galaxy if Galaxy acts as the server.

---

## 3. Build & Test Infrastructure Analysis

### 3.1 Host Machine Environment
- **Operating System**: macOS (Darwin 23.4.0, arm64).
- **Installed Tools**: `/usr/bin/curl`, `/usr/bin/git`, `/usr/bin/swift`, `/usr/bin/python3`, `/Users/frogs_hyles/.gemini/antigravity/bin/gh` (v2.103.3).
- **Missing Local Tools**:
  - `java` / JDK is **not installed** or located in PATH (`Unable to locate a Java Runtime`).
  - `gradle` CLI is **not installed**.
  - `android/gradlew` shell script and `android/gradle/wrapper/gradle-wrapper.jar` are **missing** from the repository.
  - Android SDK (`ANDROID_HOME`) is **not configured** locally.

### 3.2 GitHub Actions CI Status
- Workflow located at `.github/workflows/build-apk.yml`.
- Configured to run on `ubuntu-latest` with Temurin JDK 17 and Gradle 8.5 (`gradle/actions/setup-gradle@v3`).
- **Current CI Status**: All 4 historical runs (up to run `42317900251`, commit `00528fc`) have **failed** at step 6 ("Build APK with Gradle").
- Root causes for build failures:
  1. Invocation of `gradle assembleDebug` in CI without Gradle wrapper validation.
  2. Android SDK license acceptance issues or missing SDK 34 platform licenses on runner.
  3. Compose / Material3 API discrepancies (e.g. parameter naming in `OutlinedTextFieldDefaults.colors` between Material2 and Material3, or icon resolution in `Icons.Default.Laptop`).

### 3.3 Test Suite Status & Automated Headless Verification
- **Current Test Coverage**: **0%**. No `src/test/` or `src/androidTest/` directories exist in `android/app/`.
- **Missing Test Dependencies**: `app/build.gradle.kts` lacks JUnit (`junit:junit:4.13.2`), MockK (`io.mockk:mockk`), Robolectric (`org.robolectric:robolectric`), and OkHttp MockWebServer (`com.squareup.okhttp3:mockwebserver:4.12.0`).
- **Headless & Device-Free Verification Strategy**:
  1. **JVM Unit Tests with Robolectric & MockWebServer**:
     - `WebSocketClientTest`: Test handshake exchange, message serialization, JSON parsing, and reconnection logic against `MockWebServer`.
     - `ClipboardSyncTest`: Test text and image clipboard transformation, loop prevention (`isUpdatingFromMac`).
     - `NotificationForwarderServiceTest`: Test notification extraction, filtering of ongoing/self notifications, and remote reply intent dispatching.
     - `DiscoveryProtocolTest`: Test mDNS and BLE advertisement payload serialization.
  2. **Simulated Socket Protocol Tests**:
     - A headless Python or Swift integration script connecting to the WebSocket endpoint on port 8765 to verify bidirectional messaging without any Android hardware.

---

## 4. Key Recommendations & Implementation Roadmap

1. **Gradle Wrapper & Build Fix**:
   - Add standard `gradlew` wrapper script and `gradle/wrapper/gradle-wrapper.jar` (Gradle 8.2 or 8.5) to `android/`.
   - Update `android/app/build.gradle.kts` with signing configuration (e.g. configure `release` build to sign with debug keystore or generated release keystore so `./gradlew assembleRelease` outputs a signed APK).
   - Ensure Material3 Compose code compiles cleanly.
2. **Feature Completions**:
   - **Universal Clipboard**: Add image MIME types, Base64/URI encoding, and content provider resolution.
   - **Quick Drop**: Implement OkHttp GET for downloading files from Mac to Downloads folder, and OkHttp POST for uploading files to `/api/upload`; add `ACTION_SEND` intent filter in `AndroidManifest.xml`.
   - **Notifications**: Implement `RemoteInput` extraction and WebSocket handler for `notification_reply` to trigger `action.actionIntent.send(...)`.
   - **Screen Mirroring & Camera**: Implement MediaProjection and Camera2 streaming modules with appropriate foreground service permissions (`FOREGROUND_SERVICE_MEDIA_PROJECTION`, `CAMERA`).
   - **Discovery**: Implement BLE Advertiser/Scanner and Wi-Fi Direct helper classes.
3. **Automated Testing Suite**:
   - Add `junit:junit:4.13.2`, `io.mockk:mockk:1.13.9`, and `com.squareup.okhttp3:mockwebserver:4.12.0` to `testImplementation`.
   - Implement unit test suites verifying all protocol and service logic headless.
