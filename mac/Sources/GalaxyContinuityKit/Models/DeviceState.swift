import AppKit
import Foundation
import Combine

public struct FileTransferItem: Identifiable, Equatable {
    public let id: String
    public let filename: String
    public let fileSize: Int64
    public let isOutgoing: Bool
    public let date: Date
    public let localPath: URL?

    public init(id: String = UUID().uuidString, filename: String, fileSize: Int64, isOutgoing: Bool, date: Date = Date(), localPath: URL? = nil) {
        self.id = id
        self.filename = filename
        self.fileSize = fileSize
        self.isOutgoing = isOutgoing
        self.date = date
        self.localPath = localPath
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

@MainActor
public final class DeviceState: ObservableObject {
    public static let shared = DeviceState()

    @Published public var isConnected: Bool = false
    @Published public var connectedDeviceName: String = "No Device Connected"
    @Published public var connectedPlatform: String = ""
    @Published public var batteryLevel: Int = 0
    @Published public var isCharging: Bool = false
    @Published public var hasBatteryInfo: Bool = false

    @Published public var clipboardAutoSync: Bool = true
    @Published public var lastSharedClipboard: String = ""
    @Published public var lastSharedClipboardType: String = "text/plain"
    @Published public var clipboardLastUpdated: Date? = nil

    @Published public var transferredFiles: [FileTransferItem] = []
    @Published public var isServerRunning: Bool = false
    @Published public var serverPort: Int = 8765
    @Published public var localIPAddress: String = "127.0.0.1"

    @Published public var showPairingSheet: Bool = false
    @Published public var pingMessage: String? = nil

    // Screen Mirroring
    @Published public var isScreenMirroringActive: Bool = false
    @Published public var screenWidth: Int = 1080
    @Published public var screenHeight: Int = 2400
    @Published public var screenFps: Int = 30
    @Published public var screenBitrate: Int = 4000000
    @Published public var lastScreenFrame: NSImage? = nil
    @Published public var screenFrameCount: Int = 0

    // Continuity Camera
    @Published public var isCameraActive: Bool = false
    @Published public var cameraLens: String = "back"
    @Published public var cameraQuality: String = "1080p"
    @Published public var cameraFps: Int = 30
    @Published public var cameraZoom: Double = 1.0
    @Published public var cameraTorch: Bool = false
    @Published public var lastCameraFrame: NSImage? = nil
    @Published public var cameraFrameCount: Int = 0

    private init() {}

    public func setConnected(device: String, platform: String, battery: BatteryInfo?) {
        self.isConnected = true
        self.connectedDeviceName = device.isEmpty ? "Samsung Galaxy" : device
        self.connectedPlatform = platform
        if let b = battery {
            self.batteryLevel = b.level
            self.isCharging = b.isCharging
            self.hasBatteryInfo = true
        }
    }

    public func setDisconnected() {
        self.isConnected = false
        self.connectedDeviceName = "No Device Connected"
        self.connectedPlatform = ""
        self.hasBatteryInfo = false
        self.setScreenMirroringActive(false)
        self.setCameraActive(false)
    }

    public func updateBattery(level: Int, charging: Bool) {
        self.batteryLevel = level
        self.isCharging = charging
        self.hasBatteryInfo = true
    }

    public func addFileTransfer(_ item: FileTransferItem) {
        self.transferredFiles.insert(item, at: 0)
        if self.transferredFiles.count > 25 {
            self.transferredFiles.removeLast()
        }
    }

    public func setScreenMirroringActive(_ active: Bool, width: Int? = nil, height: Int? = nil, fps: Int? = nil, bitrate: Int? = nil) {
        self.isScreenMirroringActive = active
        if let w = width, w > 0 { self.screenWidth = w }
        if let h = height, h > 0 { self.screenHeight = h }
        if let f = fps, f > 0 { self.screenFps = f }
        if let b = bitrate, b > 0 { self.screenBitrate = b }
        if !active {
            self.lastScreenFrame = nil
            self.screenFrameCount = 0
        }
    }

    public func updateScreenFrame(_ image: NSImage) {
        self.lastScreenFrame = image
        self.screenFrameCount += 1
    }

    public func setCameraActive(_ active: Bool, lens: String? = nil, quality: String? = nil, fps: Int? = nil) {
        self.isCameraActive = active
        if let l = lens { self.cameraLens = l }
        if let q = quality { self.cameraQuality = q }
        if let f = fps, f > 0 { self.cameraFps = f }
        if !active {
            self.lastCameraFrame = nil
            self.cameraFrameCount = 0
        }
    }

    public func updateCameraLens(_ lens: String) {
        self.cameraLens = lens
    }

    public func updateCameraZoom(_ zoom: Double) {
        self.cameraZoom = zoom
    }

    public func updateCameraTorch(_ torch: Bool) {
        self.cameraTorch = torch
    }

    public func updateCameraFrame(_ image: NSImage) {
        self.lastCameraFrame = image
        self.cameraFrameCount += 1
    }
}
