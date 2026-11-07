# Dispatch: E2E Testing Orchestrator (Track 2: Opaque-Box E2E Test Suite)

You are the E2E Testing Orchestrator (`teamwork_orchestrator`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/sub_orch_e2e`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`
Original request: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md`
Test Infrastructure Plan: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/TEST_INFRA.md`
Master Project Plan: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md`

## Mission
Design and implement the comprehensive, opaque-box E2E test suite derived strictly from user requirements and protocol specifications:
1. Implement the test runner and mock socket harness in `tests/e2e/runner.py` and `tests/e2e/harness.py`.
2. Implement 4 tiers of automated test cases:
   - **Tier 1 - Feature Coverage**: ≥5 test cases per feature (≥50 tests total) across Handshake, Text Clipboard, Image Clipboard, Quick Drop (both directions), Screen Mirroring control/frames, Continuity Camera control/frames, Notifications & Quick Reply, and Peer Discovery.
   - **Tier 2 - Boundary & Corner Cases**: ≥5 test cases per feature (≥50 tests total) covering max payload sizes, empty/null fields, malformed JSON, unmasked frames, network disconnects, rapid succession events, and invalid HTTP routes.
   - **Tier 3 - Cross-Feature Combinations**: ≥10 tests verifying simultaneous feature interactions (e.g. file upload while clipboard syncing, notification arrival during video stream, discovery transition).
   - **Tier 4 - Real-World Application Scenarios**: ≥5 realistic end-to-end workflows (e.g. workday workflow, large media transfer, virtual video call, offline reconnection).
3. Ensure runner has standard pass/fail semantics (exit code 0 on pass, non-zero on failure) and runs headlessly without physical devices using Python 3 standard library.
4. When complete, publish `TEST_READY.md` at both `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/TEST_READY.md` and `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/TEST_READY.md`.

## Execution Rules
- Do NOT write code yourself — delegate implementation to `teamwork_test_writer` or `teamwork_worker`.
- Verify with `teamwork_reviewer`, `teamwork_challenger`, and `teamwork_auditor`.
- Enforce ZERO TOLERANCE for cheating or dummy implementations.
- Write your state files (`BRIEFING.md`, `progress.md`, `SCOPE.md`, `GATE_STATUS.md`) in your working directory.
- Report back to parent upon publishing `TEST_READY.md`.
