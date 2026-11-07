# Dispatch: Worker M1 (Architecture & Test Harness Implementation)

You are `worker_m1` (`teamwork_worker`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, contracts, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (complete protocol specification)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_explorer_1/handoff.md` (macOS target and test exploration)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_explorer_2/handoff.md` (Android Gradle wrapper, signing & test setup)

## Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Write Ownership Boundaries
- `mac/Package.swift`, `mac/Sources/**`, `mac/Tests/**`
- `android/gradle/**`, `android/gradlew`, `android/gradlew.bat`, `android/app/build.gradle.kts`, `android/app/src/test/**`
- `.agents/teamwork/worker_m1/**`
- DO NOT touch `tests/e2e/**`.

## Tasks

### 1. macOS Package & Test Targets (`mac/`)
- Ensure `mac/Package.swift` defines:
  - Library `GalaxyContinuityKit` (`Sources/GalaxyContinuityKit`)
  - Executable `GalaxyContinuity` (`Sources/GalaxyContinuity`, depending on `GalaxyContinuityKit`)
  - Test target `GalaxyContinuityTests` (`Tests/GalaxyContinuityTests`, depending on `GalaxyContinuityKit`)
- Fix `mac/Tests/GalaxyContinuityTests/HandshakeTests.swift`:
  - Ensure `import XCTest` is present and tests compile cleanly.
- Add `mac/Tests/GalaxyContinuityTests/WebSocketFramerTests.swift`:
  - Unit tests for `WebSocketFramer`: 7-bit, 16-bit, 64-bit frame lengths, masking/unmasking, opcode handling.
- Verify `swift build` and `swift test` succeed with exit code 0.

### 2. Android Gradle Wrapper, Signing & Test Harness (`android/`)
- Provision Gradle wrapper 8.5:
  - Download or provision `android/gradlew` (chmod +x, 0755) from `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew`
  - Provision `android/gradlew.bat` from `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradlew.bat`
  - Provision `android/gradle/wrapper/gradle-wrapper.jar` from `https://raw.githubusercontent.com/gradle/gradle/v8.5.0/gradle/wrapper/gradle-wrapper.jar` (verify SHA-256: `d3b261c2820e9e3d8d639ed084900f11f4a86050a8f83342ade7b6bc9b0d2bdd`)
  - Update `android/gradle/wrapper/gradle-wrapper.properties` to target `gradle-8.5-bin.zip`.
- Configure `android/app/build.gradle.kts`:
  - Add `signingConfigs` block:
    ```kotlin
    signingConfigs {
        create("release") {
            initWith(signingConfigs.getByName("debug"))
        }
    }
    ```
  - Attach `signingConfig = signingConfigs.getByName("release")` to `buildTypes.release`.
  - Enable `testOptions { unitTests.isReturnDefaultValues = true }`.
  - Add test dependencies:
    ```kotlin
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20231013")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    ```
- Create unit tests under `android/app/src/test/java/com/galaxycontinuity/app/`:
  - `ProtocolSerializationTest.kt`: Unit tests verifying JSON serialization and deserialization of protocol messages (handshake, clipboard, quick drop, screen mirroring, camera, notifications) matching `shared/PROTOCOL.md`.
  - `WebSocketFrameTest.kt`: Unit tests verifying message payload construction.
- Verify wrapper executable bit (`test -x android/gradlew`) and jar sha256.

### 3. Verification & Handoff
- Document all modified and created files.
- Run `swift build` and `swift test` in `mac/`, include full test output in handoff.
- Write handoff report to `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1/handoff.md`.
- Notify parent upon completion via `send_message`.


## 2026-11-07T09:27:10Z
From: 67ae80cb-3237-4127-adab-613c0f12f1aa
Content: You are worker_m1. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1/DISPATCH.md and execute the tasks. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Implement the macOS package & test targets, the Android Gradle wrapper, signing & test harness. Run swift build and swift test. Document all changes and test outputs in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m1/handoff.md and notify your parent via send_message when complete.
