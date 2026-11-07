# Dispatch: Challenger M2-2 (Quick Drop Adversarial Stress Testing)

You are `challenger_m2_2` (`teamwork_challenger`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m2_2`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification § 5.3, § 3.2, § 3.3)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m2/handoff.md` (worker handoff report)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/TEST_READY.md` (E2E test suite status)

## Scope: Empirical Adversarial Challenge for Quick Drop File Transfer
Adversarially challenge and stress-test Quick Drop file transfer across macOS and Android:
1. Outgoing File Transfer (macOS -> Android):
   - `file_available` announcement parsing.
   - HTTP `GET /api/download/:fileId`: chunked streaming, correct `Content-Length`, `Content-Disposition`, and MIME type.
   - Non-existent `:fileId` returns 404 cleanly.
   - Zero-byte file download.
2. Incoming File Transfer (Android -> macOS):
   - HTTP `POST /api/upload`: streaming body, `X-Filename` header.
   - Duplicate file collision renaming: upload `test.pdf` 3 times; verify files are saved as `test.pdf`, `test (1).pdf`, `test (2).pdf`.
   - File without extension collision renaming: `README` -> `README (1)`.
   - Special characters and percent-encoded filenames in `X-Filename`.
   - Directory traversal attacks (`../`, `../../`, Windows backslash) — verify strict confinement to `~/Downloads/GalaxyContinuity/`.
3. Progress and Completion:
   - Verify `file_progress` emission during transfer and `file_complete` upon finish.
4. Automated test execution:
   - Run `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`.
   - Run `python3 tests/e2e/runner.py --filter file` and full `python3 tests/e2e/runner.py`.
5. Formulate explicit verdict: `APPROVE` or `REQUEST_CHANGES`.
6. Output report to `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m2_2/handoff.md` and notify parent via `send_message`.


## 2026-11-07T10:40:41Z
[Message from 67ae80cb-3237-4127-adab-613c0f12f1aa]
You are challenger_m2_2. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m2_2/DISPATCH.md. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Adversarially stress-test Quick Drop file transfers (chunked streaming, collision renaming, missing files, directory traversal, progress tracking). Write your report and verdict (APPROVE or REQUEST_CHANGES) to /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m2_2/handoff.md and notify your parent via send_message.
