import Foundation

public struct BatteryInfo: Codable, Equatable {
    public var level: Int // 0 - 100
    public var isCharging: Bool

    public init(level: Int = 100, isCharging: Bool = false) {
        self.level = level
        self.isCharging = isCharging
    }
}

public struct ContinuityMessage: Codable, Equatable {
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

    // Protocol additions
    public var hash: String?
    public var payload: String?
    public var canReply: Bool?
    public var replyText: String?
    public var packageName: String?
    public var bytesTransferred: Int64?
    public var totalBytes: Int64?
    public var percentage: Int?
    public var status: String?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var bitrate: Int?
    public var reason: String?
    public var action: String?
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var key: String?
    public var keyCode: Int?
    public var lens: String?
    public var quality: String?
    public var zoom: Double?
    public var torch: Bool?

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
        battery: BatteryInfo? = nil,
        hash: String? = nil,
        payload: String? = nil,
        canReply: Bool? = nil,
        replyText: String? = nil,
        packageName: String? = nil,
        bytesTransferred: Int64? = nil,
        totalBytes: Int64? = nil,
        percentage: Int? = nil,
        status: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Int? = nil,
        bitrate: Int? = nil,
        reason: String? = nil,
        action: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        button: String? = nil,
        key: String? = nil,
        keyCode: Int? = nil,
        lens: String? = nil,
        quality: String? = nil,
        zoom: Double? = nil,
        torch: Bool? = nil
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
        self.hash = hash
        self.payload = payload
        self.canReply = canReply
        self.replyText = replyText
        self.packageName = packageName
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.percentage = percentage
        self.status = status
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.reason = reason
        self.action = action
        self.x = x
        self.y = y
        self.button = button
        self.key = key
        self.keyCode = keyCode
        self.lens = lens
        self.quality = quality
        self.zoom = zoom
        self.torch = torch
    }
}
