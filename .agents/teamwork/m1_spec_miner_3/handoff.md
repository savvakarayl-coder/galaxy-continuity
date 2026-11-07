# Handoff Report — M1 Spec Miner 3

**Author**: M1 Spec Miner 3 (`teamwork_spec_miner`)  
**Date**: 2026-11-07  
**Task**: Codification of Shared Protocol Specification (`shared/PROTOCOL.md`)  
**Working Directory**: `/Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_spec_miner_3`  
**Output Files**:  
- `spec.md` (Contains full discovery report and complete, drop-in text for `shared/PROTOCOL.md`)  
- `progress.md` (Heartbeat and milestone tracking)  
- `BRIEFING.md` (Agent state & memory)  

---

## 1. Observation

Direct observations from examining the codebase and authoritative sources:

1. **Bare existing protocol file**:
   - Inspecting `shared/PROTOCOL.md` (lines 1–89) showed only rudimentary examples for `handshake`, `clipboard` (text only), `file_available`, `ping_device`, `phone_notification`, and `battery_update`.
   - It lacked schemas for `handshake_ack`, image clipboard payloads, file transfer progress/complete (`file_progress`, `file_complete`), screen mirroring (`screen_start`, `screen_stop`, `input_event`, `input_key`), continuity camera (`camera_start`, `camera_stop`, `camera_control`), interactive notification replies (`notification_reply`), and binary framing rules.

2. **Existing macOS Host implementation**:
   - `mac/Sources/GalaxyContinuity/Services/ServerManager.swift` lines 243–294:
     - Handles WebSocket upgrade on `/ws` using SHA-1 hash of `Sec-WebSocket-Key` + `"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`.
     - Handles `POST /api/upload` reading `Content-Length` and optional `X-Filename` (with percent-decoding and duplicate resolution appending `(1)`, `(2)`), returning `HTTP/1.1 200 OK` with `{"status":"ok"}`.
     - Handles `GET /` and `GET /companion` returning `WebAssets.html`.
     - Handles `GET /api/download/:fileId` returning file binary with `Content-Disposition: attachment; filename="..."`.
   - `mac/Sources/GalaxyContinuity/Services/ServerManager.swift` lines 379–440:
     - RFC 6455 framing parses opcodes: `0x1` (Text), `0x8` (Close), `0x9` (Ping returning `0xA` Pong).
     - Length decoding handles 7-bit, 16-bit (`payloadLen == 126`), and 64-bit (`payloadLen == 127`).
     - Supports masked client frames with 4-byte mask XOR unmasking.
   - `mac/Sources/GalaxyContinuity/Models/ContinuityMessage.swift` lines 13–35:
     - Defined initial Codable struct fields (`type`, `device`, `platform`, `version`, `content`, `contentType`, `timestamp`, `source`, `fileId`, `filename`, `fileSize`, `mimeType`, `sender`, `app`, `title`, `text`, `level`, `isCharging`, `url`, `message`, `battery`).
   - `mac/Sources/GalaxyContinuity/Services/BonjourService.swift` lines 15–26:
     - Publishes `NetService(domain: "local.", type: "_galaxycontinuity._tcp.", name: "Galaxy Continuity (\(deviceName))", port: Int32(port))` with TXT records `name`, `platform`, and `version`.

3. **Existing Android Client implementation**:
   - `android/app/src/main/java/com/galaxycontinuity/app/network/WebSocketClient.kt` lines 41–79:
     - Connects to `ws://$host:$port/ws`.
     - Sends `handshake` with `device`, `platform`, `version`, and `battery`.
     - Handles `handshake_ack`, `clipboard`, `file_available`, and `ping_device`.
   - `android/app/src/main/java/com/galaxycontinuity/app/network/NsdDiscovery.kt` lines 13–71:
     - Discovers `_galaxycontinuity._tcp.` via `NsdManager.discoverServices(..., NsdManager.PROTOCOL_DNS_SD, listener)` and resolves IP/port.
   - `android/app/src/main/java/com/galaxycontinuity/app/service/ClipboardSync.kt` lines 20–49:
     - Monitors primary clip and updates clipboard; suppresses echo loops via `isUpdatingFromMac` and `lastSeenText`.
   - `android/app/src/main/java/com/galaxycontinuity/app/service/NotificationForwarderService.kt` lines 12–38:
     - Listens via `NotificationListenerService`, filters ongoing and system noise, forwards `title`, `text`, `app`.

4. **Project Requirements and Survey Contracts**:
   - `.agents/teamwork/PROJECT.md` lines 70–97 and `m1_spec_miner_3/DISPATCH.md` lines 11–15:
     - Screen Mirroring: `screen_start` (`width`, `height`, `fps`, `bitrate`), `screen_stop`, `input_event` (`action`, `x`, `y`, `button`), `input_key` (`key`, `keyCode`).
     - Binary framing: binary frame packet `[0x01][4-byte uint32 len][payload]` for screen, `[0x02][4-byte uint32 len][payload]` for camera.
     - Continuity Camera: `camera_start` (`lens`/`facing`, `quality`/`resolution`, `fps`), `camera_stop`, `camera_control` (`action`, `lens`, `zoom`, `torch`).
     - Notifications: `phone_notification` with `id`, `packageName`, `canReply`, and `notification_reply` with `id`, `packageName`, `replyText`.
     - Multi-transport discovery: Bonjour `_galaxycontinuity._tcp.`, BLE Service UUID `19B10000-E8F2-537E-4F6C-D104768A1214` with characteristics (`DEVICE_INFO`, `PAIRING_COMMAND`, `STATUS`), and Wi-Fi Direct P2P Group Owner IP `192.168.49.1:8765`.

---

## 2. Logic Chain

1. **Gap Analysis**: The existing `shared/PROTOCOL.md` was an initial skeleton created early in the repository setup. It omitted 11 out of 17 critical message schemas, omitted all binary stream framing definitions, lacked offline BLE / Wi-Fi Direct multi-transport specifications, and did not document error codes or loop-prevention rules.
2. **Harmonization with Reference Code & Survey**:
   - The reference implementations in macOS (`ServerManager.swift`, `BonjourService.swift`) and Android (`WebSocketClient.kt`, `NsdDiscovery.kt`) establish the baseline wire-level behavior on port `8765`.
   - The user requirements in `ORIGINAL_REQUEST.md` (R1) require screen mirroring, remote input, continuity camera, notification quick reply, and multi-transport discovery (Bonjour + BLE + Wi-Fi Direct).
3. **Binary Framing Standardization**:
   - To achieve low-latency media transfer without HTTP chunking overhead, WebSocket Opcode `0x2` is paired with an unambiguous 5-byte packet header: `[Byte 0: Stream Type (0x01 Screen / 0x02 Camera)][Bytes 1-4: Big-Endian UInt32 Payload Length][Payload Bytes]`.
   - This allows the macOS host to route incoming packets directly to either the Screen Mirroring rendering surface or the CoreMediaIO virtual webcam stream with zero re-framing ambiguity.
4. **Comprehensive Codification**:
   - All 17 message schemas were defined with field-by-field JSON Schema tables, data types, mandatory/optional flags, and representative payload examples.
   - The 3-tier multi-transport discovery hierarchy was specified with concrete service UUIDs, characteristic UUIDs, and network addresses.
   - The resulting document in `spec.md` provides an immediate, complete drop-in replacement for `shared/PROTOCOL.md`.

---

## 3. Caveats

1. **Protocol Implementation Status**: This agent's role is read-only specification mining and protocol definition. Codifying this specification into `shared/PROTOCOL.md` and implementing the new schemas in `ContinuityMessage.swift` and Kotlin models will be executed by Milestone 1/2/3/4 implementation agents.
2. **Video Codec Negotiation**: The binary framing standardizes on H.264 Annex B NAL units and JPEG/MJPEG frames. Advanced codec parameters (e.g. H.265 / HEVC or AV1) are left for future protocol extension without altering the packet framing format.

---

## 4. Conclusion

1. The exact, complete protocol specification covering all 17 JSON message schemas, RFC 6455 and 5-byte media packet binary framing, HTTP REST endpoints, and multi-transport discovery specifications (Bonjour mDNS, BLE UUID `19B10000-...`, Wi-Fi Direct `192.168.49.1:8765`) has been fully codified.
2. The complete text ready to be written to `shared/PROTOCOL.md` has been delivered in `spec.md` (Part 2), along with the Specification Miner discovery table (34 features) and edge cases table (19 edge cases) in Part 1.

---

## 5. Verification Method

To verify the findings and proposed protocol specification:
1. **Inspect Specification Artifacts**:
   - Verify `spec.md` exists and contains Part 1 (Features Discovered table, Edge Cases table) and Part 2 (Full replacement content for `shared/PROTOCOL.md`):
     ```bash
     test -f /Users/frogs_hyles/.gemini/antigravity/scratch/galaxy-continuity/.agents/teamwork/m1_spec_miner_3/spec.md && echo "spec.md verified"
     ```
2. **Check Completeness of Schemas**:
   - Confirm coverage of all required schemas in `spec.md`:
     - Handshake: `handshake`, `handshake_ack`
     - Universal Clipboard: `clipboard` (text, image, hash, loop prevention)
     - Quick Drop: `file_available`, `file_progress`, `file_complete`, `POST /api/upload`, `GET /api/download/:fileId`
     - Screen Mirroring: `screen_start`, `screen_stop`, `input_event`, `input_key`, `[0x01]` packet
     - Continuity Camera: `camera_start`, `camera_stop`, `camera_control`, `[0x02]` packet
     - Notifications: `phone_notification`, `notification_reply`
     - Device State & Ping: `ping_device`, `battery_update`
     - Discovery: Bonjour `_galaxycontinuity._tcp.`, BLE `19B10000-E8F2-537E-4F6C-D104768A1214`, Wi-Fi Direct `192.168.49.1:8765`
3. **Invalidation Conditions**:
   - The specification would be invalidated if port `8765` or the WebSocket path `/ws` is altered without updating all client/server references, or if the 5-byte binary packet header format is modified.
