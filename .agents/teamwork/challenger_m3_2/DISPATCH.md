# Task Assignment: Milestone 3 Challenger 2 (Continuity Camera Adversarial Stress Testing)

## Identity
- Role: teamwork_challenger
- Assigned Working Directory: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_2
- Project Root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
- Original Request File: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
- Scope Document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
- Protocol Specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md
- Worker Handoff: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3/handoff.md

## Objective
Adversarially stress-test Continuity Camera and Virtual Webcam across macOS and Android:
1. Empirically verify 5-byte binary packet framing (`0x02` stream type, UInt32 BE length), JPEG payload validation (`0xFF 0xD8`), 0-byte payloads, and corrupted packets.
2. Empirically verify camera controls: lens switching (`back`, `front`, `ultra_wide`, `telephoto`), unknown lenses (`"periscope_zoom_5x"`), digital zoom (0.5x, 1.0x, 2.0x, 10.0x), and torch toggles.
3. Empirically verify schema aliases: `"facing"` mapped to `"lens"`, `"resolution"` mapped to `"quality"`.
4. Empirically verify session lifecycle: `camera_start` with zero fps, redundant `camera_stop` calls, and stalling recovery (>5000ms).
5. Empirically verify Virtual Webcam endpoint (`GET /api/camera/stream`) serving live frames.
6. Run verification commands:
   - `cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
   - `python3 tests/e2e/runner.py --filter camera`
   - `python3 tests/e2e/runner.py`
7. Provide an explicit verdict (APPROVE or REQUEST_CHANGES) in `handoff.md`.


## 2026-11-07T14:38:01Z
You are challenger_m3_2.
Your working directory is: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_2
Project root: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity
Original request file: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md
Dispatch instructions: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/challenger_m3_2/DISPATCH.md
Worker handoff: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/worker_m3/handoff.md
Scope document: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md
Protocol specification: /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md

Adversarially stress-test Continuity Camera and Virtual Webcam (packet framing 0x02, JPEG stream, lens switching, resolution aliases, digital zoom, torch, MJPEG stream endpoint).
Run:
- cd mac && swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
- python3 tests/e2e/runner.py --filter camera
- python3 tests/e2e/runner.py

Write your handoff report to handoff.md in your working directory with an explicit verdict (APPROVE or REQUEST_CHANGES). Send a completion message to the orchestrator.
