import AppKit
import Foundation

public final class ContinuityCameraService: @unchecked Sendable {
    public static let shared = ContinuityCameraService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.continuitycamera", qos: .userInteractive)
    private var stallCheckTimer: DispatchSourceTimer?
    private var lastFrameReceivedDate: Date?

    private init() {}

    public func startCamera(lens: String = "back", quality: String = "1080p", fps: Int = 30) {
        let msg = ContinuityMessage(
            type: "camera_start",
            fps: fps,
            lens: lens,
            quality: quality,
            facing: lens,
            resolution: quality
        )
        ServerManager.shared.broadcastMessage(msg)
        Task { @MainActor in
            DeviceState.shared.setCameraActive(true, lens: lens, quality: quality, fps: fps)
        }
        startStallWatchdog()
    }

    public func stopCamera() {
        let msg = ContinuityMessage(type: "camera_stop")
        ServerManager.shared.broadcastMessage(msg)
        ServerManager.shared.stopCameraStreaming()
        VirtualWebcamFeeder.shared.stopFeeder()
        Task { @MainActor in
            DeviceState.shared.setCameraActive(false)
        }
        stopStallWatchdog()
    }

    public func switchLens(to lens: String) {
        let ctrl = ContinuityMessage(type: "camera_control", action: "switch_lens", lens: lens, facing: lens)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraLens(lens)
        }
    }

    public func setZoom(_ zoom: Double) {
        let ctrl = ContinuityMessage(type: "camera_control", action: "set_zoom", zoom: zoom)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraZoom(zoom)
        }
    }

    public func setTorch(_ enabled: Bool) {
        let ctrl = ContinuityMessage(type: "camera_control", action: "toggle_torch", torch: enabled)
        ServerManager.shared.broadcastMessage(ctrl)
        Task { @MainActor in
            DeviceState.shared.updateCameraTorch(enabled)
        }
    }

    public func handleIncomingFrame(_ frameData: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lastFrameReceivedDate = Date()
            VirtualWebcamFeeder.shared.feedJpeg(frameData)
            ServerManager.shared.broadcastCameraJpeg(frameData)
            if let image = NSImage(data: frameData) {
                Task { @MainActor in
                    DeviceState.shared.updateCameraFrame(image)
                }
            }
        }
    }

    public func handlePeerCameraStart(message: ContinuityMessage) {
        let lens = message.effectiveLens ?? "back"
        let quality = message.effectiveQuality ?? "1080p"
        Task { @MainActor in
            DeviceState.shared.setCameraActive(true, lens: lens, quality: quality, fps: message.fps)
        }
        startStallWatchdog()
    }

    public func handlePeerCameraStop(message: ContinuityMessage) {
        VirtualWebcamFeeder.shared.stopFeeder()
        Task { @MainActor in
            DeviceState.shared.setCameraActive(false)
        }
        stopStallWatchdog()
    }

    public func handlePeerSwitchLens(message: ContinuityMessage) {
        if let lens = message.effectiveLens {
            Task { @MainActor in
                DeviceState.shared.updateCameraLens(lens)
            }
        }
    }

    public func handlePeerCameraControl(message: ContinuityMessage) {
        Task { @MainActor in
            if let lens = message.effectiveLens {
                DeviceState.shared.updateCameraLens(lens)
            }
            if let zoom = message.zoom {
                DeviceState.shared.updateCameraZoom(zoom)
            }
            if let torch = message.torch {
                DeviceState.shared.updateCameraTorch(torch)
            }
        }
    }

    private func startStallWatchdog() {
        stopStallWatchdog()
        lastFrameReceivedDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let last = self.lastFrameReceivedDate else { return }
            if Date().timeIntervalSince(last) > 5.0 {
                print("[ContinuityCameraService] Stream stalled (>5000ms), issuing camera_stop")
                self.stopCamera()
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
