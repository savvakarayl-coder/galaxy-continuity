# Dispatch: m2_it2_explorer_2

## Task Assignment
Milestone 2 Iteration 2 Exploration: Android Quick Drop Reliability & Notification Fix Blueprint.

## Background & Reviewer Feedback
In Milestone 2 Gate Iteration 1, reviewer_m2_2 identified two major defects in Quick Drop:
1. `ContinuityService.kt` (lines 171–177) constructs an `ACTION_VIEW` intent without attaching data URI or MIME type, which causes `ActivityNotFoundException` when the Quick Drop download completion notification is clicked.
2. `FileTransferClient.kt` (lines 131, 235) leaks Okio streams and OkHttp connections on download or upload failure, and leaves corrupted partial files on disk when a download aborts.

## Scope of Investigation
1. Inspect `android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`.
2. Inspect `android/app/src/main/java/com/galaxycontinuity/app/network/FileTransferClient.kt`.
3. Inspect `android/app/src/test/java/com/galaxycontinuity/app/FileTransferClientTest.kt`.
4. Design a concrete implementation blueprint to:
   - Fix notification intent in `ContinuityService.kt`: attach `FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)` and proper MIME type to `intent.setDataAndType(uri, mimeType)` with `FLAG_GRANT_READ_URI_PERMISSION`.
   - Fix resource management in `FileTransferClient.kt`:
     - Wrap `body.source()` and `targetFile.sink().buffer()` in Okio `.use { }` blocks.
     - On exception or failure during `downloadFile`, catch `Exception`, safely delete `targetFile` if it exists and is incomplete, and rethrow or return null.
     - In `uploadFile`, ensure `response.close()` is called when `!response.isSuccessful`.
   - Enhance unit tests in `FileTransferClientTest.kt` to verify stream closure and partial file cleanup.

## Output Requirements
Produce a comprehensive report at `.agents/teamwork/m2_it2_explorer_2/handoff.md` with:
- Observation (exact files, line numbers, analysis)
- Logic Chain
- Concrete Fix Blueprint (exact code changes line-by-line)
- Verification Method
