import AppKit
import CryptoKit
import Darwin
import Foundation

final class ConnectedClient {
    let id: UUID
    let fd: Int32
    var isWebSocket: Bool = false
    var readBuffer = Data()
    var readSource: DispatchSourceRead?
    var deviceName: String = "Samsung Galaxy"
    var platform: String = "Unknown"

    init(id: UUID = UUID(), fd: Int32) {
        self.id = id
        self.fd = fd
    }

    func close() {
        readSource?.cancel()
        Darwin.close(fd)
    }
}

public final class ServerManager {
    public static let shared = ServerManager()

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.galaxycontinuity.server", qos: .userInitiated)
    private var clients: [UUID: ConnectedClient] = [:]
    private var sharedFiles: [String: (filename: String, url: URL)] = [:]

    public private(set) var currentPort: Int = 8765

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

    private init() {}

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

                var rawFilename = headers["x-filename"] ?? "Received_File_\(Int(Date().timeIntervalSince1970)).bin"
                if let decoded = rawFilename.removingPercentEncoding {
                    rawFilename = decoded
                }

                saveUploadedFile(name: rawFilename, data: fileData, sender: client.deviceName)

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
            if let fileInfo = sharedFiles[fileId], let fileData = try? Data(contentsOf: fileInfo.url) {
                let encodedName = fileInfo.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileInfo.filename
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(encodedName)\"\r\nContent-Length: \(fileData.count)\r\n\r\n"
                sendRaw(client: client, data: Data(headers.utf8) + fileData)
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                sendRaw(client: client, data: Data(notFound.utf8))
            }
            removeClient(client)
            return
        }

        // Default 404
        client.readBuffer.removeAll()
        let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        sendRaw(client: client, data: Data(notFound.utf8))
        removeClient(client)
    }

    private func saveUploadedFile(name: String, data: Data, sender: String) {
        let destDir = self.downloadsDirectory
        var targetUrl = destDir.appendingPathComponent(name)

        var counter = 1
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = destDir.appendingPathComponent(newName)
            counter += 1
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
                    contentType: "text/plain",
                    source: "mac"
                )
                self.sendWebSocketMessage(client: client, message: clipMsg)
            }
        }
    }

    private func processWebSocketData(_ client: ConnectedClient) {
        while let frame = WebSocketFramer.decodeFrame(from: &client.readBuffer) {
            handleWebSocketFrame(client: client, opcode: frame.opcode, payload: frame.payload)
        }
    }

    private func handleWebSocketFrame(client: ConnectedClient, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1: // Text frame
            if let string = String(data: payload, encoding: .utf8),
               let jsonData = string.data(using: .utf8),
               let message = try? JSONDecoder().decode(ContinuityMessage.self, from: jsonData) {
                handleIncomingMessage(client: client, message: message)
            }

        case 0x8: // Close
            removeClient(client)

        case 0x9: // Ping -> Pong
            sendFrame(client: client, opcode: 0xA, payload: payload)

        default:
            break
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
            if let content = message.content {
                Task { @MainActor in
                    ClipboardSyncService.shared.handleIncomingClipboard(text: content, sender: client.deviceName)
                }
            }

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
            Task { @MainActor in
                NotificationService.shared.showNotification(
                    title: "📱 \(title)",
                    subtitle: "via \(app)",
                    body: text
                )
            }

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
}
