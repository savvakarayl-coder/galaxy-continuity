# Dispatch: M2 Explorer 1 (Universal Clipboard Parity)

You are `m2_explorer_1` (`teamwork_explorer`).
Working directory: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1`
Project root: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity`

## Mandatory Input Documents
Read these before starting:
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md` (authoritative user request)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/PROJECT.md` (roadmap, architecture, layout)
- `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/shared/PROTOCOL.md` (protocol specification § 5.2)

## Milestone 2 Scope: Universal Clipboard
Investigate the codebase and design drop-in implementation blueprints for bidirectional plain text and image clipboard transfer:

1. **macOS Host (`mac/Sources/GalaxyContinuityKit/Services/ClipboardSyncService.swift`)**:
   - Inspect existing polling in `ClipboardSyncService.swift`.
   - Add support for image clipboard data: check `NSPasteboard.general.data(forType: .png)` or `.tiff` (convert TIFF to PNG data).
   - Compute SHA-256 hash of payload (`CryptoKit.SHA256`) for echo suppression.
   - For outgoing image: encode PNG to base64, send `ContinuityMessage(type: "clipboard", contentType: "image/png", payload: base64, hash: sha256)`.
   - For incoming clipboard: handle `contentType == "text/plain"` (write string to `NSPasteboard`) and `contentType == "image/png"` (decode base64, write `NSImage` / PNG data to `NSPasteboard`).
   - Suppress echo loops: if incoming `hash == lastSentHash` or `hash == lastSeenHash`, ignore.

2. **Android Client (`android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt`)**:
   - Inspect existing `ClipboardSync.kt`.
   - Add image clipboard handling: check `ClipData.Item.uri` or bitmap stream, resolve image data, compute SHA-256 hash.
   - For outgoing image: encode to base64 PNG, send clipboard JSON frame.
   - For incoming image: decode base64, create `ClipData` with image URI or content provider / clipboard entry.
   - Add SHA-256 echo suppression.

3. Formulate concrete code blueprints for the worker.
4. Output your report to `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1/handoff.md` and notify parent via `send_message`.


## 2026-11-07T10:21:37Z
You are m2_explorer_1. Read your instructions in /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1/DISPATCH.md. First read ORIGINAL_REQUEST.md at /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/ORIGINAL_REQUEST.md. Investigate Universal Clipboard for macOS and Android (text & image, base64, SHA-256 echo suppression). Formulate drop-in blueprints for the worker. Output your report to /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m2_explorer_1/handoff.md and notify your parent via send_message.
