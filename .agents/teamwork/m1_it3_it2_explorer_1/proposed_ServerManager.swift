import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

final class ConnectedClient {
    let id: UUID
    let fd: Int32
    var isWebSocket: Bool = false
    var readBuffer = Data()
    var readSource: DispatchSourceRead?
    var deviceName: String = "Samsung Galaxy"
    var platform: String = "Unknown"

    // RFC 6455 § 5.4 Fragmentation Reassembly Buffer
    var fragmentOpcode: UInt8? = nil
    var fragmentBuffer = Data()

    init(id: UUID = UUID(), fd: Int32) {
        self.id = id
        self.fd = fd
    }

    func resetFragmentationState() {
        fragmentOpcode = nil
        fragmentBuffer.removeAll(keepingCapacity: false)
    }

    func close() {
        readSource?.cancel()
        Darwin.close(fd)
        resetFragmentationState()
    }
}

public final class ServerManager {
    public static let shared = ServerManager()

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.galaxycontinuity.server", qos: .userInitiated)
    private var clients: [UUID: ConnectedClient] = [:]
    private var sharedFiles: [String: (filename: String, url: URL)] = [:]
    private var cameraStreamClients: [UUID: ConnectedClient] = [:]

    public private(set) var currentPort: Int = 8765

    private static let serverQueueKey = DispatchSpecificKey<Void>()

    public var hasActiveClients: Bool {
        if DispatchQueue.getSpecific(key: Self.serverQueueKey) != nil {
            return clients.values.contains { $0.isWebSocket }
        } else {
            return serverQueue.sync {
                clients.values.contains { $0.isWebSocket }
            }
        }
    }

    public var downloadsDirectory: URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dir = downloads.appendingPathComponent("GalaxyContinuity", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var sharedCacheDirectory: URL {
        let dir = downloadsDirectory.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        serverQueue.setSpecific(key: Self.serverQueueKey, value: ())
    }

    public func start(port: Int = 8765) {
        stop()
        self.currentPort = port

        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupSocket(port: port)
        }
    }

    public func stop() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.acceptSource?.cancel()
            self.acceptSource = nil

            for client in self.clients.values {
                client.close()
            }
            self.clients.removeAll()
            self.cameraStreamClients.removeAll()

            if self.serverSocket >= 0 {
                Darwin.close(self.serverSocket)
                self.serverSocket = -1
            }

            Task { @MainActor in
                DeviceState.shared.isServerRunning = false
                DeviceState.shared.setDisconnected()
            }
        }
    }

    private func setupSocket(port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[ServerManager] Failed to create socket: \(errno)")
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0) // 0.0.0.0

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes == 0 else {
            print("[ServerManager] Bind failed on port \(port): \(errno)")
            Darwin.close(fd)
            return
        }

        guard listen(fd, 16) == 0 else {
            print("[ServerManager] Listen failed on port \(port): \(errno)")
            Darwin.close(fd)
            return
        }

        self.serverSocket = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.resume()
        self.acceptSource = source

        let ip = self.detectLocalIP() ?? "127.0.0.1"

        Task { @MainActor in
            DeviceState.shared.isServerRunning = true
            DeviceState.shared.serverPort = port
            DeviceState.shared.localIPAddress = ip
        }

        print("[ServerManager] Galaxy Continuity Server listening on \(ip):\(port)")
    }

    private func acceptConnections() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &addrLen)
            }
        }

        guard clientFd >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        let client = ConnectedClient(fd: clientFd)
        clients[client.id] = client

        let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: serverQueue)
        client.readSource = readSource

        readSource.setEventHandler { [weak self, weak client] in
            guard let self = self, let client = client else { return }
            self.readFromClient(client)
        }

        readSource.setCancelHandler { [weak client] in
            guard let client = client else { return }
            Darwin.close(client.fd)
        }

        readSource.resume()
    }

    private func readFromClient(_ client: ConnectedClient) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(client.fd, &buffer, buffer.count)

        if bytesRead <= 0 {
            removeClient(client)
            return
        }

        client.readBuffer.append(buffer, count: bytesRead)

        if client.isWebSocket {
            processWebSocketData(client)
        } else {
            processHTTPData(client)
        }
    }

    private func removeClient(_ client: ConnectedClient) {
        cameraStreamClients.removeValue(forKey: client.id)
        client.close()
        clients.removeValue(forKey: client.id)

        if clients.isEmpty {
            Task { @MainActor in
                DeviceState.shared.setDisconnected()
            }
        }
    }

    // MARK: - HTTP Handling
    private func processHTTPData(_ client: ConnectedClient) {
        guard let headerEndRange = client.readBuffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.readBuffer.count > 100000 {
                removeClient(client)
            }
            return
        }

        let headerData = client.readBuffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            removeClient(client)
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            removeClient(client)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            removeClient(client)
            return
        }

        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // WebSocket Upgrade
        if headers["upgrade"]?.lowercased() == "websocket", let wsKey = headers["sec-websocket-key"] {
            performWebSocketHandshake(client: client, key: wsKey, headerEndOffset: headerEndRange.upperBound)
            return
        }

        // POST /api/upload
        if method == "POST" && path == "/api/upload" {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStartIndex = headerEndRange.upperBound

            if client.readBuffer.count >= bodyStartIndex + contentLength {
                let fileData = client.readBuffer.subdata(in: bodyStartIndex..<(bodyStartIndex + contentLength))
                client.readBuffer.removeSubrange(0..<(bodyStartIndex + contentLength))

                let rawFilename = headers["x-filename"]
                let safeFilename = ServerManager.sanitizeUploadFilename(rawFilename)
                saveUploadedFile(name: safeFilename, data: fileData, sender: client.deviceName)

                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}"
                sendRaw(client: client, data: Data(response.utf8))
            }
            return
        }

        // GET / or /companion
        if method == "GET" && (path == "/" || path == "/companion" || path.starts(with: "/?")) {
            client.readBuffer.removeAll()
            let htmlData = Data(WebAssets.html.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(htmlData.count)\r\n\r\n"
            sendRaw(client: client, data: Data(response.utf8) + htmlData)
            removeClient(client)
            return
        }

        // GET /api/download/:fileId
        if method == "GET" && path.starts(with: "/api/download/") {
            client.readBuffer.removeAll()
            let fileId = String(path.dropFirst("/api/download/".count))

            if let fileInfo = sharedFiles[fileId],
               FileManager.default.fileExists(atPath: fileInfo.url.path),
               let fileHandle = try? FileHandle(forReadingFrom: fileInfo.url) {

                let fileSize = (try? fileInfo.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let encodedName = fileInfo.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileInfo.filename
                let mimeType = UTType(filenameExtension: fileInfo.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

                let headerStr = "HTTP/1.1 200 OK\r\nContent-Type: \(mimeType)\r\nContent-Disposition: attachment; filename=\"\(encodedName)\"\r\nContent-Length: \(fileSize)\r\nConnection: close\r\n\r\n"
                sendRaw(client: client, data: Data(headerStr.utf8))

                // Stream chunks (64 KB)
                let chunkSize = 65536
                var bytesSent: Int64 = 0
                while bytesSent < Int64(fileSize) {
                    let chunkData = fileHandle.readData(ofLength: chunkSize)
                    if chunkData.isEmpty { break }
                    sendRaw(client: client, data: chunkData)
                    bytesSent += Int64(chunkData.count)

                    let pct = fileSize > 0 ? (Double(bytesSent) / Double(fileSize) * 100.0) : 100.0
                    let progressMsg = ContinuityMessage(
                        type: "file_progress",
                        fileId: fileId,
                        filename: fileInfo.filename,
                        bytesTransferred: bytesSent,
                        totalBytes: Int64(fileSize),
                        percentage: pct,
                        status: bytesSent >= Int64(fileSize) ? "completed" : "transferring"
                    )
                    self.broadcastMessage(progressMsg)
                }
                try? fileHandle.close()
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                sendRaw(client: client, data: Data(notFound.utf8))
            }
            removeClient(client)
            return
        }

        // GET /api/camera/stream, /camera/mjpeg, /api/camera/snapshot, /camera/snapshot
        if method == "GET" && (path == "/api/camera/stream" || path == "/camera/mjpeg" || path == "/api/camera/snapshot" || path == "/camera/snapshot" || path.starts(with: "/api/camera/stream?") || path.starts(with: "/camera/mjpeg?")) {
            client.readBuffer.removeAll()
            guard let jpeg = VirtualWebcamFeeder.shared.getLatestJpeg() else {
                let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                sendRaw(client: client, data: Data(response.utf8))
                removeClient(client)
                return
            }

            let isSnapshotRequest = path.contains("snapshot") || path.contains("single=true") || (headers["accept"]?.lowercased().contains("image/jpeg") == true)
            let isExplicitStreamRequest = path.contains("stream=true") || path.contains("mjpeg=true") || (headers["accept"]?.lowercased().contains("multipart") == true)

            // If client specifically requests continuous streaming (e.g. multipart Accept header or stream=true query):
            if isExplicitStreamRequest && !isSnapshotRequest {
                let mjpegHeader = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
                sendRaw(client: client, data: Data(mjpegHeader.utf8))

                let frameHeader = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
                let frameFooter = "\r\n"
                sendRaw(client: client, data: Data(frameHeader.utf8) + jpeg + Data(frameFooter.utf8))

                cameraStreamClients[client.id] = client
                return
            }

            // Default snapshot response (preserves test_adversarial_camera.py test_07 & test_08)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nConnection: close\r\n\r\n"
            sendRaw(client: client, data: Data(response.utf8) + jpeg)
            removeClient(client)
            return
        }

        // Default 404
        client.readBuffer.removeAll()
        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        sendRaw(client: client, data: Data(notFound.utf8))
        removeClient(client)
    }

    // MARK: - Filename Sanitization & Path Confinement
    public static func sanitizeUploadFilename(_ raw: String?) -> String {
        let fallback = "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
        guard let raw = raw else { return fallback }

        var name = raw
        if let decoded = name.removingPercentEncoding {
            name = decoded
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if raw/decoded string is empty or composed solely of dots, slashes, or backslashes
        // (e.g. "", ".", "..", "...", "/", "\\") before URL(fileURLWithPath:) resolves it to CWD
        if name.isEmpty || name.allSatisfy({ $0 == "." || $0 == "/" || $0 == "\\" }) {
            return fallback
        }

        // Extract terminal path component to discard all directory traversal prefixes
        var candidate = URL(fileURLWithPath: name).lastPathComponent

        // Strip any Windows-style backslash components
        if let lastBackslash = candidate.split(separator: "\\").last {
            candidate = String(lastBackslash)
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Disallow empty, root "/", "."-prefixed (hidden files or . / ..), and path separators
        if candidate.isEmpty || candidate == "/" || candidate.hasPrefix(".") || candidate.contains("/") || candidate.contains("\\") {
            return fallback
        }

        return candidate
    }

    private func saveUploadedFile(name: String, data: Data, sender: String) {
        let safeName = ServerManager.sanitizeUploadFilename(name)
        let destDir = self.downloadsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var targetUrl = destDir.appendingPathComponent(safeName).standardizedFileURL.resolvingSymlinksInPath()

        // Enforce strict confinement: targetUrl must resolve immediately within destDir
        guard targetUrl.deletingLastPathComponent().path == destDir.path else {
            print("[ServerManager] Security alert: resolved path \(targetUrl.path) is outside downloads directory \(destDir.path)")
            return
        }

        var counter = 1
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = destDir.appendingPathComponent(newName).standardizedFileURL.resolvingSymlinksInPath()
            counter += 1
        }

        guard targetUrl.deletingLastPathComponent().path == destDir.path else {
            print("[ServerManager] Security alert: deduplicated path \(targetUrl.path) is outside downloads directory \(destDir.path)")
            return
        }

        do {
            try data.write(to: targetUrl)
            let finalName = targetUrl.lastPathComponent
            let size = Int64(data.count)

            print("[ServerManager] File successfully saved: \(targetUrl.path) (\(size) bytes)")

            Task { @MainActor in
                let item = FileTransferItem(
                    filename: finalName,
                    fileSize: size,
                    isOutgoing: false,
                    date: Date(),
                    localPath: targetUrl
                )
                DeviceState.shared.addFileTransfer(item)

                NotificationService.shared.showNotification(
                    title: "⚡ Quick Drop from \(sender)",
                    subtitle: "Saved to ~/Downloads/GalaxyContinuity",
                    body: "\(finalName) (\(item.formattedSize))"
                )

                // Send file_complete confirmation
                let completeMsg = ContinuityMessage(
                    type: "file_complete",
                    fileId: UUID().uuidString,
                    filename: finalName,
                    message: "File saved to ~/Downloads/GalaxyContinuity/\(finalName)",
                    status: "success"
                )
                self.broadcastMessage(completeMsg)
            }
        } catch {
            print("[ServerManager] Failed to write uploaded file: \(error)")
        }
    }

    // MARK: - WebSocket Handshake & Framing
    private func performWebSocketHandshake(client: ConnectedClient, key: String, headerEndOffset: Int) {
        client.readBuffer.removeSubrange(0..<headerEndOffset)

        let acceptValue = WebSocketFramer.computeAcceptKey(for: key)

        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptValue)\r\n\r\n"
        sendRaw(client: client, data: Data(response.utf8))

        client.isWebSocket = true
        print("[ServerManager] Client connected over WebSocket: \(client.id)")

        // Send handshake ack & current clipboard
        let macName = Host.current().localizedName ?? "MacBook Pro"
        let ack = ContinuityMessage(type: "handshake_ack", device: macName, platform: "macOS", version: "1.0.0")
        sendWebSocketMessage(client: client, message: ack)

        Task { @MainActor in
            if !DeviceState.shared.lastSharedClipboard.isEmpty {
                let clipMsg = ContinuityMessage(
                    type: "clipboard",
                    content: DeviceState.shared.lastSharedClipboard,
                    contentType: DeviceState.shared.lastSharedClipboardType,
                    source: "mac",
                    payload: DeviceState.shared.lastSharedClipboard
                )
                self.sendWebSocketMessage(client: client, message: clipMsg)
            }
        }
    }

    private func processWebSocketData(_ client: ConnectedClient) {
        while let frame = WebSocketFramer.decodeFrame(from: &client.readBuffer) {
            handleWebSocketFrame(client: client, frame: frame)
        }
    }

    func handleWebSocketFrame(client: ConnectedClient, frame: WebSocketFrame) {
        // Control frames (opcode >= 0x8) MUST NOT be fragmented (RFC 6455 § 5.5)
        // and MAY be interleaved within fragmented data messages (RFC 6455 § 5.4).
        // Control frames MUST NOT disrupt the current fragment reassembly buffer.
        if frame.opcode >= 0x8 {
            switch frame.opcode {
            case 0x8: // Close
                sendFrame(client: client, opcode: 0x8, payload: frame.payload.prefix(2))
                removeClient(client)

            case 0x9: // Ping -> reply with Pong
                sendFrame(client: client, opcode: 0xA, payload: frame.payload)

            case 0xA: // Pong heartbeat response
                break

            default:
                print("[ServerManager] Dropping unassigned control opcode: \(frame.opcode)")
                break
            }
            return
        }

        // Data frames (opcode < 0x8)
        let maxMessageSize = 64 * 1024 * 1024 // 64 MB DoS guard

        switch frame.opcode {
        case 0x0: // Continuation frame
            guard let initialOpcode = client.fragmentOpcode else {
                print("[ServerManager] Warning: Received continuation frame (0x0) without active fragmented message; dropping")
                return
            }

            if client.fragmentBuffer.count + frame.payload.count > maxMessageSize {
                print("[ServerManager] Error: Fragmented payload exceeded maximum size limit (\(maxMessageSize) bytes); aborting message")
                client.resetFragmentationState()
                return
            }

            client.fragmentBuffer.append(frame.payload)

            if frame.fin {
                let completePayload = client.fragmentBuffer
                let completeOpcode = initialOpcode
                client.resetFragmentationState()
                dispatchCompleteMessage(client: client, opcode: completeOpcode, payload: completePayload)
            }

        case 0x1, 0x2: // Initial Text (0x1) or Binary (0x2) data frame
            if client.fragmentOpcode != nil {
                print("[ServerManager] Warning: Received new data frame (opcode \(frame.opcode)) before previous fragmented message completed; resetting buffer")
                client.resetFragmentationState()
            }

            if frame.fin {
                // Complete unfragmented message
                dispatchCompleteMessage(client: client, opcode: frame.opcode, payload: frame.payload)
            } else {
                // First fragment of fragmented message
                if frame.payload.count > maxMessageSize {
                    print("[ServerManager] Error: Initial fragment exceeded maximum size limit (\(maxMessageSize) bytes)")
                    return
                }
                client.fragmentOpcode = frame.opcode
                client.fragmentBuffer = frame.payload
            }

        default: // Reserved/unassigned non-control opcodes (0x3 - 0x7)
            print("[ServerManager] Warning: Dropping frame with unassigned non-control opcode: \(frame.opcode)")
            break
        }
    }

    private func dispatchCompleteMessage(client: ConnectedClient, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1: // Text frame (UTF-8 JSON)
            guard let string = String(data: payload, encoding: .utf8),
                  let jsonData = string.data(using: .utf8) else {
                print("[ServerManager] Discarding text frame: invalid UTF-8 payload")
                return
            }

            if let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData) {
                handleIncomingMessage(client: client, message: message)
            } else {
                print("[ServerManager] Failed to decode ContinuityMessage JSON: \(string.prefix(200))")
            }

        case 0x2: // Binary frame (e.g. Media stream packet)
            handleIncomingBinaryFrame(client: client, payload: payload)

        default:
            break
        }
    }

    private func handleIncomingBinaryFrame(client: ConnectedClient, payload: Data) {
        guard payload.count >= 5 else {
            print("[ServerManager] Dropping truncated binary stream packet (< 5 bytes)")
            return
        }
        let streamType = payload[0]
        let declaredLength = UInt32(payload[1]) << 24 | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 8 | UInt32(payload[4])
        let mediaPayload = payload.count > 5 ? payload.subdata(in: 5..<min(payload.count, 5 + Int(declaredLength))) : Data()

        switch streamType {
        case 0x01: // Screen Mirroring
            ScreenMirroringService.shared.handleIncomingFrame(mediaPayload)
        case 0x02: // Continuity Camera
            ContinuityCameraService.shared.handleIncomingFrame(mediaPayload)
        default:
            print("[ServerManager] Unrecognized stream type: \(streamType)")
        }
    }

    private func handleIncomingMessage(client: ConnectedClient, message: ContinuityMessage) {
        switch message.type {
        case "handshake":
            let dev = message.device ?? "Samsung Galaxy"
            let plat = message.platform ?? "android"
            client.deviceName = dev
            client.platform = plat

            Task { @MainActor in
                DeviceState.shared.setConnected(device: dev, platform: plat, battery: message.battery)
                NotificationService.shared.showNotification(
                    title: "⚡ Galaxy Connected",
                    body: "\(dev) is now paired via Continuity"
                )
            }

        case "clipboard":
            if let content = message.content ?? message.payload {
                let contentType = message.contentType ?? "text/plain"
                let hash = message.hash
                Task { @MainActor in
                    ClipboardSyncService.shared.handleIncomingClipboard(
                        content: content,
                        contentType: contentType,
                        hash: hash,
                        sender: client.deviceName
                    )
                }
            }

        case "file_progress":
            QuickDropService.shared.handleProgressUpdate(message: message)

        case "file_complete":
            QuickDropService.shared.handleTransferComplete(message: message)

        case "battery_update":
            if let level = message.level {
                Task { @MainActor in
                    DeviceState.shared.updateBattery(level: level, charging: message.isCharging ?? false)
                }
            }

        case "ping_device":
            Task { @MainActor in
                NSSound(named: "Ping")?.play()
                NotificationService.shared.showNotification(
                    title: "🔔 \(client.deviceName)",
                    body: message.message ?? "Galaxy is pinging your Mac!"
                )
            }

        case "phone_notification":
            let app = message.app ?? "Samsung Phone"
            let title = message.title ?? app
            let text = message.text ?? ""
            let notifId = message.id ?? UUID().uuidString
            let pkg = message.packageName ?? ""
            let canReply = message.canReply ?? false
            Task { @MainActor in
                NotificationService.shared.showPhoneNotification(
                    id: notifId,
                    packageName: pkg,
                    appName: app,
                    title: title,
                    body: text,
                    canReply: canReply
                )
            }

        case "screen_start":
            ScreenMirroringService.shared.handlePeerScreenStart(message: message)

        case "screen_stop":
            ScreenMirroringService.shared.handlePeerScreenStop(message: message)

        case "input_event":
            ScreenMirroringService.shared.handlePeerInputEvent(message: message)

        case "input_key":
            ScreenMirroringService.shared.handlePeerInputKey(message: message)

        case "camera_start":
            ContinuityCameraService.shared.handlePeerCameraStart(message: message)

        case "camera_stop":
            ContinuityCameraService.shared.handlePeerCameraStop(message: message)

        case "camera_switch_lens":
            ContinuityCameraService.shared.handlePeerSwitchLens(message: message)

        case "camera_control":
            ContinuityCameraService.shared.handlePeerCameraControl(message: message)

        default:
            break
        }
    }

    // MARK: - Outgoing WebSocket Messages
    public func broadcastMessage(_ message: ContinuityMessage) {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.clients.values where client.isWebSocket {
                self.sendWebSocketMessage(client: client, message: message)
            }
        }
    }

    public func broadcastBinary(_ data: Data) {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.clients.values where client.isWebSocket {
                self.sendFrame(client: client, opcode: 0x2, payload: data)
            }
        }
    }

    private func sendWebSocketMessage(client: ConnectedClient, message: ContinuityMessage) {
        guard let jsonData = try? JSONEncoder().encode(message) else { return }
        sendFrame(client: client, opcode: 0x1, payload: jsonData)
    }

    private func sendFrame(client: ConnectedClient, opcode: UInt8, payload: Data) {
        let frame = WebSocketFramer.encodeFrame(opcode: opcode, payload: payload, fin: true, isMasked: false)
        sendRaw(client: client, data: frame)
    }

    private func sendRaw(client: ConnectedClient, data: Data) {
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(client.fd, ptr.baseAddress, data.count)
        }
    }

    // MARK: - Mac to Galaxy File Share
    public func shareFileToGalaxy(fileURL: URL) {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            let fileId = UUID().uuidString
            let filename = fileURL.lastPathComponent
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            self.sharedFiles[fileId] = (filename: filename, url: fileURL)

            Task { @MainActor in
                let item = FileTransferItem(
                    id: fileId,
                    filename: filename,
                    fileSize: Int64(size),
                    isOutgoing: true,
                    date: Date(),
                    localPath: fileURL
                )
                DeviceState.shared.addFileTransfer(item)
            }

            let msg = ContinuityMessage(
                type: "file_available",
                fileId: fileId,
                filename: filename,
                fileSize: Int64(size),
                mimeType: "application/octet-stream",
                sender: Host.current().localizedName ?? "Mac"
            )
            self.broadcastMessage(msg)
        }
    }

    public func sendNotificationReply(id: String, packageName: String, replyText: String) {
        let msg = ContinuityMessage(
            type: "notification_reply",
            id: id,
            replyText: replyText,
            packageName: packageName
        )
        self.broadcastMessage(msg)
    }

    public func sendNotificationOpen(id: String, packageName: String) {
        let msg = ContinuityMessage(
            type: "notification_open",
            id: id,
            packageName: packageName
        )
        self.broadcastMessage(msg)
    }

    // MARK: - IP helper
    public func detectLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.starts(with: "en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    if !ip.starts(with: "127.") {
                        address = ip
                        break
                    }
                }
            }
        }
        return address
    }

    // MARK: - Camera MJPEG Stream Broadcasting
    public func broadcastCameraJpeg(_ jpeg: Data) {
        serverQueue.async { [weak self] in
            guard let self = self, !self.cameraStreamClients.isEmpty else { return }
            let frameHeader = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
            let frameFooter = "\r\n"
            let packet = Data(frameHeader.utf8) + jpeg + Data(frameFooter.utf8)

            var deadClientIds: [UUID] = []
            for (id, client) in self.cameraStreamClients {
                let fd = client.fd
                let sent = packet.withUnsafeBytes { rawBuf in
                    Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
                }
                if sent <= 0 {
                    deadClientIds.append(id)
                }
            }
            for id in deadClientIds {
                if let client = self.cameraStreamClients.removeValue(forKey: id) {
                    self.removeClient(client)
                }
            }
        }
    }

    public func stopCameraStreaming() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.cameraStreamClients.values {
                let endBoundary = "--frame--\r\n"
                self.sendRaw(client: client, data: Data(endBoundary.utf8))
                self.removeClient(client)
            }
            self.cameraStreamClients.removeAll()
        }
    }
}
