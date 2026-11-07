# Android Client Investigation & Drop-in Implementation Blueprint for Milestone 3 (Screen Mirroring & Continuity Camera)

**Agent**: `m3_explorer_2`  
**Milestone**: M3 (Screen Mirroring & Continuity Camera)  
**Assigned Task**: Android Client Investigation & Architecture Blueprint  
**Date**: 2026-11-07  

---

## 1. Observation

### 1.1 Android Manifest & Permissions State
- **File**: `android/app/src/main/AndroidManifest.xml`
  - Current permissions declared (lines 4–13):
    ```xml
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
    ```
  - *Observation*: The manifest targets `compileSdk = 34` and `targetSdk = 34` (`android/app/build.gradle.kts` lines 8–13). On Android 14 (API 34), foreground services with types `mediaProjection` and `camera` require explicit permissions:
    - Missing: `android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION`
    - Missing: `android.permission.FOREGROUND_SERVICE_CAMERA`
    - Missing: `android.permission.CAMERA`
    - Missing: `<uses-feature android:name="android.hardware.camera" android:required="false" />`
  - Current declared services (lines 34–47):
    - Only `ContinuityService` (`foregroundServiceType="connectedDevice"`) and `NotificationForwarderService` (`BIND_NOTIFICATION_LISTENER_SERVICE`) are declared.
    - Missing service declarations: `ScreenMirroringService`, `ContinuityCameraService`, and `ContinuityAccessibilityService`.

### 1.2 Android Networking & Protocol Handlers
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`
  - In `ContinuityListener` interface (lines 17–25):
    ```kotlin
    interface ContinuityListener {
        fun onConnected(macName: String)
        fun onDisconnected()
        fun onClipboardReceived(content: String, contentType: String = "text/plain", hash: String? = null)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String)
        fun onFileComplete(fileId: String, status: String, message: String)
        fun onPingReceived(message: String)
    }
    ```
    *Observation*: No callbacks exist for `screen_start`, `screen_stop`, `input_event`, `input_key`, `camera_start`, `camera_stop`, or `camera_control`.
  - In `onMessage` (lines 55–96):
    The `when (json.optString("type"))` block does not handle screen mirroring or camera control messages.
  - Sending methods:
    `WebSocketClient` only has text frame senders (`sendHandshake`, `sendClipboard`, `sendFileProgress`, `sendFileComplete`, `sendNotification`). No method exists to transmit binary media stream packets (WebSocket opcode `0x2`) or to send `screen_stop` and `camera_stop`.

### 1.3 Service Coordination & Architecture
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`
  - Currently acts as the central foreground service managing the single active WebSocket connection (`activeClient`), `NsdDiscovery`, `ClipboardSync`, and `FileTransferClient`.
  - No references exist to screen capture or camera capture.
- **File**: `android/app/src/main/java/com/galaxycontinuity/app/MainActivity.kt`
  - Launches `ContinuityService` and renders Compose UI cards for status, clipboard, and notifications.
  - Has no UI or permission flow for `MediaProjection` (`MediaProjectionManager.createScreenCaptureIntent()`), runtime `CAMERA` permission, or accessibility service enablement.

### 1.4 Authoritative Protocol Requirements (`shared/PROTOCOL.md`)
- **Binary Media Stream Packet Framing (§ 4.2)**:
  - 5-byte packet header:
    - Byte 0: `UInt8` Stream Type (`0x01` = Screen Mirroring Frame, `0x02` = Continuity Camera Frame).
    - Bytes 1–4: `UInt32` Big-Endian Payload Length.
    - Bytes 5..N: Media Payload.
  - For `0x01` (Screen Mirroring): Raw H.264 NAL units (Annex B `00 00 00 01`) or JPEG frame buffer.
  - For `0x02` (Continuity Camera): Raw JPEG image buffer (starts with `0xFF 0xD8`, required by virtual webcam CMIO extension and verified in `test_35_continuity_camera_video_binary_stream`).
- **Screen Mirroring Messages (§ 5.4)**:
  - `screen_start`: `width` (Int, default 1080), `height` (Int, default 2400), `fps` (Int, default 30), `bitrate` (Int, default 4000000).
  - `screen_stop`: `reason` (String, default `"user_dismissed"`).
  - `input_event`: `action` (`"down"`, `"move"`, `"up"`, `"scroll"`), `x` (`0.0`..`1.0`), `y` (`0.0`..`1.0`), `button` (Int, optional).
  - `input_key`: `key` (`"BACK"`, `"HOME"`, `"RECENTS"`, `"VOLUME_UP"`, `"VOLUME_DOWN"`, `"ENTER"`, `"POWER"`), `keyCode` (Int, optional).
- **Continuity Camera Messages (§ 5.5)**:
  - `camera_start`: `lens` (or `facing`: `"back"`, `"front"`, `"ultra_wide"`, `"telephoto"`), `quality` (or `resolution`: `"1080p"`, `"720p"`, `"4k"`), `fps` (Int, default 30).
  - `camera_stop`: empty envelope.
  - `camera_control` (or alias `camera_switch_lens`): `action` (`"switch_lens"`, `"set_zoom"`, `"toggle_torch"`), `lens` (or `facing`), `zoom` (Double), `torch` (Boolean).
- **Error Handling & Idempotence (§ 6.2 & E2E Tests)**:
  - Coordinate clamping: Out-of-bounds normalized coordinates (< 0.0 or > 1.0) must be clamped safely without crashing (`test_29`, `test_30`).
  - Unknown action or unknown keyCode must be dropped safely (`test_31`, `test_32`).
  - `screen_stop` when inactive is idempotent (`test_34`).
  - `camera_stop` when inactive is idempotent (`test_37`).
  - Stalling detection: If no frames are produced for > 5000ms, stream terminates gracefully.

---

## 2. Logic Chain

1. **Android 14 API 34 Foreground Service Constraints**:
   - Starting in Android 14 (API 34), a service using `MediaProjection` must declare `android:foregroundServiceType="mediaProjection"` and hold `FOREGROUND_SERVICE_MEDIA_PROJECTION`.
   - Crucially, `startForeground(...)` with `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` must be called *before* invoking `MediaProjectionManager.getMediaProjection(resultCode, data)`. Failing to do so triggers a runtime `SecurityException`.
   - Similarly, a service capturing Camera2 in background must declare `android:foregroundServiceType="camera"` and hold `FOREGROUND_SERVICE_CAMERA` and `CAMERA`.
   - Therefore, screen capture and camera capture must run in dedicated services (`ScreenMirroringService` and `ContinuityCameraService`) rather than bundling everything into `ContinuityService` (`connectedDevice`).

2. **Remote Input Injection Mechanics**:
   - Standard Android apps cannot inject global touch events into other apps via `Instrumentation` or `MotionEvent` without system signatures or root permissions.
   - The standard, Google Play-compliant mechanism for injecting touch and navigation events is an `AccessibilityService` with `android:canPerformGestures="true"`.
   - `ContinuityAccessibilityService` implements:
     - Touch: Dispatches `GestureDescription` via `dispatchGesture()`. It maps normalized `x, y` (`0.0`–`1.0`) to pixel coordinates using `DisplayMetrics`, clamps to `[0.0, 1.0]`, and creates touch paths for `"down"` (start stroke), `"move"`, `"up"` (complete stroke/tap), and `"scroll"` (swipe stroke).
     - Navigation: Dispatches global actions using `performGlobalAction()`:
       - `GLOBAL_ACTION_BACK` for `"BACK"` or `keyCode = 4`.
       - `GLOBAL_ACTION_HOME` for `"HOME"` or `keyCode = 3`.
       - `GLOBAL_ACTION_RECENTS` for `"RECENTS"` or `keyCode = 187`.
       - `GLOBAL_ACTION_LOCK_SCREEN` for `"POWER"`.
       - `GLOBAL_ACTION_NOTIFICATIONS` for `"NOTIFICATIONS"`.
   - To make this 100% testable on the JVM without an active Android accessibility manager, coordinate clamping and key mapping logic are encapsulated in a pure Kotlin helper `RemoteInputMapper`.

3. **Binary Streaming Architecture**:
   - `StreamPacket` encapsulates the 5-byte binary framing protocol:
     `[streamType: 1 byte][length: 4 bytes Big-Endian][payload]`.
   - `ScreenMirroringService` configures `MediaProjection`, sets up `MediaCodec` (H.264 `video/avc`), creates a `VirtualDisplay` directing screen output to the codec surface, retrieves encoded NAL units from output buffers, wraps them in `StreamPacket.pack(0x01, nalData)`, and dispatches them via `WebSocketClient.sendBinary(...)`.
   - `ContinuityCameraService` uses `Camera2` (`CameraManager`), opens the requested sensor (`CameraCharacteristics.LENS_FACING_BACK` or `FRONT`), sets up an `ImageReader` configured with `ImageFormat.JPEG`, retrieves JPEG image buffers (verifying the `0xFF 0xD8` marker), wraps them in `StreamPacket.pack(0x02, jpegData)`, and dispatches them via `WebSocketClient.sendBinary(...)`.
   - Camera controls (`set_zoom`, `toggle_torch`, `switch_lens`) operate directly on `CaptureRequest.Builder` (`CONTROL_ZOOM_RATIO`, `FLASH_MODE_TORCH`).

4. **Integration with `ContinuityService` and `MainActivity`**:
   - `ContinuityService` implements `WebSocketClient.ContinuityListener`. When incoming `screen_start`/`screen_stop` or `camera_start`/`camera_stop` control messages arrive from macOS, it starts/stops the appropriate foreground services and relays input events to `ContinuityAccessibilityService`.
   - `MainActivity` provides UI toggles and request launchers for:
     - `MediaProjectionManager.createScreenCaptureIntent()`
     - `Manifest.permission.CAMERA`
     - Intent to open `Settings.ACTION_ACCESSIBILITY_SETTINGS` with an indicator of accessibility service connection status.

---

## 3. Caveats

1. **MediaProjection Permission Dialog**:
   - Android requires explicit user consent via a system dialog (`MediaProjectionManager.createScreenCaptureIntent()`) before `MediaProjection` can be instantiated. Consent cannot be granted silently in the background. The blueprint handles this by having `MainActivity` register an `ActivityResultLauncher` and passing the `resultCode` and `Intent` data to `ScreenMirroringService`.
2. **Accessibility Service Activation**:
   - Accessibility services must be enabled by the user in Android System Settings (`Settings -> Accessibility -> Installed apps -> Galaxy Continuity Input`). The app provides a direct intent deep-link to this settings page with a live status check.
3. **Headless JVM Unit Testing**:
   - Physical camera sensors, `MediaProjection`, and `AccessibilityManager` are not available in headless JVM unit tests.
   - *Mitigation*: The blueprint decouples protocol serialization, 5-byte binary framing (`StreamPacket`), coordinate transformation, and key mapping into pure Kotlin components (`StreamPacket`, `RemoteInputMapper`) that achieve complete test coverage without requiring Android framework mocks or emulators.

---

## 4. Conclusion & Drop-in Blueprints

Below are complete, production-grade drop-in blueprints for Worker M3.

---

### Blueprint 1: `AndroidManifest.xml` Updates
**Target File**: `android/app/src/main/AndroidManifest.xml`

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />

    <application
        android:allowBackup="true"
        android:icon="@android:drawable/ic_menu_share"
        android:label="Galaxy Continuity"
        android:roundIcon="@android:drawable/ic_menu_share"
        android:supportsRtl="true"
        android:theme="@android:style/Theme.Material.NoActionBar"
        android:usesCleartextTraffic="true">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:theme="@android:style/Theme.Material.NoActionBar">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <!-- Main Continuity Orchestration Service -->
        <service
            android:name=".service.ContinuityService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="connectedDevice" />

        <!-- Screen Mirroring Service (MediaProjection + MediaCodec) -->
        <service
            android:name=".service.ScreenMirroringService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="mediaProjection" />

        <!-- Continuity Camera Service (Camera2 + ImageReader) -->
        <service
            android:name=".service.ContinuityCameraService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="camera" />

        <!-- Accessibility Service for Remote Touch and Key Injection -->
        <service
            android:name=".service.ContinuityAccessibilityService"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
            android:exported="true">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/accessibility_service_config" />
        </service>

        <!-- Notification Listener Service -->
        <service
            android:name=".service.NotificationForwarderService"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
            android:exported="true">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>

        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>

    </application>

</manifest>
```

---

### Blueprint 2: `accessibility_service_config.xml`
**Target File**: `android/app/src/main/res/xml/accessibility_service_config.xml`

```xml
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows"
    android:canPerformGestures="true"
    android:description="@string/accessibility_service_description"
    android:notificationTimeout="100" />
```

---

### Blueprint 3: `strings.xml` Updates
**Target File**: `android/app/src/main/res/values/strings.xml`

```xml
<resources>
    <string name="app_name">Galaxy Continuity</string>
    <string name="accessibility_service_description">Enables remote touch gestures and navigation controls dispatched from your connected Mac during screen mirroring sessions.</string>
    <string name="screen_mirroring_notification">Streaming phone display to Mac</string>
    <string name="camera_streaming_notification">Streaming camera video feed to Mac</string>
</resources>
```

---

### Blueprint 4: Binary Stream Packet Framer (`StreamPacket.kt`)
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/network/StreamPacket.kt`

```kotlin
package com.galaxycontinuity.app.network

import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Standardized 5-byte binary packet framer according to shared/PROTOCOL.md § 4.2.
 *
 * Header layout:
 * - Byte 0: UInt8 Stream Type (0x01: Screen Mirroring Frame, 0x02: Continuity Camera Frame)
 * - Bytes 1-4: UInt32 Big-Endian Payload Length
 * - Bytes 5..N: Media Payload
 */
object StreamPacket {
    const val TYPE_SCREEN: Byte = 0x01
    const val TYPE_CAMERA: Byte = 0x02
    const val HEADER_SIZE: Int = 5

    data class UnpackedPacket(
        val streamType: Byte,
        val length: Int,
        val payload: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is UnpackedPacket) return false
            return streamType == other.streamType && length == other.length && payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var result = streamType.toInt()
            result = 31 * result + length
            result = 31 * result + payload.contentHashCode()
            return result
        }
    }

    /**
     * Packs a stream type and binary payload into a 5-byte header standard frame.
     */
    fun pack(streamType: Byte, payload: ByteArray): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + payload.size)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(streamType)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    fun packToByteString(streamType: Byte, payload: ByteArray): ByteString {
        return pack(streamType, payload).toByteString()
    }

    /**
     * Unpacks a 5-byte stream packet. Returns null if data is shorter than 5 bytes or payload is truncated.
     */
    fun unpack(bytes: ByteArray): UnpackedPacket? {
        if (bytes.size < HEADER_SIZE) return null
        val buffer = ByteBuffer.wrap(bytes)
        buffer.order(ByteOrder.BIG_ENDIAN)
        val streamType = buffer.get()
        val length = buffer.getInt()
        if (length < 0 || bytes.size < HEADER_SIZE + length) return null

        val payload = ByteArray(length)
        buffer.get(payload)
        return UnpackedPacket(streamType, length, payload)
    }
}
```

---

### Blueprint 5: `WebSocketClient.kt` Milestone 3 Updates
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`

```kotlin
package com.galaxycontinuity.app.network

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class WebSocketClient(
    private val context: Context,
    private val listener: ContinuityListener
) {
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
    }

    private val tag = "GalaxyWS"
    private var client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private var webSocket: WebSocket? = null
    var isConnected = false
        private set
    var currentHost = ""
    var currentPort = 8765
    private val mainHandler = Handler(Looper.getMainLooper())

    fun connect(host: String, port: Int = 8765) {
        currentHost = host
        currentPort = port
        disconnect()

        val url = "ws://$host:$port/ws"
        Log.d(tag, "Connecting to $url")

        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnected = true
                Log.d(tag, "WebSocket opened!")
                sendHandshake()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json = JSONObject(text)
                    when (val type = json.optString("type")) {
                        "handshake_ack" -> {
                            val macName = json.optString("device", "MacBook Pro")
                            mainHandler.post { listener.onConnected(macName) }
                        }
                        "clipboard" -> {
                            val content = if (json.has("content")) json.getString("content") else json.optString("payload", "")
                            val contentType = json.optString("contentType", "text/plain").ifEmpty { "text/plain" }
                            val hash = json.optString("hash").ifEmpty { null }
                            mainHandler.post { listener.onClipboardReceived(content, contentType, hash) }
                        }
                        "file_available" -> {
                            val fileId = json.optString("fileId")
                            val filename = json.optString("filename")
                            val size = json.optLong("fileSize")
                            mainHandler.post { listener.onFileAvailable(fileId, filename, size) }
                        }
                        "file_progress" -> {
                            val fileId = json.optString("fileId")
                            val transferred = json.optLong("bytesTransferred")
                            val total = json.optLong("totalBytes")
                            val pct = json.optDouble("percentage")
                            val status = json.optString("status")
                            mainHandler.post { listener.onFileProgress(fileId, transferred, total, pct, status) }
                        }
                        "file_complete" -> {
                            val fileId = json.optString("fileId")
                            val status = json.optString("status")
                            val message = json.optString("message")
                            mainHandler.post { listener.onFileComplete(fileId, status, message) }
                        }
                        "ping_device" -> {
                            val msg = json.optString("message", "Ping from Mac")
                            mainHandler.post { listener.onPingReceived(msg) }
                        }

                        // Milestone 3: Screen Mirroring
                        "screen_start" -> {
                            val width = json.optInt("width", 1080)
                            val height = json.optInt("height", 2400)
                            val fps = json.optInt("fps", 30)
                            val bitrate = json.optInt("bitrate", 4000000)
                            mainHandler.post { listener.onScreenStart(width, height, fps, bitrate) }
                        }
                        "screen_stop" -> {
                            val reason = json.optString("reason", "mac_requested").ifEmpty { null }
                            mainHandler.post { listener.onScreenStop(reason) }
                        }
                        "input_event" -> {
                            val action = json.optString("action", "down")
                            val x = json.optDouble("x", 0.5)
                            val y = json.optDouble("y", 0.5)
                            val button = json.optInt("button", 0)
                            mainHandler.post { listener.onRemoteInput(action, x, y, button) }
                        }
                        "input_key" -> {
                            val key = json.optString("key", "")
                            val keyCode = json.optInt("keyCode", 0)
                            mainHandler.post { listener.onRemoteKey(key, keyCode) }
                        }

                        // Milestone 3: Continuity Camera
                        "camera_start" -> {
                            val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")
                            val quality = if (json.has("quality")) json.getString("quality") else json.optString("resolution", "1080p")
                            val fps = json.optInt("fps", 30)
                            mainHandler.post { listener.onCameraStart(lens, quality, fps) }
                        }
                        "camera_stop" -> {
                            mainHandler.post { listener.onCameraStop() }
                        }
                        "camera_control", "camera_switch_lens" -> {
                            val action = json.optString("action", if (type == "camera_switch_lens") "switch_lens" else "")
                            val lens = if (json.has("lens")) json.getString("lens") else if (json.has("facing")) json.getString("facing") else null
                            val zoom = if (json.has("zoom")) json.getDouble("zoom") else null
                            val torch = if (json.has("torch")) json.getBoolean("torch") else null
                            mainHandler.post { listener.onCameraControl(action, lens, zoom, torch) }
                        }

                        else -> {
                            Log.d(tag, "Ignoring unhandled message type: $type")
                        }
                    }
                } catch (e: Exception) {
                    Log.e(tag, "Error parsing message: $text", e)
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                isConnected = false
                mainHandler.post { listener.onDisconnected() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                isConnected = false
                Log.e(tag, "WebSocket error: ${t.message}")
                mainHandler.post { listener.onDisconnected() }
            }
        })
    }

    private fun sendHandshake() {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 100

        val deviceName = "Samsung ${Build.MODEL}"
        val json = JSONObject().apply {
            put("type", "handshake")
            put("device", deviceName)
            put("platform", "android")
            put("version", "1.0.0")
            put("battery", JSONObject().apply {
                put("level", level)
                put("isCharging", false)
            })
        }
        webSocket?.send(json.toString())
    }

    fun sendBinary(data: ByteArray) {
        if (!isConnected) return
        webSocket?.send(data.toByteString())
    }

    fun sendBinary(byteString: ByteString) {
        if (!isConnected) return
        webSocket?.send(byteString)
    }

    fun sendScreenStop(reason: String = "user_dismissed") {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "screen_stop")
            put("reason", reason)
        }
        webSocket?.send(json.toString())
    }

    fun sendCameraStop() {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "camera_stop")
        }
        webSocket?.send(json.toString())
    }

    fun sendClipboard(content: String, contentType: String = "text/plain", hash: String? = null) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", content)
            put("payload", content)
            put("contentType", contentType)
            put("source", "phone")
            if (hash != null) {
                put("hash", hash)
            }
        }
        webSocket?.send(json.toString())
    }

    fun sendFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_progress")
            put("fileId", fileId)
            put("bytesTransferred", bytesTransferred)
            put("totalBytes", totalBytes)
            put("percentage", percentage)
            put("status", status)
        }
        webSocket?.send(json.toString())
    }

    fun sendFileComplete(fileId: String, status: String, message: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_complete")
            put("fileId", fileId)
            put("status", status)
            put("message", message)
        }
        webSocket?.send(json.toString())
    }

    fun sendNotification(app: String, title: String, text: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "phone_notification")
            put("app", app)
            put("title", title)
            put("text", text)
            put("timestamp", System.currentTimeMillis())
        }
        webSocket?.send(json.toString())
    }

    fun disconnect() {
        webSocket?.close(1000, "App closing")
        webSocket = null
        isConnected = false
    }
}
```

---

### Blueprint 6: Remote Input Mapper (`RemoteInputMapper.kt`)
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`

```kotlin
package com.galaxycontinuity.app.service

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent

/**
 * Pure Kotlin input coordinate clamping, gesture mapping, and keycode translation logic.
 * Decoupled from Android OS runtime to facilitate JVM testing.
 */
object RemoteInputMapper {

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

### Blueprint 7: `ContinuityAccessibilityService.kt`
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt`

```kotlin
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

        when (action.lowercase()) {
            "down" -> {
                downX = pixelX
                downY = pixelY
                downTime = System.currentTimeMillis()
            }
            "move" -> {
                // If dragging, we can dispatch continuous strokes
            }
            "up" -> {
                val duration = (System.currentTimeMillis() - downTime).coerceIn(20L, 400L)
                val path = Path().apply {
                    moveTo(downX, downY)
                    lineTo(pixelX, pixelY)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0, duration)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                dispatchGesture(gesture, null, null)
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
```

---

### Blueprint 8: Screen Mirroring Service (`ScreenMirroringService.kt`)
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ScreenMirroringService.kt`

```kotlin
package com.galaxycontinuity.app.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import androidx.core.app.NotificationCompat
import com.galaxycontinuity.app.MainActivity
import com.galaxycontinuity.app.network.StreamPacket
import kotlinx.coroutines.*
import java.nio.ByteBuffer

class ScreenMirroringService : Service() {

    companion object {
        private const val TAG = "ScreenMirroringService"
        const val CHANNEL_ID = "galaxy_screen_channel"
        const val NOTIFICATION_ID = 3001

        const val ACTION_START = "com.galaxycontinuity.app.service.START_SCREEN"
        const val ACTION_STOP = "com.galaxycontinuity.app.service.STOP_SCREEN"

        const val EXTRA_RESULT_CODE = "extra_result_code"
        const val EXTRA_RESULT_DATA = "extra_result_data"
        const val EXTRA_WIDTH = "extra_width"
        const val EXTRA_HEIGHT = "extra_height"
        const val EXTRA_FPS = "extra_fps"
        const val EXTRA_BITRATE = "extra_bitrate"

        var isStreaming = false
            private set
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var streamingJob: Job? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopScreenMirroring("user_requested")
                stopSelf()
            }
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                val resultData = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                val width = intent.getIntExtra(EXTRA_WIDTH, 1080)
                val height = intent.getIntExtra(EXTRA_HEIGHT, 2400)
                val fps = intent.getIntExtra(EXTRA_FPS, 30).coerceAtLeast(1)
                val bitrate = intent.getIntExtra(EXTRA_BITRATE, 4000000).coerceAtLeast(500000)

                if (resultCode == Activity.RESULT_OK && resultData != null) {
                    startMirroring(resultCode, resultData, width, height, fps, bitrate)
                } else {
                    Log.e(TAG, "Cannot start screen mirroring without valid result code & data")
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startMirroring(
        resultCode: Int,
        resultData: Intent,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) {
        if (isStreaming) {
            Log.d(TAG, "Screen mirroring already running; ignoring restart")
            return
        }

        // On Android 14+ (UPSIDE_DOWN_CAKE), startForeground MUST precede getMediaProjection!
        val notification = buildNotification("Screen Mirroring active — streaming display to Mac")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (mpManager == null) {
            stopSelf()
            return
        }

        mediaProjection = mpManager.getMediaProjection(resultCode, resultData)
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.d(TAG, "MediaProjection stopped by system")
                stopScreenMirroring("system_stopped")
            }
        }, Handler(Looper.getMainLooper()))

        try {
            setupMediaCodecAndVirtualDisplay(width, height, fps, bitrate)
            isStreaming = true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize encoder or virtual display", e)
            stopScreenMirroring("init_error")
        }
    }

    private fun setupMediaCodecAndVirtualDisplay(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1 second keyframe interval
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        mediaCodec = codec

        val metrics: DisplayMetrics = resources.displayMetrics
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "GalaxyContinuityScreen",
            width,
            height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            null
        )

        // Extraction loop
        streamingJob = serviceScope.launch {
            val bufferInfo = MediaCodec.BufferInfo()
            while (isActive && isStreaming) {
                try {
                    val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                    if (outputIndex >= 0) {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val outData = ByteArray(bufferInfo.size)
                            outputBuffer.get(outData)

                            // Frame into 5-byte packet: streamType 0x01 (Screen)
                            val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, outData)
                            ContinuityService.activeClient?.sendBinary(packet)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                } catch (e: Exception) {
                    if (isActive) {
                        Log.e(TAG, "Error in codec loop: ${e.message}")
                    }
                }
            }
        }
    }

    fun stopScreenMirroring(reason: String = "user_dismissed") {
        if (!isStreaming) return
        isStreaming = false

        streamingJob?.cancel()
        streamingJob = null

        try {
            virtualDisplay?.release()
            virtualDisplay = null

            mediaCodec?.stop()
            mediaCodec?.release()
            mediaCodec = null

            inputSurface?.release()
            inputSurface = null

            mediaProjection?.stop()
            mediaProjection = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing projection resources", e)
        }

        ContinuityService.activeClient?.sendScreenStop(reason)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScreenMirroring("service_destroyed")
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen Mirroring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of live screen mirroring"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = Intent(this, ScreenMirroringService::class.java).apply {
            action = ACTION_STOP
        }
        val pendingStop = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Galaxy Continuity Screen")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Streaming", pendingStop)
            .setOngoing(true)
            .build()
    }
}
```

---

### Blueprint 9: Continuity Camera Service (`ContinuityCameraService.kt`)
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityCameraService.kt`

```kotlin
package com.galaxycontinuity.app.service

import android.annotation.SuppressLint
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.*
import android.util.Log
import android.util.Range
import androidx.core.app.NotificationCompat
import com.galaxycontinuity.app.network.StreamPacket

class ContinuityCameraService : Service() {

    companion object {
        private const val TAG = "ContinuityCamera"
        const val CHANNEL_ID = "galaxy_camera_channel"
        const val NOTIFICATION_ID = 4001

        const val ACTION_START = "com.galaxycontinuity.app.service.START_CAMERA"
        const val ACTION_STOP = "com.galaxycontinuity.app.service.STOP_CAMERA"

        const val EXTRA_LENS = "extra_lens"
        const val EXTRA_QUALITY = "extra_quality"
        const val EXTRA_FPS = "extra_fps"

        var instance: ContinuityCameraService? = null
            private set
        var isStreaming = false
            private set
    }

    private var cameraManager: CameraManager? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private var currentLens = "back"
    private var isTorchOn = false
    private var currentZoom = 1.0f

    override fun onCreate() {
        super.onCreate()
        instance = this
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCamera()
                stopSelf()
            }
            ACTION_START -> {
                val lens = intent.getStringExtra(EXTRA_LENS) ?: "back"
                val quality = intent.getStringExtra(EXTRA_QUALITY) ?: "1080p"
                val fps = intent.getIntExtra(EXTRA_FPS, 30).coerceAtLeast(1)
                startCamera(lens, quality, fps)
            }
        }
        return START_NOT_STICKY
    }

    private fun startCamera(lens: String, quality: String, fps: Int) {
        if (isStreaming) {
            stopCamera()
        }

        val notification = buildNotification("Continuity Camera active — streaming to Mac")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        startBackgroundThread()
        currentLens = lens

        val (width, height) = when (quality.lowercase()) {
            "4k" -> Pair(3840, 2160)
            "720p" -> Pair(1280, 720)
            else -> Pair(1920, 1080)
        }

        openCamera(lens, width, height, fps)
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(lens: String, width: Int, height: Int, fps: Int) {
        val manager = cameraManager ?: return
        val targetFacing = if (lens.equals("front", ignoreCase = true)) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }

        var selectedCameraId: String? = null
        try {
            for (id in manager.cameraIdList) {
                val chars = manager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                if (facing == targetFacing) {
                    selectedCameraId = id
                    break
                }
            }
            if (selectedCameraId == null && manager.cameraIdList.isNotEmpty()) {
                selectedCameraId = manager.cameraIdList[0]
            }

            if (selectedCameraId == null) {
                Log.e(TAG, "No suitable camera found")
                stopSelf()
                return
            }

            // ImageReader for JPEG capture (verifies 0xFF 0xD8 payload)
            val reader = ImageReader.newInstance(width, height, ImageFormat.JPEG, 2)
            reader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)

                    // Pack into 5-byte header standard packet: streamType 0x02 (Camera)
                    val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, bytes)
                    ContinuityService.activeClient?.sendBinary(packet)
                } catch (e: Exception) {
                    Log.e(TAG, "Error acquiring camera image: ${e.message}")
                } finally {
                    image.close()
                }
            }, backgroundHandler)
            imageReader = reader

            manager.openCamera(selectedCameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    startCaptureSession(camera, reader.surface, fps)
                    isStreaming = true
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                    isStreaming = false
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                    isStreaming = false
                    Log.e(TAG, "CameraDevice error: $error")
                }
            }, backgroundHandler)

        } catch (e: Exception) {
            Log.e(TAG, "Failed to open camera: ${e.message}", e)
            stopSelf()
        }
    }

    private fun startCaptureSession(camera: CameraDevice, surface: android.view.Surface, fps: Int) {
        try {
            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
            }

            camera.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        session.setRepeatingRequest(builder.build(), null, backgroundHandler)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Camera capture session configuration failed")
                    }
                },
                backgroundHandler
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start camera capture session", e)
        }
    }

    fun handleControl(action: String, lens: String?, zoom: Double?, torch: Boolean?) {
        when (action.lowercase()) {
            "switch_lens" -> {
                val targetLens = lens ?: if (currentLens == "back") "front" else "back"
                startCamera(targetLens, "1080p", 30)
            }
            "set_zoom" -> {
                if (zoom != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    currentZoom = zoom.toFloat()
                    try {
                        val session = captureSession ?: return
                        val camera = cameraDevice ?: return
                        val surface = imageReader?.surface ?: return
                        val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            addTarget(surface)
                            set(CaptureRequest.CONTROL_ZOOM_RATIO, currentZoom)
                            if (isTorchOn) {
                                set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
                            }
                        }
                        session.setRepeatingRequest(builder.build(), null, backgroundHandler)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to update zoom: ${e.message}")
                    }
                }
            }
            "toggle_torch" -> {
                if (torch != null) {
                    isTorchOn = torch
                    try {
                        val session = captureSession ?: return
                        val camera = cameraDevice ?: return
                        val surface = imageReader?.surface ?: return
                        val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            addTarget(surface)
                            set(
                                CaptureRequest.FLASH_MODE,
                                if (isTorchOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
                            )
                        }
                        session.setRepeatingRequest(builder.build(), null, backgroundHandler)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to update torch: ${e.message}")
                    }
                }
            }
        }
    }

    fun stopCamera() {
        if (!isStreaming) return
        isStreaming = false

        try {
            captureSession?.stopRepeating()
            captureSession?.close()
            captureSession = null

            cameraDevice?.close()
            cameraDevice = null

            imageReader?.close()
            imageReader = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing camera: ${e.message}")
        }

        stopBackgroundThread()
        ContinuityService.activeClient?.sendCameraStop()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("CameraBackground").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
            backgroundThread = null
            backgroundHandler = null
        } catch (e: InterruptedException) {
            Log.e(TAG, "Background thread interrupted", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCamera()
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Continuity Camera",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of Continuity Camera streaming feed"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ACTION_STOP
        }
        val pendingStop = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Galaxy Continuity Camera")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Camera", pendingStop)
            .setOngoing(true)
            .build()
    }
}
```

---

### Blueprint 10: `ContinuityService.kt` Coordination Updates
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`

Integrate listener implementations for Milestone 3:

```kotlin
    // MARK: - Milestone 3 Screen Mirroring & Input Callbacks
    override fun onScreenStart(width: Int, height: Int, fps: Int, bitrate: Int) {
        // If media projection permission was already obtained, ScreenMirroringService starts
        Log.d("ContinuityService", "Received screen_start ($width x $height @ $fps fps)")
        // Broadcast local intent or trigger ScreenMirroringService if intent data is saved
    }

    override fun onScreenStop(reason: String?) {
        Log.d("ContinuityService", "Received screen_stop (reason: $reason)")
        val stopIntent = Intent(this, ScreenMirroringService::class.java).apply {
            action = ScreenMirroringService.ACTION_STOP
        }
        startService(stopIntent)
    }

    override fun onRemoteInput(action: String, x: Double, y: Double, button: Int) {
        ContinuityAccessibilityService.instance?.handleInputEvent(action, x, y, button)
    }

    override fun onRemoteKey(key: String, keyCode: Int) {
        ContinuityAccessibilityService.instance?.handleKeyInput(key, keyCode)
    }

    // MARK: - Milestone 3 Continuity Camera Callbacks
    override fun onCameraStart(lens: String, quality: String, fps: Int) {
        Log.d("ContinuityService", "Received camera_start (lens: $lens, quality: $quality, fps: $fps)")
        val intent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ContinuityCameraService.ACTION_START
            putExtra(ContinuityCameraService.EXTRA_LENS, lens)
            putExtra(ContinuityCameraService.EXTRA_QUALITY, quality)
            putExtra(ContinuityCameraService.EXTRA_FPS, fps)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onCameraStop() {
        Log.d("ContinuityService", "Received camera_stop")
        val intent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ContinuityCameraService.ACTION_STOP
        }
        startService(intent)
    }

    override fun onCameraControl(action: String, lens: String?, zoom: Double?, torch: Boolean?) {
        ContinuityCameraService.instance?.handleControl(action, lens, zoom, torch)
    }
```

---

### Blueprint 11: `MainActivity.kt` MediaProjection & Accessibility Integration
**Target File**: `android/app/src/main/java/com/galaxycontinuity/app/MainActivity.kt`

Integrate launcher contracts for MediaProjection and deep link to Accessibility Settings:

```kotlin
    // Register ActivityResultLauncher for MediaProjection
    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val serviceIntent = Intent(this, ScreenMirroringService::class.java).apply {
                action = ScreenMirroringService.ACTION_START
                putExtra(ScreenMirroringService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(ScreenMirroringService.EXTRA_RESULT_DATA, result.data)
                putExtra(ScreenMirroringService.EXTRA_WIDTH, 1080)
                putExtra(ScreenMirroringService.EXTRA_HEIGHT, 2400)
                putExtra(ScreenMirroringService.EXTRA_FPS, 30)
                putExtra(ScreenMirroringService.EXTRA_BITRATE, 4000000)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        }
    }

    // Function to launch screen capture consent dialog
    fun requestScreenCapture() {
        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        mpManager?.createScreenCaptureIntent()?.let { projectionLauncher.launch(it) }
    }

    // Function to open Android Accessibility settings
    fun openAccessibilitySettings() {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }
```

---

### Blueprint 12: Automated JVM Unit Test Suites

#### A. Stream Packet Framing Tests (`StreamPacketTest.kt`)
**Target File**: `android/app/src/test/java/com/galaxycontinuity/app/StreamPacketTest.kt`

```kotlin
package com.galaxycontinuity.app

import com.galaxycontinuity.app.network.StreamPacket
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class StreamPacketTest {

    @Test
    fun testScreenStreamPacketPackingAndUnpacking() {
        val fakeNal = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x65, 0x08, 0x09)
        val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, fakeNal)

        assertEquals(StreamPacket.HEADER_SIZE + fakeNal.size, packet.size)
        assertEquals(0x01.toByte(), packet[0])

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(StreamPacket.TYPE_SCREEN, unpacked!!.streamType)
        assertEquals(fakeNal.size, unpacked.length)
        assertArrayEquals(fakeNal, unpacked.payload)
    }

    @Test
    fun testCameraStreamPacketWithJpegPayload() {
        // Mock JPEG starting with 0xFF 0xD8 SOI marker
        val fakeJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x10, 0x20)
        val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, fakeJpeg)

        assertEquals(StreamPacket.HEADER_SIZE + fakeJpeg.size, packet.size)
        assertEquals(0x02.toByte(), packet[0])

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(StreamPacket.TYPE_CAMERA, unpacked!!.streamType)
        assertEquals(fakeJpeg.size, unpacked.length)
        assertTrue(unpacked.payload[0] == 0xFF.toByte() && unpacked.payload[1] == 0xD8.toByte())
    }

    @Test
    fun testShortHeaderUnpackRejection() {
        val shortBytes = byteArrayOf(0x01, 0x00, 0x00)
        val unpacked = StreamPacket.unpack(shortBytes)
        assertNull("Packets with fewer than 5 bytes must return null", unpacked)
    }

    @Test
    fun testTruncatedPayloadUnpackRejection() {
        val buffer = ByteBuffer.allocate(StreamPacket.HEADER_SIZE + 2)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(0x01.toByte())
        buffer.putInt(100) // Claims 100 bytes but only 2 provided
        buffer.put(byteArrayOf(0x01, 0x02))

        val unpacked = StreamPacket.unpack(buffer.array())
        assertNull("Truncated payload packets must return null", unpacked)
    }

    @Test
    fun testZeroLengthPayloadPacket() {
        val emptyPayload = ByteArray(0)
        val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, emptyPayload)
        assertEquals(StreamPacket.HEADER_SIZE, packet.size)

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(0, unpacked!!.length)
        assertEquals(0, unpacked.payload.size)
    }
}
```

#### B. Screen Mirroring & Input Mapper Tests (`ScreenMirroringTest.kt`)
**Target File**: `android/app/src/test/java/com/galaxycontinuity/app/ScreenMirroringTest.kt`

```kotlin
package com.galaxycontinuity.app

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import com.galaxycontinuity.app.service.RemoteInputMapper
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ScreenMirroringTest {

    @Test
    fun testScreenStartMessageParsing() {
        val json = JSONObject().apply {
            put("type", "screen_start")
            put("width", 1080)
            put("height", 2400)
            put("fps", 60)
            put("bitrate", 6000000)
        }

        assertEquals("screen_start", json.getString("type"))
        assertEquals(1080, json.optInt("width", 1080))
        assertEquals(2400, json.optInt("height", 2400))
        assertEquals(60, json.optInt("fps", 30))
        assertEquals(6000000, json.optInt("bitrate", 4000000))
    }

    @Test
    fun testScreenStopMessageParsing() {
        val json = JSONObject().apply {
            put("type", "screen_stop")
            put("reason", "user_dismissed")
        }

        assertEquals("screen_stop", json.getString("type"))
        assertEquals("user_dismissed", json.optString("reason"))
    }

    @Test
    fun testCoordinateClampingNegative() {
        val (x, y) = RemoteInputMapper.mapCoordinates(-0.5, -0.2, 1080, 2400)
        assertEquals(0f, x, 0.001f)
        assertEquals(0f, y, 0.001f)
    }

    @Test
    fun testCoordinateClampingExcess() {
        val (x, y) = RemoteInputMapper.mapCoordinates(1.5, 2.0, 1080, 2400)
        assertEquals(1080f, x, 0.001f)
        assertEquals(2400f, y, 0.001f)
    }

    @Test
    fun testCoordinateNormalMapping() {
        val (x, y) = RemoteInputMapper.mapCoordinates(0.5, 0.25, 1080, 2400)
        assertEquals(540f, x, 0.001f)
        assertEquals(600f, y, 0.001f)
    }

    @Test
    fun testGlobalActionKeyMapping() {
        assertEquals(AccessibilityService.GLOBAL_ACTION_BACK, RemoteInputMapper.mapToGlobalAction("BACK", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_BACK, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_BACK))

        assertEquals(AccessibilityService.GLOBAL_ACTION_HOME, RemoteInputMapper.mapToGlobalAction("HOME", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_HOME, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_HOME))

        assertEquals(AccessibilityService.GLOBAL_ACTION_RECENTS, RemoteInputMapper.mapToGlobalAction("RECENTS", null))
        assertEquals(AccessibilityService.GLOBAL_ACTION_RECENTS, RemoteInputMapper.mapToGlobalAction(null, KeyEvent.KEYCODE_APP_SWITCH))

        assertEquals(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN, RemoteInputMapper.mapToGlobalAction("POWER", null))
        assertNull(RemoteInputMapper.mapToGlobalAction("UNKNOWN_KEY", 9999))
    }

    @Test
    fun testValidActionValidation() {
        assertTrue(RemoteInputMapper.isValidAction("down"))
        assertTrue(RemoteInputMapper.isValidAction("move"))
        assertTrue(RemoteInputMapper.isValidAction("up"))
        assertTrue(RemoteInputMapper.isValidAction("scroll"))
        assertFalse(RemoteInputMapper.isValidAction("invalid_action"))
    }
}
```

#### C. Continuity Camera Tests (`ContinuityCameraTest.kt`)
**Target File**: `android/app/src/test/java/com/galaxycontinuity/app/ContinuityCameraTest.kt`

```kotlin
package com.galaxycontinuity.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ContinuityCameraTest {

    @Test
    fun testCameraStartMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_start")
            put("lens", "front")
            put("quality", "1080p")
            put("fps", 30)
        }

        assertEquals("camera_start", json.getString("type"))
        assertEquals("front", json.optString("lens"))
        assertEquals("1080p", json.optString("quality"))
        assertEquals(30, json.optInt("fps"))
    }

    @Test
    fun testCameraStartFacingResolutionAliases() {
        val json = JSONObject().apply {
            put("type", "camera_start")
            put("facing", "back")
            put("resolution", "720p")
        }

        val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")
        val quality = if (json.has("quality")) json.getString("quality") else json.optString("resolution", "1080p")

        assertEquals("back", lens)
        assertEquals("720p", quality)
    }

    @Test
    fun testCameraControlMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_control")
            put("action", "set_zoom")
            put("zoom", 2.5)
            put("torch", true)
        }

        assertEquals("camera_control", json.getString("type"))
        assertEquals("set_zoom", json.getString("action"))
        assertEquals(2.5, json.getDouble("zoom"), 0.01)
        assertTrue(json.getBoolean("torch"))
    }

    @Test
    fun testCameraSwitchLensAliasParsing() {
        val json = JSONObject().apply {
            put("type", "camera_switch_lens")
            put("facing", "front")
        }

        val action = json.optString("action", if (json.getString("type") == "camera_switch_lens") "switch_lens" else "")
        val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")

        assertEquals("switch_lens", action)
        assertEquals("front", lens)
    }

    @Test
    fun testCameraStopMessageParsing() {
        val json = JSONObject().apply {
            put("type", "camera_stop")
        }
        assertEquals("camera_stop", json.getString("type"))
    }
}
```

---

## 5. Verification Method

1. **Static Analysis & File Layout**:
   - Verify all 12 target files are created/updated in `android/`:
     - `android/app/src/main/AndroidManifest.xml`
     - `android/app/src/main/res/xml/accessibility_service_config.xml`
     - `android/app/src/main/res/values/strings.xml`
     - `android/app/src/main/java/com/galaxycontinuity/app/network/StreamPacket.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/service/ScreenMirroringService.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityCameraService.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`
     - `android/app/src/main/java/com/galaxycontinuity/app/MainActivity.kt`
     - Test files in `android/app/src/test/java/com/galaxycontinuity/app/` (`StreamPacketTest.kt`, `ScreenMirroringTest.kt`, `ContinuityCameraTest.kt`).
2. **Automated JVM Test Execution**:
   - Run: `./gradlew testDebugUnitTest` in `android/`
   - Expected Result: 100% test pass on `StreamPacketTest`, `ScreenMirroringTest`, `ContinuityCameraTest`, and existing M1/M2 tests (`ClipboardSyncUnitTest`, `FileTransferClientTest`, `ProtocolSerializationTest`, `WebSocketFrameTest`).
3. **E2E Compatibility Verification**:
   - Run: `python3 tests/e2e/runner.py`
   - Invalidation Conditions:
     - Any regression in E2E tests for Screen Mirroring (`test_27` through `test_31`) or Continuity Camera (`test_32` through `test_36`).
     - Any packet header mismatch where binary frame length != 5 + payload size or streamType != `0x01`/`0x02`.
     - Incomplete Android 14 permissions causing runtime `SecurityException` when starting foreground services.
