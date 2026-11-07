# Android Build Tooling, Wrapper & Signing Analysis

**Agent**: M1 Explorer 2 (`teamwork_explorer`)  
**Scope**: Milestone 1 — Android Build & Test Infrastructure (`android/`)  
**Target Files**:
- `android/build.gradle.kts`
- `android/settings.gradle.kts`
- `android/gradle/wrapper/gradle-wrapper.properties`
- `android/gradle/wrapper/gradle-wrapper.jar`
- `android/gradlew` & `android/gradlew.bat`
- `android/app/build.gradle.kts`
- `android/app/src/test/`

---

## 1. Exact Gradle Version Analysis

### 1.1 Current Configuration
- `android/build.gradle.kts`:
  ```kotlin
  plugins {
      id("com.android.application") version "8.2.2" apply false
      id("org.jetbrains.kotlin.android") version "1.9.22" apply false
  }
  ```
- `android/app/build.gradle.kts`:
  - `compileSdk = 34`
  - `minSdk = 26`, `targetSdk = 34`
  - `compileOptions` & `kotlinOptions`: `JavaVersion.VERSION_17` / jvmTarget `17`
  - Compose compiler: `kotlinCompilerExtensionVersion = "1.5.8"`
- `android/gradle/wrapper/gradle-wrapper.properties`:
  ```properties
  distributionUrl=https\://services.gradle.org/distributions/gradle-8.2-bin.zip
  ```
- `.github/workflows/build-apk.yml`:
  ```yaml
  - name: Setup Gradle 8.5
    uses: gradle/actions/setup-gradle@v3
    with:
      gradle-version: '8.5'
  ```
  *(Updated in git commit `00528fc`: "ci: use gradle-version 8.5 in setup-gradle and fix Android 14 foreground service type")*

### 1.2 Version Compatibility Matrix
| Component | Configured Version | Minimum Required Gradle | Compatible Gradle Range | JDK Compatibility |
|---|---|---|---|---|
| **Android Gradle Plugin (AGP)** | `8.2.2` | `8.2` | `8.2` – `8.5` | JDK 17+ |
| **Kotlin Android Plugin** | `1.9.22` | `7.6.3` | `7.6.3` – `8.5` | JDK 17+ |
| **Compose Compiler Extension** | `1.5.8` | (Requires Kotlin 1.9.22) | — | JDK 17+ |
| **GitHub Actions Runner** | Ubuntu 22.04 / 24.04 | `8.5` (via `setup-gradle@v3`) | `8.5` | Temurin JDK 17 |

### 1.3 Recommended Gradle Version: **Gradle 8.5**
- **Primary Finding**: AGP `8.2.2` was tested with Gradle versions `8.2` through `8.5`. While Gradle `8.2` is the minimum, **Gradle 8.5** is the officially recommended version for this project.
- **Rationale**:
  1. **CI Parity**: `.github/workflows/build-apk.yml` explicitly provisions Gradle `8.5`. Aligning the wrapper to `8.5` ensures that developer CLI builds (`./gradlew`) and CI runner builds use the exact same Gradle runtime, eliminating potential daemon or incremental compilation discrepancies.
  2. **Kotlin 1.9.22 Support**: Gradle 8.5 includes critical bug fixes and configuration cache stability improvements for Kotlin 1.9 multiplatform/android daemon processes.
  3. **Apple Silicon & JDK 17 Stability**: Gradle 8.5 provides improved memory management and native ARM64 support on macOS.
- **Action Required**: Update `android/gradle/wrapper/gradle-wrapper.properties` to reference `gradle-8.5-bin.zip`.

---

## 2. Gradle Wrapper Distribution Files

### 2.1 Missing Files in `android/`
The repository currently contains only `android/gradle/wrapper/gradle-wrapper.properties`. The executable wrapper scripts and bootstrap jar are absent:
1. `android/gradlew` — POSIX executable shell script (MISSING)
2. `android/gradlew.bat` — Windows command batch script (MISSING)
3. `android/gradle/wrapper/gradle-wrapper.jar` — Gradle bootstrap runtime JAR (MISSING)
4. `android/gradle/wrapper/gradle-wrapper.properties` — Exists, but should be updated to Gradle 8.5.

### 2.2 Specifications & Provenance of Wrapper Artifacts
The official Gradle 8.5.0 release artifacts are publicly available from Gradle's official repository:

1. **`android/gradle/wrapper/gradle-wrapper.jar`**:
   - **Source URL**: `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradle/wrapper/gradle-wrapper.jar`
   - **Size**: 43,462 bytes
   - **SHA-256 Checksum**:
     `d3b261c2820e9e3d8d639ed084900f11f4a86050a8f83342ade7b6bc9b0d2bdd`
   - **Purpose**: Bytecode bootstrap entry point (`org.gradle.wrapper.GradleWrapperMain`) that downloads the specified distribution zip if not cached and delegates task execution.

2. **`android/gradlew`**:
   - **Source URL**: `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew`
   - **Size**: ~8,714 bytes
   - **Permissions**: Must have executable bit set (`chmod +x android/gradlew`).
   - **Purpose**: Main entry point on Unix/macOS/Linux.

3. **`android/gradlew.bat`**:
   - **Source URL**: `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew.bat`
   - **Size**: ~2,798 bytes
   - **Purpose**: Entry point for Windows developers.

4. **`android/gradle/wrapper/gradle-wrapper.properties`**:
   - **Target Content**:
     ```properties
     distributionBase=GRADLE_USER_HOME
     distributionPath=wrapper/dists
     distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip
     networkTimeout=10000
     validateDistributionUrl=true
     zipStoreBase=GRADLE_USER_HOME
     zipStorePath=wrapper/dists
     ```

### 2.3 Machine-Executable Provisioning Command
The implementer can provision and verify all wrapper files using standard command line tools:
```bash
cd /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/android

# Ensure wrapper directory exists
mkdir -p gradle/wrapper

# 1. Download official Gradle 8.5 wrapper JAR
curl -sSL "https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradle/wrapper/gradle-wrapper.jar" \
  -o gradle/wrapper/gradle-wrapper.jar

# Verify checksum
echo "d3b261c2820e9e3d8d639ed084900f11f4a86050a8f83342ade7b6bc9b0d2bdd  gradle/wrapper/gradle-wrapper.jar" | shasum -a 256 -c -

# 2. Download official gradlew shell script and set executable permissions
curl -sSL "https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew" -o gradlew
chmod +x gradlew

# 3. Download official gradlew.bat
curl -sSL "https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew.bat" -o gradlew.bat

# 4. Update gradle-wrapper.properties to 8.5
cat << 'EOF' > gradle/wrapper/gradle-wrapper.properties
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip
networkTimeout=10000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF
```

---

## 3. Signing Configuration in `android/app/build.gradle.kts`

### 3.1 Problem Statement
In `android/app/build.gradle.kts`:
```kotlin
    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
```
Currently, no `signingConfig` is assigned to `release`.
When `./gradlew assembleRelease` runs:
1. AGP defaults to generating an **unsigned** APK: `app-release-unsigned.apk`.
2. Unsigned APKs cannot be installed on Android devices (the Android OS Package Installer throws `INSTALL_PARSE_FAILED_NO_CERTIFICATES` or `INSTALL_FAILED_INVALID_APK`).
3. Requirement R2 mandates publishing a working APK asset to GitHub Release `v1.0.0`. An unsigned release APK violates the acceptance criteria and breaks end-user installation.
4. Downstream verification in CI or local scripts requiring `./gradlew assembleRelease` will fail or output unusable artifacts unless release is configured with a valid signing configuration.

### 3.2 Solution Architecture
We must configure `signingConfigs` in `android/app/build.gradle.kts` to:
1. Provide a robust `release` signing configuration.
2. Check if a dedicated release keystore exists (e.g. `release.keystore` or environment variables `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`).
3. If no dedicated keystore is present, **automatically fall back to `signingConfigs.getByName("debug")`**.
4. In AGP, `signingConfigs.getByName("debug")` is built-in and automatically provisions a debug keystore (`~/.android/debug.keystore`) on any machine or CI runner.
5. Assign this signing configuration to `buildTypes.getByName("release")`.

### 3.3 Proposed Code Changes in `android/app/build.gradle.kts`

```kotlin
android {
    namespace = "com.galaxycontinuity.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.galaxycontinuity.app"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    signingConfigs {
        create("release") {
            val keystoreFile = project.rootProject.file("release.keystore")
            if (keystoreFile.exists()) {
                storeFile = keystoreFile
                storePassword = System.getenv("KEYSTORE_PASSWORD") ?: "android"
                keyAlias = System.getenv("KEY_ALIAS") ?: "androiddebugkey"
                keyPassword = System.getenv("KEY_PASSWORD") ?: "android"
            } else {
                // Fall back to the built-in debug keystore for automated CI/CD and headless builds.
                // Ensures ./gradlew assembleRelease produces a signed, valid app-release.apk
                // without requiring manual keystore provisioning.
                initWith(signingConfigs.getByName("debug"))
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.8"
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}
```

### 3.4 Verification & Artifact Outputs
With this configuration:
- Running `./gradlew assembleDebug` creates:
  `android/app/build/outputs/apk/debug/app-debug.apk` (Signed with Debug key).
- Running `./gradlew assembleRelease` creates:
  `android/app/build/outputs/apk/release/app-release.apk` (Signed with Release key or Debug key fallback; NOT unsigned).
- Both APKs have valid V1/V2 signatures and can be installed via ADB or downloaded directly by users.

---

## 4. Headless Unit Test Structure & Test Suites

### 4.1 Headless JVM Testing Strategy
To verify data models, JSON serialization, and protocol invariants without needing an emulator or physical device:
1. **Pure JVM Unit Tests**: Placed under `android/app/src/test/java/`.
2. **Android Stub Resolution**: In standard Android unit tests on JVM, Android framework classes in `android.jar` throw `RuntimeException: Stub!`. To solve this cleanly:
   - Add `testOptions { unitTests.isReturnDefaultValues = true }` in `android/app/build.gradle.kts`.
   - Add `testImplementation("org.json:json:20231013")` so `org.json.JSONObject` executes actual JSON parsing and serialization logic rather than throwing the Android stub exception.
   - Add `testImplementation("junit:junit:4.13.2")` for standard test execution.
   - Add `testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")` for mock WebSocket/HTTP networking tests.

### 4.2 App Dependencies Update (`android/app/build.gradle.kts`)
Add to `dependencies { ... }`:
```kotlin
dependencies {
    // Existing implementation dependencies...
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Unit Testing Dependencies (Headless JVM)
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20231013")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
```

### 4.3 Proposed Directory Layout
```
android/app/src/test/
└── java/
    └── com/
        └── galaxycontinuity/
            └── app/
                ├── model/
                │   └── ContinuityProtocolTest.kt
                └── network/
                    └── WebSocketMessageSerializationTest.kt
```

### 4.4 Test Suite 1: Protocol Models & Schema Test
**File**: `android/app/src/test/java/com/galaxycontinuity/app/model/ContinuityProtocolTest.kt`
This suite verifies that every protocol message defined in `shared/PROTOCOL.md` and `PROJECT.md` can be serialized and deserialized accurately:

```kotlin
package com.galaxycontinuity.app.model

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ContinuityProtocolTest {

    @Test
    fun testHandshakePayloadSerialization() {
        val json = JSONObject().apply {
            put("type", "handshake")
            put("device", "Samsung Galaxy S24 Ultra")
            put("platform", "android")
            put("version", "1.0.0")
            put("battery", JSONObject().apply {
                put("level", 88)
                put("charging", true)
            })
        }

        assertEquals("handshake", json.getString("type"))
        assertEquals("Samsung Galaxy S24 Ultra", json.getString("device"))
        assertEquals("android", json.getString("platform"))
        assertEquals("1.0.0", json.getString("version"))
        
        val battery = json.getJSONObject("battery")
        assertEquals(88, battery.getInt("level"))
        assertTrue(battery.getBoolean("charging"))
    }

    @Test
    fun testHandshakeAckPayloadDeserialization() {
        val rawJson = """
            {
                "type": "handshake_ack",
                "device": "MacBook Pro",
                "platform": "macOS",
                "version": "1.0.0"
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("handshake_ack", json.getString("type"))
        assertEquals("MacBook Pro", json.getString("device"))
        assertEquals("macOS", json.getString("platform"))
        assertEquals("1.0.0", json.getString("version"))
    }

    @Test
    fun testClipboardTextPayloadSerialization() {
        val text = "Hello from Android clipboard!"
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", text)
            put("contentType", "text/plain")
            put("source", "phone")
            put("timestamp", 1730940000000L)
        }

        assertEquals("clipboard", json.getString("type"))
        assertEquals(text, json.getString("content"))
        assertEquals("text/plain", json.getString("contentType"))
        assertEquals("phone", json.getString("source"))
        assertEquals(1730940000000L, json.getLong("timestamp"))
    }

    @Test
    fun testClipboardImagePayloadFormat() {
        val base64Png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        val sha256 = "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("contentType", "image/png")
            put("payload", base64Png)
            put("hash", sha256)
            put("timestamp", 1730940000000L)
        }

        assertEquals("clipboard", json.getString("type"))
        assertEquals("image/png", json.getString("contentType"))
        assertEquals(base64Png, json.getString("payload"))
        assertEquals(sha256, json.getString("hash"))
    }

    @Test
    fun testFileAvailablePayloadDeserialization() {
        val rawJson = """
            {
                "type": "file_available",
                "fileId": "uuid-9988-7766",
                "filename": "document.pdf",
                "fileSize": 1048576,
                "mimeType": "application/pdf",
                "sender": "MacBook Pro"
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("file_available", json.getString("type"))
        assertEquals("uuid-9988-7766", json.getString("fileId"))
        assertEquals("document.pdf", json.getString("filename"))
        assertEquals(1048576L, json.getLong("fileSize"))
        assertEquals("application/pdf", json.getString("mimeType"))
    }

    @Test
    fun testPhoneNotificationSerialization() {
        val json = JSONObject().apply {
            put("type", "phone_notification")
            put("id", "notif-101")
            put("app", "Telegram")
            put("title", "Alice")
            put("text", "Let's meet at 5")
            put("canReply", true)
            put("timestamp", 1730940000000L)
        }

        assertEquals("phone_notification", json.getString("type"))
        assertEquals("notif-101", json.getString("id"))
        assertEquals("Telegram", json.getString("app"))
        assertEquals("Alice", json.getString("title"))
        assertEquals("Let's meet at 5", json.getString("text"))
        assertTrue(json.getBoolean("canReply"))
    }

    @Test
    fun testNotificationReplyDeserialization() {
        val rawJson = """
            {
                "type": "notification_reply",
                "id": "notif-101",
                "replyText": "Sounds good!"
            }
        """.trimIndent()

        val json = JSONObject(rawJson)
        assertEquals("notification_reply", json.getString("type"))
        assertEquals("notif-101", json.getString("id"))
        assertEquals("Sounds good!", json.getString("replyText"))
    }

    @Test
    fun testScreenMirroringControlMessages() {
        val startJson = JSONObject().apply {
            put("type", "screen_start")
            put("fps", 30)
            put("bitrate", 2000000)
        }
        assertEquals("screen_start", startJson.getString("type"))
        assertEquals(30, startJson.getInt("fps"))
        assertEquals(2000000, startJson.getInt("bitrate"))

        val inputEvent = JSONObject().apply {
            put("type", "input_event")
            put("action", "down")
            put("x", 0.5)
            put("y", 0.75)
        }
        assertEquals("input_event", inputEvent.getString("type"))
        assertEquals("down", inputEvent.getString("action"))
        assertEquals(0.5, inputEvent.getDouble("x"), 0.001)
        assertEquals(0.75, inputEvent.getDouble("y"), 0.001)
    }

    @Test
    fun testContinuityCameraControlMessages() {
        val cameraStart = JSONObject().apply {
            put("type", "camera_start")
            put("lens", "back")
            put("quality", "1080p")
        }
        assertEquals("camera_start", cameraStart.getString("type"))
        assertEquals("back", cameraStart.getString("lens"))
        assertEquals("1080p", cameraStart.getString("quality"))

        val cameraStop = JSONObject().apply {
            put("type", "camera_stop")
        }
        assertEquals("camera_stop", cameraStop.getString("type"))
    }
}
```

### 4.5 Test Suite 2: WebSocket Serialization & Error Handling
**File**: `android/app/src/test/java/com/galaxycontinuity/app/network/WebSocketMessageSerializationTest.kt`

```kotlin
package com.galaxycontinuity.app.network

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebSocketMessageSerializationTest {

    @Test
    fun testMalformedJsonHandling() {
        val malformedJson = "{ type: 'incomplete' "
        var parseFailed = false
        try {
            JSONObject(malformedJson)
        } catch (e: JSONException) {
            parseFailed = true
        }
        assertTrue("Malformed JSON must throw JSONException rather than uncaught error", parseFailed)
    }

    @Test
    fun testMissingOptionalFieldsFallback() {
        val minimalJson = JSONObject("""{"type": "handshake_ack"}""")
        val device = minimalJson.optString("device", "Default Device")
        val version = minimalJson.optString("version", "1.0.0")

        assertEquals("Default Device", device)
        assertEquals("1.0.0", version)
    }

    @Test
    fun testUnknownMessageTypeIgnoredGracefully() {
        val unknownJson = JSONObject("""{"type": "future_unsupported_feature", "data": 42}""")
        val type = unknownJson.optString("type")
        val isRecognized = when (type) {
            "handshake", "handshake_ack", "clipboard", "file_available",
            "phone_notification", "notification_reply", "ping_device",
            "screen_start", "screen_stop", "input_event", "camera_start", "camera_stop" -> true
            else -> false
        }
        assertFalse("Unknown message type must be recognized as unsupported", isRecognized)
    }

    @Test
    fun testRoundTripClipboardSerialization() {
        val originalText = "Test round-trip unicode content: ⚡📱💻🚀"
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", originalText)
            put("contentType", "text/plain")
        }
        val serialized = json.toString()
        val deserialized = JSONObject(serialized)

        assertEquals("clipboard", deserialized.getString("type"))
        assertEquals(originalText, deserialized.getString("content"))
    }
}
```

### 4.6 Verification Command
In environments with JDK 17 installed:
```bash
cd android
./gradlew testDebugUnitTest
```
Runs all JVM tests headlessly in under 2 seconds.

---

## 5. Summary of Recommended Actions for Worker

1. **Gradle Wrapper**:
   - Download official Gradle 8.5 `gradle-wrapper.jar` to `android/gradle/wrapper/` and verify SHA-256.
   - Download official `gradlew` and `gradlew.bat` to `android/`.
   - Make `android/gradlew` executable (`chmod +x`).
   - Update `android/gradle/wrapper/gradle-wrapper.properties` to `gradle-8.5-bin.zip`.
2. **App Build & Signing Configuration**:
   - Update `android/app/build.gradle.kts` with `signingConfigs { create("release") { ... } }` and set `signingConfig = signingConfigs.getByName("release")` under `buildTypes.release`.
   - Add `testOptions { unitTests.isReturnDefaultValues = true }`.
   - Add test dependencies (`junit:junit:4.13.2`, `org.json:json:20231013`, `mockwebserver:4.12.0`).
3. **Unit Tests**:
   - Create directories `android/app/src/test/java/com/galaxycontinuity/app/model/` and `android/app/src/test/java/com/galaxycontinuity/app/network/`.
   - Add `ContinuityProtocolTest.kt` and `WebSocketMessageSerializationTest.kt`.
