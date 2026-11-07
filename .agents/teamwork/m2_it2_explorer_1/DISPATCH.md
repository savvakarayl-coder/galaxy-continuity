# Dispatch: m2_it2_explorer_1

## Task Assignment
Milestone 2 Iteration 2 Exploration: Android Clipboard & Unit Test Integrity Fix Blueprint.

## Background & Reviewer Feedback
In Milestone 2 Gate Iteration 1, reviewer_m2_2 issued REQUEST_CHANGES with two critical findings:
1. `android/app/src/test/java/com/galaxycontinuity/app/ClipboardSyncUnitTest.kt` is a facade test: it does not import or call `ClipboardSync` or `WebSocketClient`, but re-implements private functions and local closures within test methods and tests itself, exercising zero lines of production code.
2. `ClipboardSync.kt` (lines 71, 93) and `WebSocketClient.kt` (line 67) discard empty string clipboard payloads, breaking bidirectional clipboard clearing/empty string sync parity with macOS.
3. Static filename `synced_clip.$ext` in `ClipboardSync.kt:124` causes image cache overwrites during rapid sync.

## Scope of Investigation
1. Inspect `android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt` and `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt`.
2. Inspect `android/app/src/test/java/com/galaxycontinuity/app/ClipboardSyncUnitTest.kt`.
3. Design a concrete implementation blueprint to:
   - Expose testable pure methods on `ClipboardSync` (e.g. in its companion object or static utility methods: `sha256Hex(bytes: ByteArray): String`, echo suppression logic `shouldSuppressEcho(hash: String, lastSeenHash: String, lastSentHash: String): Boolean`, image extension resolution `resolveExtension(contentType: String): String`, etc.).
   - Expose testable serialization/deserialization methods on `WebSocketClient` or `ClipboardSync` (e.g. `createClipboardMessage(content: String, contentType: String, hash: String): String`, `parseClipboardMessage(json: String): ClipboardPayload`).
   - Refactor `ClipboardSyncUnitTest.kt` to directly `import com.galaxycontinuity.app.service.ClipboardSync` and `import com.galaxycontinuity.app.network.WebSocketClient` and call their real production methods directly with non-trivial assertions (testing empty string, SHA-256 vectors, echo suppression, image extensions, JSON roundtrip).
   - Fix empty string handling in `ClipboardSync.kt` (allow empty string text in outgoing listener and incoming `updateClipboardFromMac`) and in `WebSocketClient.kt` (allow empty string `content` for `type == "clipboard"`).
   - Fix image cache filename in `ClipboardSync.kt` to use unique identifier (e.g. `synced_clip_${hash.take(8)}.$ext`).

## Output Requirements
Produce a comprehensive report at `.agents/teamwork/m2_it2_explorer_1/handoff.md` with:
- Observation (exact files, line numbers, analysis)
- Logic Chain (why this blueprint completely resolves reviewer_m2_2 findings)
- Concrete Fix Blueprint (exact code changes line-by-line)
- Verification Method (how to verify without Android device or host JDK)


## 2026-11-07T10:51:12Z
[Message] timestamp=2026-11-07T10:51:12Z sender=67ae80cb-3237-4127-adab-613c0f12f1aa priority=MESSAGE_PRIORITY_HIGH
Task: Formulate an exact, actionable fix blueprint to:
1. Eliminate the facade test in ClipboardSyncUnitTest.kt (expose pure companion methods on ClipboardSync, refactor unit test to import production classes).
2. Fix empty string clipboard handling on lines 71 & 93 in ClipboardSync.kt and line 67 in WebSocketClient.kt.
3. Fix image cache filename in ClipboardSync.kt:124 to avoid collision.
Write handoff.md and send completion message to parent.
