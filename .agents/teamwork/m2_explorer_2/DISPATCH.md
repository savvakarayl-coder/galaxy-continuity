# Dispatch: M2 Explorer 2 (Quick Drop File Transfer Parity)

You are `m2_explorer_2` (`teamwork_explorer`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_2`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification § 5.3)

## Milestone 2 Scope: Quick Drop File Transfer
Investigate the codebase and design drop-in implementation blueprints for bidirectional file transfers:

1. **macOS Host (`mac/Sources/GalaxyContinuityKit/Services/ServerManager.swift`, `QuickDropService.swift`)**:
   - Outgoing transfers (macOS -> Galaxy):
     - Initiating file transfer from macOS: register file in `ServerManager.availableFiles[fileId] = (fileName, filePath)`.
     - Broadcast WebSocket message `{"type": "file_available", "fileId": "<uuid>", "fileName": "<name>", "fileSize": <bytes>, "mimeType": "<mime>"}`.
     - Serve HTTP `GET /api/download/:fileId`: stream file chunks, send HTTP 200 with `Content-Length`, `Content-Type: application/octet-stream`, `Content-Disposition: attachment; filename="<name>"`.
   - Incoming transfers (Galaxy -> macOS):
     - Receive HTTP `POST /api/upload`: parse `X-Filename`, stream body, apply sanitization, handle duplicate collision rename (`file (1).ext`, `file (2).ext`), save to `~/Downloads/GalaxyContinuity/`.
     - Post local notification upon download completion.

2. **Android Client (`android/app/src/main/java/com/galaxycontinuity/app/service/ContinuityService.kt`, `network/FileTransferClient.kt`)**:
   - Outgoing transfers (Galaxy -> macOS):
     - Create `FileTransferClient.uploadFile(serverUrl, fileUri, filename, progressCallback)` using OkHttp `POST /api/upload` with `X-Filename` header.
     - Send `file_progress` updates over WebSocket or HTTP progress.
   - Incoming transfers (macOS -> Galaxy):
     - In `ContinuityService.onFileAvailable(fileId, filename, size)`: implement HTTP `GET http://<host>:8765/api/download/<fileId>` using OkHttp / DownloadManager.
     - Save file to Android `Download/GalaxyContinuity/` or app storage.
     - Emit progress notifications and completion intent.

3. Formulate concrete code blueprints for the worker.
4. Output your report to `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_2/handoff.md` and notify parent via `send_message`.

## 2026-11-07T10:21:41Z
You are m2_explorer_2. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_2/DISPATCH.md. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Investigate Quick Drop file transfer for macOS and Android (upload, download, collision renaming, progress tracking). Formulate drop-in blueprints for the worker. Output your report to /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_2/handoff.md and notify your parent via send_message.
