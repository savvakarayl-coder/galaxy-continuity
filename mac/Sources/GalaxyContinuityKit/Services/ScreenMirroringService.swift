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

    public func startMirroring(width: Int = 1080, height: Int = 2400, fps: Int = 30, bitrate: Int = 4000000) {
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
    }

    public func sendKeyInput(key: String, keyCode: Int? = nil) {
        let msg = ContinuityMessage(
            type: "input_key",
            key: key,
            keyCode: keyCode
        )
        ServerManager.shared.broadcastMessage(msg)
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

    private func startStallWatchdog() {
        stopStallWatchdog()
        lastFrameReceivedDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let last = self.lastFrameReceivedDate else { return }
            if Date().timeIntervalSince(last) > 5.0 {
                print("[ScreenMirroringService] Stream stalled (>5000ms), issuing screen_stop")
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
