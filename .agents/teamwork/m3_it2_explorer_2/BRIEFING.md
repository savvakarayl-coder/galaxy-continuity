# BRIEFING — 2026-11-07T14:57:00Z

## Mission
Investigate Android client issues (Touch gesture safety, Camera lens switching, CaptureRequest persistence, and Screen mirroring stream compatibility) and produce an exhaustive, concrete, drop-in remediation blueprint with exact Kotlin code snippets in handoff.md.

## 🔒 My Identity
- Archetype: explorer
- Roles: Android Client Fix Blueprint Specialist
- Working directory: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m3_it2_explorer_2
- Original parent: edb875f9-c921-490b-8f47-2beeb22c6414
- Milestone: Milestone 3 Iteration 2

## 🔒 Key Constraints
- Read-only investigation — do NOT implement in production source code
- Produce concrete drop-in Kotlin code snippets and blueprint in handoff.md
- Adhere strictly to PROTOCOL.md and PROJECT.md

## Current Parent
- Conversation ID: edb875f9-c921-490b-8f47-2beeb22c6414
- Updated: 2026-11-07T14:57:00Z

## Investigation State
- **Explored paths**:
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityAccessibilityService.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/RemoteInputMapper.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityCameraService.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ScreenMirroringService.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`
  - `android/app/src/main/java/com/galaxycontinuity/app/network/StreamPacket.kt`
  - Unit tests: `ScreenMirroringUnitTest.kt`, `ContinuityCameraUnitTest.kt`, `StreamPacketTest.kt`
  - Reviewer reports: `reviewer_m3_1/handoff.md`, `reviewer_m3_2/handoff.md`
- **Key findings**:
  1. Touch safety: Missing `down` leaves `downX/downY = 0f, 0f` and `duration = 400L`, causing full diagonal drag from `(0, 0)`. Need defensive guard in `RemoteInputMapper` & `ContinuityAccessibilityService` to force in-place tap and reset `downTime`.
  2. Camera lens switch: `switch_lens` calls `startCamera` which calls `stopCamera()`, sending `sendCameraStop()` to Mac and calling `stopSelf()`, deactivating the session on Mac and killing the Android service. Need clean separation: `closeCameraSensor()` vs full `stopCamera()`.
  3. CaptureRequest persistence: `set_zoom` and `toggle_torch` recreate `CaptureRequest.Builder` without previous zoom, torch, AF mode, or AE fps range. Need persistent builder and unified `updateCaptureRequest()` method.
  4. Screen mirroring compatibility: Raw H.264 NAL units cannot be decoded by `NSImage(data:)` on Mac. MediaCodec needs SPS/PPS preservation. Additionally, providing an optional JPEG capture pipeline via `ImageReader` guarantees 100% immediate viewer rendering on macOS. Missing `resultData` should immediately respond with `sendScreenStop("permission_required")`.
- **Unexplored areas**: None. All core Android areas analyzed down to line numbers.

## Key Decisions Made
- Architecture for Camera2 persistence: Use single active `currentRequestBuilder` with `updateCaptureRequest(block)` lambda pattern.
- Architecture for Touch safety: Decouple touch path resolution into `RemoteInputMapper.resolveUpStroke` to enable 100% JVM unit test coverage without Android runtime dependencies.
- Architecture for Screen Mirroring: Support both hardware H.264 (with SPS/PPS header prepending) and ImageReader JPEG mode.

## Artifact Index
- DISPATCH.md — Incoming parent tasks and directives
- BRIEFING.md — Persistent working memory and state
- progress.md — Liveness heartbeat and step tracking
- handoff.md — Final deliverable remediation blueprint
