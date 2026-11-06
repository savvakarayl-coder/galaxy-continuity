import Foundation

public struct BatteryInfo: Codable, Equatable {
    public var level: Int // 0 - 100
    public var isCharging: Bool

    public init(level: Int = 100, isCharging: Bool = false) {
        self.level = level
        self.isCharging = isCharging
    }
}

public struct ContinuityMessage: Codable {
    public var type: String
    public var device: String?
    public var platform: String?
    public var version: String?
    public var content: String?
    public var contentType: String?
    public var timestamp: Double?
    public var source: String?
    public var fileId: String?
    public var filename: String?
    public var fileSize: Int64?
    public var mimeType: String?
    public var sender: String?
    public var app: String?
    public var title: String?
    public var text: String?
    public var level: Int?
    public var isCharging: Bool?
    public var url: String?
    public var message: String?
    public var battery: BatteryInfo?

    public init(
        type: String,
        device: String? = nil,
        platform: String? = nil,
        version: String? = nil,
        content: String? = nil,
        contentType: String? = nil,
        timestamp: Double? = Date().timeIntervalSince1970 * 1000,
        source: String? = nil,
        fileId: String? = nil,
        filename: String? = nil,
        fileSize: Int64? = nil,
        mimeType: String? = nil,
        sender: String? = nil,
        app: String? = nil,
        title: String? = nil,
        text: String? = nil,
        level: Int? = nil,
        isCharging: Bool? = nil,
        url: String? = nil,
        message: String? = nil,
        battery: BatteryInfo? = nil
    ) {
        self.type = type
        self.device = device
        self.platform = platform
        self.version = version
        self.content = content
        self.contentType = contentType
        self.timestamp = timestamp
        self.source = source
        self.fileId = fileId
        self.filename = filename
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.sender = sender
        self.app = app
        self.title = title
        self.text = text
        self.level = level
        self.isCharging = isCharging
        self.url = url
        self.message = message
        self.battery = battery
    }
}
