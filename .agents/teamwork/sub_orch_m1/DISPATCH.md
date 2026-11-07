# Dispatch: Milestone 1 Sub-Orchestrator (Architecture & Test Harness Enablement)

You are the Milestone 1 Sub-Orchestrator (`teamwork_orchestrator`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/sub_orch_m1`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`
Original request: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md`
Master Project Plan: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md`

## Milestone 1 Scope
Implement Architecture & Test Harness Enablement across `mac/`, `android/`, and `shared/`:

1. **macOS (`mac/Package.swift`)**:
   - Refactor `Package.swift` to extract core services into a reusable library target (`GalaxyContinuityKit`), retain the menu bar executable (`GalaxyContinuity`) linking the library, and add an automated test target (`GalaxyContinuityTests`).
   - Add initial unit/integration tests in `mac/Tests/GalaxyContinuityTests/` covering server startup, WebSocket framing, HTTP endpoints, and message decoding.
   - Verify that `swift build` and `swift test` succeed cleanly.

2. **Android (`android/`)**:
   - Add the standard Gradle wrapper distribution files (`gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`).
   - Configure `android/app/build.gradle.kts` so that `release` builds have a valid signing configuration (using a release or debug signing key) to ensure `./gradlew assembleRelease` and `./gradlew assembleDebug` can produce installable APKs.
   - Set up initial unit test directory and test class in `android/app/src/test/` to verify protocol message serialization and network models.

3. **Shared Protocol (`shared/PROTOCOL.md`)**:
   - Update `shared/PROTOCOL.md` to formally document all message schemas, JSON formats, binary frame headers, and discovery parameters (mDNS, BLE UUIDs, Wi-Fi Direct) discovered in the survey phase.

## Execution Rules
- Do NOT write source code yourself — delegate implementation to `teamwork_worker`.
- Use `teamwork_explorer` for initial technical analysis, `teamwork_reviewer` for code review, `teamwork_challenger` for empirical testing, and `teamwork_auditor` for integrity forensics.
- Enforce ZERO TOLERANCE for cheating. Forensic audit is a binary veto.
- Write your state files (`BRIEFING.md`, `progress.md`, `SCOPE.md`, `GATE_STATUS.md`) in your working directory.
- Report back to parent with handoff report and verification evidence when Milestone 1 passes its gate.
