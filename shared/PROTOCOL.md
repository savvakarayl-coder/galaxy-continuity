# Galaxy Continuity — Authoritative Communication Protocol

**Version**: `1.0.0`  
**Status**: Authoritative Standard  
**Default Service Port**: `8765` (TCP)  

---

## 1. Overview & Transport Topology

Galaxy Continuity delivers a full 1:1 Apple Continuity replacement between macOS hosts and Samsung Galaxy (Android) devices. The protocol operates over a unified bidirectional architecture:

```
+-----------------------------------------------------------------------------------+
|                               Multi-Transport Discovery                           |
|  1. Local Network: Bonjour / mDNS (_galaxycontinuity._tcp. on port 8765)         |
|  2. Offline BLE: GATT Service UUID 19B10000-E8F2-537E-4F6C-D104768A1214           |
|  3. Offline Direct: Wi-Fi Direct P2P Group Owner (192.168.49.1:8765)              |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                        Unified TCP Connection (Port 8765)                         |
|                                                                                   |
|  +---------------------------+   +---------------------------------------------+  |
|  |     HTTP/1.1 Endpoints    |   |           RFC 6455 WebSocket (/ws)          |  |
|  | - GET / (Web Companion)   |   |                                             |  |
|  | - POST /api/upload        |   | - Opcode 0x1: UTF-8 JSON Control Messages   |  |
|  | - GET /api/download/:id   |   | - Opcode 0x2: Binary Media Stream Packets   |  |
|  +---------------------------+   | - Opcode 0x9/0xA: Ping / Pong Heartbeat     |  |
|                                  +---------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

---

## 2. Multi-Transport Peer Discovery

Galaxy Continuity implements a resilient three-tier discovery hierarchy to maintain continuous connectivity whether connected to enterprise Wi-Fi, home routers, or completely offline.

### 2.1 Apple Bonjour / mDNS (Local Network)
- **Service Type**: `_galaxycontinuity._tcp.`
- **Default Port**: `8765`
- **Domain**: `local.`
- **Service Name Format**: `Galaxy Continuity (<Device Name>)`
- **Multicast Target**: UDP `224.0.0.251:5353` (IPv4) or `[FF02::FB]:5353` (IPv6)
- **Mandatory TXT Records**:
  | Key | Type | Description | Example |
  |---|---|---|---|
  | `name` | String | Human-readable device name | `MacBook Pro` or `Galaxy S24 Ultra` |
  | `platform` | String | Operating system identifier | `macOS` or `Android` |
  | `version` | String | Protocol version string | `1.0.0` |
  | `port` | String | Active TCP server port | `8765` |
  | `id` | String | Stable unique device UUID or hardware hash | `c56a4180-2a8d-4f81-9bfa-89e4c69812df` |

- **macOS Registration**: Published via `NetService(domain: "local.", type: "_galaxycontinuity._tcp.", name: "...", port: 8765)`.
- **Android Discovery**: Discovered and resolved via `android.net.nsd.NsdManager.discoverServices("_galaxycontinuity._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)`.

---

### 2.2 Bluetooth Low Energy (BLE - Offline Discovery)
When local network Wi-Fi is inaccessible, BLE beacons advertise device availability and negotiate direct links.

- **Primary Service UUID**: `19B10000-E8F2-537E-4F6C-D104768A1214`
- **GATT Characteristic UUIDs**:
  | Characteristic | UUID | Properties | Purpose / Payload |
  |---|---|---|---|
  | `DEVICE_INFO` | `19B10001-E8F2-537E-4F6C-D104768A1214` | `Read`, `Notify` | UTF-8 JSON: `{"device":"...","platform":"...","ip":"192.168.49.1","port":8765}` |
  | `PAIRING_COMMAND` | `19B10002-E8F2-537E-4F6C-D104768A1214` | `Write`, `WriteWithoutResponse` | 1-byte command opcode + payload: `0x01` (Request P2P link), `0x02` (Exchange credentials) |
  | `STATUS` | `19B10003-E8F2-537E-4F6C-D104768A1214` | `Read`, `Notify` | 1-byte status: `0x00` (Idle), `0x01` (Advertising), `0x02` (P2P Group Formed), `0x03` (Connected) |

- **Advertising Packet Structure**:
  - Flags: `0x06` (`LE General Discoverable Mode` | `BR/EDR Not Supported`).
  - 128-bit Service UUID: `19B10000-E8F2-537E-4F6C-D104768A1214`.
  - Service Data (Manufacturer Data):
    - Bytes 0-1: Protocol Identifier (`0x47 0x43` = "GC")
    - Byte 2: Device Role (`0x01` macOS Host, `0x02` Galaxy Client)
    - Bytes 3-4: Port (Big-Endian UInt16, `0x223D` = 8765)
    - Bytes 5-8: Short Device ID (First 4 bytes of device UUID)

---

### 2.3 Wi-Fi Direct (P2P High-Bandwidth Offline Link)
- **Role**: High-bandwidth ad-hoc direct link (802.11ac/ax peer-to-peer) for offline screen mirroring, camera streaming, and large file transfers without a local Wi-Fi router.
- **Group Owner (GO)**: Autonomous Group Owner established on Galaxy or Mac.
- **Group Owner Fixed IP**: `192.168.49.1` (standard Android Wi-Fi Direct P2P subnet `192.168.49.0/24`).
- **Connection URL**: `ws://192.168.49.1:8765/ws`.
- **Upload URL**: `http://192.168.49.1:8765/api/upload`.
- **Download URL**: `http://192.168.49.1:8765/api/download/:fileId`.

#### Discovery & Connection Fallback Hierarchy:
1. **Tier 1 (mDNS/Bonjour)**: Probe local network via `_galaxycontinuity._tcp.`. If resolved and TCP connection succeeds within 3 seconds, use local network.
2. **Tier 2 (BLE Out-of-Band Probe)**: If local Wi-Fi fails or devices are on isolated subnets, scan for BLE Service `19B10000-E8F2-537E-4F6C-D104768A1214`.
3. **Tier 3 (Wi-Fi Direct P2P)**: Form autonomous Wi-Fi Direct group. Connect to GO at `192.168.49.1:8765`.

---

## 3. HTTP REST API Specifications

The HTTP server runs on default port `8765`.

### 3.1 Web Companion PWA
- **Endpoint**: `GET /` or `GET /companion`
- **Request Headers**: None required
- **Response**:
  - Status: `200 OK`
  - Headers: `Content-Type: text/html; charset=utf-8`, `Connection: close`
  - Body: One UI styled Web Companion client (HTML5/CSS/JavaScript).

---

### 3.2 Quick Drop File Upload (Phone -> Mac)
- **Endpoint**: `POST /api/upload`
- **Headers**:
  - `Content-Length: <bytes>` (**Required**)
  - `X-Filename: <filename>` (**Optional**, supports UTF-8 and standard URL percent-encoding, e.g. `document%202026.pdf`)
  - `Content-Type: application/octet-stream` (or multipart)
- **Request Body**: Raw binary file payload.
- **Disk Storage Rule**:
  - Target directory: `~/Downloads/GalaxyContinuity/`.
  - Fallback filename if header omitted: `Received_File_<timestamp>.bin`.
  - Collision resolution: If target filename exists, append ` (1)`, ` (2)`, etc. (e.g. `report (1).pdf`).
- **Response (Success)**:
  - Status: `200 OK`
  - Headers: `Content-Type: application/json`, `Connection: keep-alive`, `Content-Length: 15`
  - Body: `{"status":"ok"}`
- **Response (Failure / Bad Method)**:
  - Status: `404 Not Found` (or `400 Bad Request` if `Content-Length` is missing)

---

### 3.3 Quick Drop File Download (Phone <- Mac)
- **Endpoint**: `GET /api/download/:fileId`
- **Path Parameter**: `:fileId` — UUID string advertised in a preceding `file_available` message.
- **Response (Success)**:
  - Status: `200 OK`
  - Headers:
    - `Content-Type: application/octet-stream`
    - `Content-Disposition: attachment; filename="<url_encoded_filename>"`
    - `Content-Length: <file_size_in_bytes>`
  - Body: Raw binary file payload.
- **Response (Not Found / Expired)**:
  - Status: `404 Not Found`
  - Headers: `Content-Length: 0`

---

### 3.4 WebSocket Upgrade Handshake
- **Endpoint**: `GET /ws` (or any path with WebSocket upgrade headers)
- **Request Headers**:
  - `Upgrade: websocket`
  - `Connection: Upgrade`
  - `Sec-WebSocket-Key: <base64-24-bytes>`
  - `Sec-WebSocket-Version: 13`
- **Handshake Computation**:
  - `GUID` = `"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`
  - `Accept` = `Base64(SHA1(Sec-WebSocket-Key + GUID))`
- **Response**:
  - Status: `HTTP/1.1 101 Switching Protocols`
  - Headers:
    - `Upgrade: websocket`
    - `Connection: Upgrade`
    - `Sec-WebSocket-Accept: <Accept>`

---

## 4. Binary Framing Specification

### 4.1 RFC 6455 WebSocket Framing & Opcode Mapping
WebSocket connections on `/ws` support standard RFC 6455 framing:

| Opcode | Hex | Description | Framing Rules |
|---|---|---|---|
| **Text Frame** | `0x1` | UTF-8 encoded JSON control messages (`ContinuityMessage`) | Masked from client; unmasked from server. |
| **Binary Frame** | `0x2` | Binary video/camera frame packets | Masked from client; unmasked from server. Carries binary packet header. |
| **Connection Close** | `0x8` | Clean session termination | Optional 2-byte status code + reason. |
| **Ping** | `0x9` | Liveness heartbeat query | Sent periodically (every 15-30s). Carries arbitrary payload. |
| **Pong** | `0xA` | Heartbeat response | Sent immediately upon receiving Ping `0x9` with identical payload. |

#### RFC 6455 Payload Length Encoding:
- `Length 0 - 125`: 7-bit length encoded directly in Byte 1.
- `Length 126`: 16-bit unsigned integer length in next 2 bytes (Big-Endian network byte order).
- `Length 127`: 64-bit unsigned integer length in next 8 bytes (Big-Endian network byte order).

---

### 4.2 Binary Media Stream Packet Framing
Binary media streams (Screen Mirroring and Continuity Camera) are framed using a standardized 5-byte packet header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Stream Type  |              Payload Length (32-bit)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Payload Length (cont.)  |          Media Payload ...    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

#### Header Fields:
1. **Byte 0 — Stream Type (`UInt8`)**:
   - `0x01`: **Screen Mirroring Frame** (H.264 NAL / JPEG chunk).
   - `0x02`: **Continuity Camera Frame** (MJPEG / H.264 chunk).
2. **Bytes 1-4 — Payload Length (`UInt32`, Big-Endian network byte order)**:
   - Size of the following media payload in bytes.
3. **Bytes 5..N — Media Payload**:
   - For `0x01` (Screen Mirroring): Raw H.264 NAL units (Annex B format starting with `00 00 00 01`) or JPEG frame buffer.
   - For `0x02` (Continuity Camera): Raw JPEG image buffer (for virtual webcam MJPEG ingestion) or H.264 frame.

---

## 5. Exhaustive JSON Message Schemas (WebSocket Opcode 0x1)

All control messages share the top-level envelope property `"type": "<message_type>"`.

---

### 5.1 Connection Lifecycle & Handshake

#### Client Handshake (`handshake`)
Sent by the Galaxy Client immediately upon opening the WebSocket connection.

```json
{
  "type": "handshake",
  "device": "Samsung Galaxy S24 Ultra",
  "platform": "android",
  "version": "1.0.0",
  "battery": {
    "level": 88,
    "isCharging": true
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"handshake"` |
| `device` | String | Yes | Client device name (e.g. `"Samsung Galaxy S24 Ultra"`) |
| `platform` | String | Yes | Operating system: `"android"` |
| `version` | String | Yes | Client application version: `"1.0.0"` |
| `battery` | Object | Optional | Initial battery status object |
| `battery.level` | Integer | Yes | Battery percentage (0 - 100) |
| `battery.isCharging` | Boolean | Yes | Charging state (`true` if charging, `false` otherwise) |

---

#### Server Handshake Acknowledgment (`handshake_ack`)
Sent by the macOS Host immediately upon receiving the client's HTTP upgrade or `handshake`.

```json
{
  "type": "handshake_ack",
  "device": "MacBook Pro — Савва",
  "platform": "macOS",
  "version": "1.0.0",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"handshake_ack"` |
| `device` | String | Yes | macOS host localized name |
| `platform` | String | Yes | Fixed value: `"macOS"` |
| `version` | String | Yes | Server application version: `"1.0.0"` |
| `timestamp` | Double | Optional | Epoch millisecond timestamp of acknowledgment |

---

### 5.2 Universal Clipboard Synchronization

Bidirectional payload synchronization for plain text and base64 encoded images.

#### Plain Text Clipboard
```json
{
  "type": "clipboard",
  "content": "https://galaxycontinuity.org/docs",
  "contentType": "text/plain",
  "hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "source": "mac",
  "timestamp": 1730940000000.0
}
```

#### Image Clipboard (PNG / JPEG)
```json
{
  "type": "clipboard",
  "content": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "contentType": "image/png",
  "hash": "a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e",
  "source": "phone",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"clipboard"` |
| `content` | String | Yes | Plain text string OR base64-encoded binary image bytes |
| `contentType` | String | Yes | MIME type: `"text/plain"`, `"image/png"`, or `"image/jpeg"` |
| `hash` | String | Optional | SHA-256 hex digest of payload for deduplication |
| `source` | String | Yes | Originating sender identifier: `"mac"` or `"phone"` |
| `timestamp` | Double | Optional | Epoch millisecond timestamp when copied |

#### Loop Prevention Rules:
1. Senders MUST tag their originating role in `"source"`.
2. When a node receives a `clipboard` message, it writes the content to the local system pasteboard under an internal suppression lock.
3. If the incoming payload `content` or `hash` matches the local node's `lastSeenClipboard`, the event MUST be dropped immediately.
4. Nodes MUST NEVER re-broadcast a clipboard update that originated remotely.

---

### 5.3 Quick Drop File Transfer

#### File Available Announcement (`file_available`)
Broadcast by the file sender to notify the peer that a file is ready for download.

```json
{
  "type": "file_available",
  "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
  "filename": "quarterly_presentation.pdf",
  "fileSize": 10485760,
  "mimeType": "application/pdf",
  "sender": "MacBook Pro",
  "timestamp": 1730940000000.0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"file_available"` |
| `fileId` | String | Yes | Unique UUID for the download endpoint `/api/download/:fileId` |
| `filename` | String | Yes | Display filename with extension |
| `fileSize` | Int64 | Yes | Total file size in bytes |
| `mimeType` | String | Yes | MIME type (e.g. `"application/pdf"`, `"image/jpeg"`) |
| `sender` | String | Yes | Name of device offering the file |
| `timestamp` | Double | Optional | Epoch millisecond timestamp |

---

#### File Transfer Progress (`file_progress`)
Sent periodically during active file upload or download.

```json
{
  "type": "file_progress",
  "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
  "bytesTransferred": 5242880,
  "totalBytes": 10485760,
  "percentage": 50.0,
  "status": "transferring"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"file_progress"` |
| `fileId` | String | Yes | UUID of the file being transferred |
| `bytesTransferred` | Int64 | Yes | Bytes transferred so far |
| `totalBytes` | Int64 | Yes | Total file size in bytes |
| `percentage` | Double | Yes | Transfer completion percentage (0.0 - 100.0) |
| `status` | String | Yes | Status: `"pending"`, `"transferring"`, `"completed"`, `"failed"` |

---

#### File Transfer Complete (`file_complete`)
Sent upon successful storage of the uploaded file on disk or verification of download.

```json
{
  "type": "file_complete",
  "fileId": "c56a4180-2a8d-4f81-9bfa-89e4c69812df",
  "status": "success",
  "message": "File saved to ~/Downloads/GalaxyContinuity/quarterly_presentation.pdf"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"file_complete"` |
| `fileId` | String | Yes | UUID of the completed file transfer |
| `status` | String | Yes | `"success"` or `"error"` |
| `message` | String | Optional | Human-readable completion or error status description |

---

### 5.4 Screen Mirroring

#### Start Screen Mirroring (`screen_start`)
Sent by macOS Host to Galaxy Client to request live display streaming.

```json
{
  "type": "screen_start",
  "width": 1080,
  "height": 2400,
  "fps": 30,
  "bitrate": 4000000
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"screen_start"` |
| `width` | Integer | Optional | Requested video width in pixels (default: `1080`) |
| `height` | Integer | Optional | Requested video height in pixels (default: `2400`) |
| `fps` | Integer | Optional | Target frames per second (e.g. `30` or `60`) |
| `bitrate` | Integer | Optional | Target encoder bitrate in bps (e.g. `4000000` = 4 Mbps) |

---

#### Stop Screen Mirroring (`screen_stop`)
Sent by either macOS Host or Galaxy Client to terminate screen capture.

```json
{
  "type": "screen_stop",
  "reason": "user_dismissed"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"screen_stop"` |
| `reason` | String | Optional | Reason string (`"user_dismissed"`, `"session_timeout"`, `"error"`) |

---

#### Remote Touch / Mouse Input Event (`input_event`)
Sent by macOS Host viewer window to Galaxy Client to inject touch gestures.

```json
{
  "type": "input_event",
  "action": "down",
  "x": 0.5234,
  "y": 0.7412,
  "button": 0
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_event"` |
| `action` | String | Yes | Gesture action: `"down"`, `"move"`, `"up"`, `"scroll"` |
| `x` | Double | Yes | Normalized horizontal coordinate (`0.0` left to `1.0` right) |
| `y` | Double | Yes | Normalized vertical coordinate (`0.0` top to `1.0` bottom) |
| `button` | Integer | Optional | Mouse button: `0` (Left/Primary), `1` (Right/Secondary), `2` (Middle) |

---

#### Remote Key Navigation Event (`input_key`)
Sent by macOS Host viewer window to Galaxy Client to inject navigation or hardware button presses.

```json
{
  "type": "input_key",
  "key": "BACK",
  "keyCode": 4
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"input_key"` |
| `key` | String | Yes | Semantic key name: `"BACK"`, `"HOME"`, `"RECENTS"`, `"VOLUME_UP"`, `"VOLUME_DOWN"`, `"ENTER"`, `"POWER"` |
| `keyCode` | Integer | Optional | Android `KeyEvent` integer code (e.g. BACK = 4, HOME = 3, RECENTS = 187, ENTER = 66) |

---

### 5.5 Continuity Camera

#### Start Continuity Camera (`camera_start`)
Sent by macOS Host to Galaxy Client to request live Camera2 streaming.

```json
{
  "type": "camera_start",
  "lens": "back",
  "quality": "1080p",
  "fps": 30
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"camera_start"` |
| `lens` | String | Optional | Camera sensor: `"back"` (default), `"front"`, `"ultra_wide"`, `"telephoto"`. (Alias `"facing"` accepted) |
| `quality` | String | Optional | Stream resolution: `"1080p"` (default), `"720p"`, `"4k"`. (Alias `"resolution"` accepted) |
| `fps` | Integer | Optional | Capture frame rate (e.g. `30` or `60`) |

---

#### Stop Continuity Camera (`camera_stop`)
Sent by either macOS Host or Galaxy Client to close the camera session.

```json
{
  "type": "camera_stop"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"camera_stop"` |

---

#### Camera Remote Control (`camera_control`)
Sent by macOS Host to adjust camera settings during an active streaming session.

```json
{
  "type": "camera_control",
  "action": "switch_lens",
  "lens": "front",
  "zoom": 1.5,
  "torch": false
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"camera_control"` |
| `action` | String | Yes | Control action: `"switch_lens"`, `"set_zoom"`, `"toggle_torch"` |
| `lens` | String | Optional | Target lens: `"back"`, `"front"`, `"ultra_wide"`, `"telephoto"` |
| `zoom` | Double | Optional | Digital zoom magnification factor (e.g. `1.0`, `2.0`) |
| `torch` | Boolean | Optional | Flashlight/torch toggle state (`true` on, `false` off) |

---

### 5.6 Notification Synchronization & Quick Reply

#### Forward Phone Notification (`phone_notification`)
Sent by Galaxy Client (`NotificationForwarderService`) to macOS Host.

```json
{
  "type": "phone_notification",
  "id": "notif-uuid-10492",
  "packageName": "org.telegram.messenger",
  "app": "Telegram",
  "title": "Alex",
  "text": "Are you free for lunch?",
  "timestamp": 1730940050000.0,
  "canReply": true
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"phone_notification"` |
| `id` | String | Yes | Stable notification ID key |
| `packageName` | String | Yes | Android package name of originating app (e.g. `"org.telegram.messenger"`) |
| `app` | String | Yes | Display name of the application |
| `title` | String | Yes | Notification title header (sender name / subject) |
| `text` | String | Yes | Notification body content |
| `timestamp` | Double | Optional | Epoch millisecond timestamp of notification |
| `canReply` | Boolean | Optional | `true` if notification supports interactive `RemoteInput` quick reply |

---

#### Notification Quick Reply Action (`notification_reply`)
Sent by macOS Host to Galaxy Client in response to user input in macOS notification action.

```json
{
  "type": "notification_reply",
  "id": "notif-uuid-10492",
  "packageName": "org.telegram.messenger",
  "replyText": "Yes, let's meet at 12:30!"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"notification_reply"` |
| `id` | String | Yes | ID key matching the original `phone_notification` |
| `packageName` | String | Yes | Target Android package name |
| `replyText` | String | Yes | User's response text to inject into `RemoteInput` |

---

### 5.7 Remote Ping & Device Locate (`ping_device`)

Bidirectional locator signal to trigger audible sound and haptic vibration.

```json
{
  "type": "ping_device",
  "source": "mac",
  "message": "Finding your Galaxy..."
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"ping_device"` |
| `source` | String | Yes | Originating sender: `"mac"` (Find My Phone) or `"phone"` (Ping Mac) |
| `message` | String | Optional | User-facing alert text to display |

#### Device Behaviors:
- **Phone when pinged from Mac**:
  - Overrides silent mode audio stream.
  - Plays default notification chime sound.
  - Executes haptic vibration pattern: `[300ms vibrate, 150ms rest, 300ms vibrate, 150ms rest, 400ms vibrate]`.
  - Displays high-priority heads-up banner notification.
- **Mac when pinged from Phone**:
  - Plays macOS system sound (`NSSound(named: "Ping")` or `"Glass"`).
  - Posts macOS user notification banner.

---

### 5.8 Battery State Updates (`battery_update`)

Sent by Galaxy Client to macOS Host upon battery level changes or charging state transitions.

```json
{
  "type": "battery_update",
  "level": 92,
  "isCharging": true
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | String | Yes | Fixed value: `"battery_update"` |
| `level` | Integer | Yes | Current battery percentage (`0` - `100`) |
| `isCharging` | Boolean | Yes | Charging state (`true` if connected to charger, `false` otherwise) |

---

## 6. Error Handling, Loop Prevention & Reconnection Logic

### 6.1 Reconnection & Exponential Backoff
Clients MUST implement exponential backoff reconnection when disconnected:
1. Attempt 1: Immediate retry (0ms delay).
2. Attempt 2: 1 second delay.
3. Attempt 3: 2 seconds delay.
4. Attempt 4: 4 seconds delay.
5. Attempt 5+: Clamped at 10 seconds maximum delay with ±20% jitter.
6. If connection fails for > 15 seconds, client MUST re-trigger multi-transport discovery (mDNS scan -> BLE advertising scan -> Wi-Fi Direct).

### 6.2 Error Handling & Fallback Table

| Error Scenario | Detection | Protocol Recovery Action |
|---|---|---|
| **Invalid/Corrupt JSON** | `JSONDecoder` or `JSONObject` throws parse exception | Log error, discard invalid frame, keep WebSocket open. |
| **Unknown Message Type** | `type` value does not match schema registry | Discard unrecognized type safely without crashing. |
| **Missing File in Download** | `GET /api/download/:fileId` with expired/unknown ID | Server returns `404 Not Found` with `Content-Length: 0`. Client clears pending download. |
| **Duplicate Filename on Upload** | `POST /api/upload` target file already exists on Mac | Server automatically appends ` (1)`, ` (2)` counter before extension. Never overwrites. |
| **Clipboard Echo Loop** | Incoming clipboard hash matches `lastSeenHash` | Suppress local clipboard injection; do not re-broadcast. |
| **Unmasked Client WS Frame** | Byte 1 bit 7 (`mask`) is 0 from client | Low-level server checks `isMasked` flag and reads payload directly without error. |
| **Media Stream Stalling** | No media frames received for > 5000ms | Host sends `screen_stop` or `camera_stop` and prompts user to restart stream. |
| **Wi-Fi Network Dropped** | TCP socket write/read fails with EOF | Transition immediately to offline BLE discovery and Wi-Fi Direct link on `192.168.49.1`. |
