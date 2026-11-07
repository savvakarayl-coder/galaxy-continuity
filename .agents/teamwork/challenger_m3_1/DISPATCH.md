# Task Assignment: Milestone 3 Challenger 1 (Screen Mirroring Adversarial Stress Testing)

## Identity
- Role: teamwork_challenger
- Assigned Working Directory: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_1
- Project Root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
- Original Request File: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
- Scope Document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
- Protocol Specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md
- Worker Handoff: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3/handoff.md

## Objective
Adversarially stress-test Screen Mirroring across macOS and Android:
1. Empirically verify 5-byte binary packet framing (`0x01` stream type, UInt32 BE length), corrupted headers (<5 bytes), 0-byte payloads, and large payloads.
2. Empirically verify remote touch input boundaries: negative coordinates (`x: -0.5, y: -0.2`), excess coordinates (`x: 2.5, y: 3.0`), unknown action names (`"hover_scroll_pinch"`), and rapid gesture spam.
3. Empirically verify remote key events: standard keys (`"BACK"`, `"HOME"`, `"RECENTS"`, `"ENTER"`), unknown keys (`"HYPER_DIMENSIONAL_BUTTON"`), and unknown key codes.
4. Empirically verify session lifecycle: `screen_start` with zero dimensions, redundant `screen_stop` calls (idempotence), and stalling watchdog (>5000ms recovery).
5. Run verification commands:
   - `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
   - `python3 tests/e2e/runner.py --filter screen`
   - `python3 tests/e2e/runner.py`
6. Provide an explicit verdict (APPROVE or REQUEST_CHANGES) in `handoff.md`.


## 2026-11-07T14:37:55Z
You are challenger_m3_1.
Your working directory is: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_1
Project root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
Original request file: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
Dispatch instructions: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_1/DISPATCH.md
Worker handoff: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3/handoff.md
Scope document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
Protocol specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md

Adversarially stress-test Screen Mirroring (packet framing 0x01, touch coordinates out of bounds, unknown actions, key codes, stalling watchdog >5000ms).
Run:
- cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
- python3 tests/e2e/runner.py --filter screen
- python3 tests/e2e/runner.py

Write your handoff report to handoff.md in your working directory with an explicit verdict (APPROVE or REQUEST_CHANGES). Send a completion message to the orchestrator.
