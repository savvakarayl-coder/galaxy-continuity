# Galaxy Continuity — Communication Protocol

Specification for bidirectional communication between macOS and Samsung Galaxy devices.

## Transport
- **Discovery**: Apple Bonjour / mDNS (`_galaxycontinuity._tcp.`, default port `8765`).
- **Events Channel**: WebSocket (`ws://<host>:<port>/ws`).
- **File Transfer**: HTTP multipart upload (`POST /api/upload`) and file download (`GET /api/download/:fileId`).
- **Web Companion**: HTTP (`GET /` or `GET /companion`).

## Message Format (JSON over WebSocket)

### 1. Handshake & Status
```json
{
  "type": "handshake",
  "device": "Samsung Galaxy S24 Ultra",
  "platform": "android",
  "version": "1.0.0",
  "battery": {
    "level": 88,
    "charging": true
  }
}
```

Response from Mac:
```json
{
  "type": "handshake_ack",
  "device": "MacBook Pro",
  "platform": "macOS",
  "version": "1.0.0"
}
```

### 2. Universal Clipboard
```json
{
  "type": "clipboard",
  "content": "https://example.com/interesting-article",
  "contentType": "text/plain",
  "timestamp": 1730940000000,
  "source": "mac" // or "phone"
}
```

### 3. File Transfer Notification
When a file is ready to be fetched by the peer:
```json
{
  "type": "file_available",
  "fileId": "uuid-1234",
  "filename": "vacation_photo.jpg",
  "fileSize": 4518290,
  "mimeType": "image/jpeg",
  "sender": "Samsung Galaxy"
}
```

### 4. Remote Ping ("Find My Phone" / "Ping Mac")
```json
{
  "type": "ping_device",
  "source": "mac",
  "message": "Finding your Galaxy..."
}
```

### 5. Phone Notifications Forwarding
```json
{
  "type": "phone_notification",
  "app": "WhatsApp",
  "title": "Alex",
  "text": "Hey, are you free for lunch?",
  "timestamp": 1730940050000
}
```

### 6. Battery Status Updates
```json
{
  "type": "battery_update",
  "level": 85,
  "charging": false
}
```
