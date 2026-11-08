import AppKit
import Foundation

public final class ScreenMirroringService: @unchecked Sendable {
    public static let shared = ScreenMirroringService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.screenmirroring", qos: .userInteractive)
    private var stallCheckTimer: DispatchSourceTimer?
    private var lastFrameReceivedDate: Date?
    private let h264Decoder = H264Decoder()

    private init() {
        h264Decoder.onFrameDecoded = { image in
            Task { @MainActor in
                DeviceState.shared.updateScreenFrame(image)
            }
        }
    }

    public static func makeStreamPacket(streamType: UInt8 = 0x01, payload: Data) -> Data {
        var packet = Data([streamType])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    public static func parseStreamPacket(_ packet: Data) throws -> (streamType: UInt8, length: Int, payload: Data) {
        guard packet.count >= 5 else {
            throw NSError(
                domain: "ScreenMirroring",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stream packet shorter than 5-byte header"]
            )
        }
        let streamType = packet[0]
        let length = Int(UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 8 | UInt32(packet[4]))
        let payload = packet.count > 5 ? packet.subdata(in: 5..<min(packet.count, 5 + length)) : Data()
        return (streamType, length, payload)
    }

    public func startMirroring(width: Int = 720, height: Int = 1600, fps: Int = 30, bitrate: Int = 3000000) {
        let msg = ContinuityMessage(
            type: "screen_start",
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate
        )
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(true, width: width, height: height, fps: fps, bitrate: bitrate)
        }
        startStallWatchdog()
    }

    public func stopMirroring(reason: String = "user_dismissed") {
        let msg = ContinuityMessage(type: "screen_stop", reason: reason)
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(false)
        }
        h264Decoder.reset()
        stopStallWatchdog()
    }

    private var adbPath: String? = {
        let candidates = [
            "/tmp/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private func dispatchAdbInput(args: [String]) {
        guard let adb = adbPath else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = ["shell", "input"] + args
            try? proc.run()
        }
    }

    private var lastDownX: Double = 0.5
    private var lastDownY: Double = 0.5
    private var lastDownTime: Date = Date()

    public func sendInputEvent(action: String, x: Double, y: Double, button: Int = 0) {
        let clampedX = max(0.0, min(1.0, x))
        let clampedY = max(0.0, min(1.0, y))
        let msg = ContinuityMessage(
            type: "input_event",
            action: action,
            x: clampedX,
            y: clampedY,
            button: button
        )
        ServerManager.shared.broadcastMessage(msg)

        if action == "down" {
            lastDownX = clampedX
            lastDownY = clampedY
            lastDownTime = Date()
        } else if action == "up" {
            let px = Int(clampedX * 1080.0)
            let py = Int(clampedY * 2400.0)
            let startPx = Int(lastDownX * 1080.0)
            let startPy = Int(lastDownY * 2400.0)
            let dist = hypot(Double(px - startPx), Double(py - startPy))
            let duration = max(50, min(600, Int(Date().timeIntervalSince(lastDownTime) * 1000)))
            if dist > 25 {
                dispatchAdbInput(args: ["swipe", "\(startPx)", "\(startPy)", "\(px)", "\(py)", "\(duration)"])
            } else {
                dispatchAdbInput(args: ["tap", "\(px)", "\(py)"])
            }
        }
    }

    public func sendTextInput(text: String) {
        let msg = ContinuityMessage(type: "input_text", text: text)
        ServerManager.shared.broadcastMessage(msg)

        // Only dispatch ADB fallback when WebSocket is NOT connected to prevent duplicate text input
        guard !ServerManager.shared.hasActiveClients else { return }

        // Only dispatch ADB fallback if text is pure ASCII without newlines to prevent Android OS NullPointerException
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && !$0.isNewline }) else { return }

        // ADB fast-path: escape shell metacharacters, single/double quotes, and replace spaces with %s
        var escaped = ""
        escaped.reserveCapacity(text.count * 2)
        for char in text {
            switch char {
            case " ":
                escaped.append("%s")
            case "\\", "'", "\"", "$", "`", "&", ";", "(", ")", "|", "<", ">", "*", "?", "[", "]", "{", "}", "~", "!", "#":
                escaped.append("\\")
                escaped.append(char)
            default:
                escaped.append(char)
            }
        }
        if !escaped.isEmpty {
            dispatchAdbInput(args: ["text", escaped])
        }
    }

    public func sendScrollEvent(x: Double, y: Double, dx: Double, dy: Double) {
        let clampedX = max(0.0, min(1.0, x))
        let clampedY = max(0.0, min(1.0, y))
        let msg = ContinuityMessage(
            type: "input_scroll",
            action: "scroll",
            x: clampedX,
            y: clampedY,
            dx: dx,
            dy: dy
        )
        ServerManager.shared.broadcastMessage(msg)

        // ADB fast-path touch swipe fallback (only when WebSocket is NOT connected)
        guard !ServerManager.shared.hasActiveClients else { return }
        let startPx = Int(clampedX * 1080.0)
        let startPy = Int(clampedY * 2400.0)
        let endPx = max(0, min(1080, startPx - Int(dx * 4.0)))
        let endPy = max(0, min(2400, startPy - Int(dy * 4.0)))
        if abs(dx) > 1 || abs(dy) > 1 {
            dispatchAdbInput(args: ["swipe", "\(startPx)", "\(startPy)", "\(endPx)", "\(endPy)", "100"])
        }
    }

    public func sendScrollInput(x: Double, y: Double, dx: Double, dy: Double) {
        sendScrollEvent(x: x, y: y, dx: dx, dy: dy)
    }

    public func sendKeyInput(key: String, keyCode: Int? = nil) {
        var resolvedCode = keyCode
        let keyUpper = key.uppercased()
        if resolvedCode == nil {
            if keyUpper == "BACK" { resolvedCode = 4 }
            else if keyUpper == "HOME" { resolvedCode = 3 }
            else if keyUpper == "RECENTS" { resolvedCode = 187 }
            else if keyUpper == "NOTIFICATIONS" { resolvedCode = 83 }
            else if keyUpper == "POWER" || keyUpper == "LOCK" { resolvedCode = 26 }
            else if keyUpper == "BACKSPACE" || keyUpper == "DEL" { resolvedCode = 67 }
            else if keyUpper == "ENTER" || keyUpper == "RETURN" { resolvedCode = 66 }
            else if keyUpper == "TAB" { resolvedCode = 61 }
            else if keyUpper == "ESCAPE" || keyUpper == "ESC" { resolvedCode = 111 }
            else if keyUpper == "SPACE" { resolvedCode = 62 }
            else if keyUpper == "DPAD_UP" || keyUpper == "UP" { resolvedCode = 19 }
            else if keyUpper == "DPAD_DOWN" || keyUpper == "DOWN" { resolvedCode = 20 }
            else if keyUpper == "DPAD_LEFT" || keyUpper == "LEFT" { resolvedCode = 21 }
            else if keyUpper == "DPAD_RIGHT" || keyUpper == "RIGHT" { resolvedCode = 22 }
        }

        let msg = ContinuityMessage(
            type: "input_key",
            key: key,
            keyCode: resolvedCode
        )
        ServerManager.shared.broadcastMessage(msg)

        // Only dispatch ADB fallback when WebSocket is NOT connected to prevent duplicate key injection
        guard !ServerManager.shared.hasActiveClients else { return }
        if let code = resolvedCode, code > 0 {
            dispatchAdbInput(args: ["keyevent", "\(code)"])
        }
    }

    public func handleIncomingFrame(_ frameData: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lastFrameReceivedDate = Date()
            if self.isStillImage(frameData) {
                if let image = NSImage(data: frameData) {
                    Task { @MainActor in
                        DeviceState.shared.updateScreenFrame(image)
                    }
                }
            } else {
                self.h264Decoder.decode(annexB: frameData)
            }
        }
    }

    private func isStillImage(_ data: Data) -> Bool {
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
            return true // JPEG SOI
        }
        if data.count >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
            return true // PNG magic
        }
        return false
    }

    public func handlePeerScreenStart(message: ContinuityMessage) {
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(
                true,
                width: message.width,
                height: message.height,
                fps: message.fps,
                bitrate: message.bitrate
            )
        }
        startStallWatchdog()
    }

    public func handlePeerScreenStop(message: ContinuityMessage) {
        Task { @MainActor in
            DeviceState.shared.setScreenMirroringActive(false)
        }
        h264Decoder.reset()
        stopStallWatchdog()
    }

    public func handlePeerInputEvent(message: ContinuityMessage) {
        print("[ScreenMirroringService] Inbound input event: action=\(message.action ?? "") x=\(message.x ?? 0) y=\(message.y ?? 0)")
    }

    public func handlePeerInputKey(message: ContinuityMessage) {
        print("[ScreenMirroringService] Inbound input key: key=\(message.key ?? "") keyCode=\(message.keyCode ?? 0)")
    }

    public var stallTimeout: TimeInterval = 5.0

    private func startStallWatchdog() {
        stopStallWatchdog()
        lastFrameReceivedDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let last = self.lastFrameReceivedDate else { return }
            if Date().timeIntervalSince(last) >= self.stallTimeout {
                print("[ScreenMirroringService] Stream stalled (>=\(Int(self.stallTimeout))s), issuing screen_stop")
                self.stopMirroring(reason: "stream_stalled")
            }
        }
        timer.resume()
        stallCheckTimer = timer
    }

    private func stopStallWatchdog() {
        stallCheckTimer?.cancel()
        stallCheckTimer = nil
    }
}
