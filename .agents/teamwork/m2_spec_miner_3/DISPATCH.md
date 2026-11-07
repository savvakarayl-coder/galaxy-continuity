# Dispatch: M2 Spec Miner 3 (Clipboard & Quick Drop Specification Alignment)

You are `m2_spec_miner_3` (`teamwork_spec_miner`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_spec_miner_3`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification § 5.2, § 5.3, § 6.1)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/TEST_READY.md` (E2E test suite status)

## Milestone 2 Scope: Specification Alignment & Test Matrix
Mine authoritative specifications and cross-reference against test suites for Features F2, F3, F4, F5:
1. **Clipboard Specifications (`PROTOCOL.md § 5.2`)**:
   - `type: "clipboard"`, `contentType: "text/plain" | "image/png"`, `payload: String | Base64`, `hash: SHA-256`, `timestamp: Int64`.
   - Loop prevention rules: echo suppression using `hash`, device source tracking.
   - Large image payload limits and WebSocket framing interaction (64-bit length handling).
2. **Quick Drop Specifications (`PROTOCOL.md § 5.3 & § 6.1`)**:
   - WebSocket message `file_available` fields: `fileId`, `fileName`, `fileSize`, `mimeType`.
   - `file_progress` fields: `fileId`, `bytesTransferred`, `totalBytes`, `percentage` (Double), `status`.
   - `file_complete` fields: `fileId`, `fileName`, `fileSize`, `status`.
   - HTTP endpoints: `GET /api/download/:fileId`, `POST /api/upload`.
   - Filename collision rules: `filename (1).ext`, `filename (2).ext`.
   - HTTP response headers: `Content-Length`, `Content-Disposition`, `Connection: close`.
3. **E2E Test Matrix Analysis**:
   - Inspect tests covering F2, F3, F4, F5 in `tests/e2e/test_tier1_features.py` and `test_tier2_boundary.py`.
   - Document all expected status codes, header names, JSON keys, and edge cases (e.g. 0-byte file, 10MB file, percent-encoded filenames, special characters).
4. Formulate concrete specifications and verification criteria for Worker M2.
5. Output your report to `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_spec_miner_3/handoff.md` and notify parent via `send_message`.


## 2026-11-07T10:21:45Z
You are m2_spec_miner_3. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_spec_miner_3/DISPATCH.md. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Mine protocol specifications and E2E test suites for clipboard and Quick Drop (features F2, F3, F4, F5). Formulate exact contracts and test verification matrix for the worker. Output your report to /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_spec_miner_3/handoff.md and notify your parent via send_message.
