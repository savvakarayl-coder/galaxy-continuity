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
    @Published public var clipboardLastUpdated: Date? = nil

    @Published public var transferredFiles: [FileTransferItem] = []
    @Published public var isServerRunning: Bool = false
    @Published public var serverPort: Int = 8765
    @Published public var localIPAddress: String = "127.0.0.1"

    @Published public var showPairingSheet: Bool = false
    @Published public var pingMessage: String? = nil

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
}
