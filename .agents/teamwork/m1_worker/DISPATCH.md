# Dispatch: Milestone 1 Worker (Architecture & Test Harness Enablement)

You are the Milestone 1 Implementation Worker (`teamwork_worker`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_worker`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`
Original request: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md`
Project Plan: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md`

## Input Reports to Read
1. macOS Target Refactoring: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_explorer_1/analysis.md` and `handoff.md`
2. Android Gradle & Build Setup: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_explorer_2/analysis.md` and `handoff.md`
3. Shared Protocol Specification: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_spec_miner_3/spec.md` and `handoff.md`

## Exclusive Write Ownership
You own:
- `mac/Package.swift`, `mac/Sources/**`, `mac/Tests/**`
- `android/gradle/**`, `android/gradlew`, `android/gradlew.bat`, `android/app/build.gradle.kts`, `android/app/src/test/**`
- `shared/PROTOCOL.md`
DO NOT modify any files in `tests/e2e/`.

## Mandatory Integrity Warning
> DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Tasks to Implement

### 1. Update `shared/PROTOCOL.md`
Copy the authoritative, complete specification codified in Part 2 of `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_spec_miner_3/spec.md` into `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md`.

### 2. Refactor macOS Targets & Enable Automated Testing
Per `m1_explorer_1/analysis.md`:
1. Refactor `mac/Package.swift` to define:
   - Library target `GalaxyContinuityKit` containing: `ServerManager.swift`, `ClipboardSyncService.swift`, `BonjourService.swift`, `NotificationService.swift`, `DeviceState.swift`, `ContinuityMessage.swift`, `WebAssets.swift`, and helper codecs.
   - Executable target `GalaxyContinuity` containing: `App.swift`, `AppDelegate.swift`, SwiftUI views (`MenuBarView.swift`, `DevicePairingView.swift`, `QuickDropView.swift`), linking `GalaxyContinuityKit`.
   - Test target `GalaxyContinuityTests` containing comprehensive tests for `GalaxyContinuityKit`.
2. Extract WebSocket framing logic into `mac/Sources/GalaxyContinuityKit/Services/WebSocketFramer.swift` so framing and SHA-1 accept hashing can be tested directly and used by `ServerManager`.
3. Create test cases in `mac/Tests/GalaxyContinuityTests/` covering:
   - WebSocket RFC 6455 framing (7-bit, 16-bit, 64-bit frame lengths, masking/unmasking, SHA-1 key accept generation).
   - JSON message serialization and parsing for all protocol message types.
   - File upload/download model and mock socket requests.
4. Run `cd mac && swift build` and `cd mac && swift test` and ensure all tests pass cleanly.

### 3. Provision Android Gradle Wrapper, Signing & Tests
Per `m1_explorer_2/analysis.md`:
1. Provision Gradle wrapper files:
   - Download official Gradle 8.5 `gradle-wrapper.jar` to `android/gradle/wrapper/gradle-wrapper.jar` and verify SHA-256 (`d3b261c2820e9e3d8d639ed084900f11f4a86050a8f83342ade7b6bc9b0d2bdd`).
   - Download official `gradlew` to `android/gradlew` and make it executable (`chmod +x`).
   - Download official `gradlew.bat` to `android/gradlew.bat`.
   - Update `android/gradle/wrapper/gradle-wrapper.properties` to `gradle-8.5-bin.zip`.
2. Update `android/app/build.gradle.kts`:
   - Add `signingConfigs { create("release") { ... } }` with fallback via `initWith(signingConfigs.getByName("debug"))`.
   - Set `signingConfig = signingConfigs.getByName("release")` under `buildTypes.release`.
   - Add `testOptions { unitTests.isReturnDefaultValues = true }`.
   - Add test dependencies: `junit:4.13.2`, `org.json:20231013`, `mockwebserver:4.12.0`.
3. Create JVM unit test classes under `android/app/src/test/java/com/galaxycontinuity/app/`:
   - `model/ContinuityProtocolTest.kt`: Tests serialization/deserialization for all protocol schemas.
   - `network/WebSocketMessageSerializationTest.kt`: Tests boundary parsing, malformed JSON, and unicode round-tripping.
4. Verify build files and tests. If a local JDK is available, run `./gradlew testDebugUnitTest`; if not, verify syntax and configuration integrity.

Write your report to `handoff.md` with:
- Summary of changes made
- Build and test commands executed and their output
- Verification evidence
Notify parent when complete.

## 2026-11-07T00:52:52Z
Read your dispatch instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_worker/DISPATCH.md, ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md, and PROJECT.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md.

Implement Milestone 1:
1. Codify complete shared/PROTOCOL.md from m1_spec_miner_3/spec.md Part 2.
2. Refactor mac/Package.swift, extract GalaxyContinuityKit and GalaxyContinuityTests, implement tests, and verify swift build & swift test pass.
3. Provision Android Gradle wrapper files (8.5), configure release signing in android/app/build.gradle.kts, add test dependencies and test suites in android/app/src/test/.

MANDATORY INTEGRITY WARNING: DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Save your report to handoff.md in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_worker/.
Keep progress.md updated and notify parent when complete.
